import CoreServices
import Foundation

/// Recursive file-system watcher over Claude JSONL session roots, backed by one
/// `FSEventStream` per call. A single stream covers the entire `~/.claude/projects/` subtree —
/// no per-file FDs, no per-directory FDs, no rescan timer. Events get coalesced through a
/// debounce window, and a hard minimum interval gates the user's `onChange` callback so a hot
/// tool loop can't drive `BurnTracker.poll()` faster than is useful.
///
/// Why FSEvents over `DispatchSourceFileSystemObject`: per-file kqueue watches cost one FD
/// each. A user with ~2.5k jsonl sessions blows past the default 256-FD soft limit. FSEvents
/// is path-based, recursive, and Apple-recommended for "watch a tree" workloads. New project
/// directories appearing mid-session are picked up automatically — no rescan timer needed.
final class SessionFileWatcher {
    private let roots: [URL]
    private let debounceMillis: Int
    private let minIntervalSeconds: Double
    private let onChange: () -> Void

    private let queue = DispatchQueue(label: "ouroburn.session-file-watcher", qos: .utility)
    private var streams: [FSEventStreamRef] = []
    private var debounceItem: DispatchWorkItem?
    private var lastFiredAt: Date?
    private var pendingFire = false
    private var running = false

    init(
        roots: [URL],
        debounceMillis: Int = 750,
        minIntervalSeconds: Double = 2.0,
        rescanIntervalSeconds _: Double = 60.0,
        onChange: @escaping () -> Void
    ) {
        self.roots = roots
        self.debounceMillis = debounceMillis
        self.minIntervalSeconds = minIntervalSeconds
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !running else { return }
            running = true
            startStreams()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            running = false
            for stream in streams {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            streams.removeAll()
            debounceItem?.cancel()
            debounceItem = nil
            pendingFire = false
        }
    }

    private func startStreams() {
        // Watch each root's `projects/` subtree separately so we never see unrelated noise
        // from elsewhere in `~/.claude` (credentials writes, settings flips, etc.).
        let watchPaths: [String] = roots.compactMap { root in
            let projects = root.appendingPathComponent("projects").path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projects, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return projects
        }
        guard !watchPaths.isEmpty else {
            Log.info(Log.tracker, "SessionFileWatcher: no `projects/` roots — watcher idle")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, _, _, _ in
            guard let info, eventCount > 0 else { return }
            let watcher = Unmanaged<SessionFileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleFire()
        }

        let cfPaths = watchPaths as CFArray
        // 0.25s FS-layer coalescing keeps event volume manageable during hot bursts; our own
        // debounce above decides when to actually call `onChange`.
        let latency: CFAbsoluteTime = 0.25
        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Log.error(Log.tracker, "SessionFileWatcher: FSEventStreamCreate failed")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            streams.append(stream)
            Log.info(Log.tracker, "SessionFileWatcher: started FSEventStream on \(watchPaths.count) root(s)")
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Log.error(Log.tracker, "SessionFileWatcher: FSEventStreamStart returned false")
        }
    }

    private func scheduleFire() {
        guard running else { return }
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fireRespectingCooldown() }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(debounceMillis), execute: item)
    }

    private func fireRespectingCooldown() {
        guard running else { return }
        let now = Date()
        if let last = lastFiredAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < minIntervalSeconds {
                guard !pendingFire else { return }
                pendingFire = true
                let delay = minIntervalSeconds - elapsed
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, running else { return }
                    pendingFire = false
                    lastFiredAt = Date()
                    onChange()
                }
                return
            }
        }
        lastFiredAt = now
        onChange()
    }
}
