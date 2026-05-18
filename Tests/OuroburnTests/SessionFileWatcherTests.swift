import Foundation
@testable import Ouroburn
import Testing

/// Lock-protected counter shared with the watcher's onChange closure. The watcher fires from
/// its internal serial queue; we read from the test thread.
private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@Suite("SessionFileWatcher")
struct SessionFileWatcherTests {
    @Test func singleAppendFiresOnce() async throws {
        let (root, jsonl) = try makeRootWithSession()
        let counter = FireCounter()
        let watcher = SessionFileWatcher(
            roots: [root],
            debounceMillis: 200,
            minIntervalSeconds: 0.5,
            rescanIntervalSeconds: 60
        ) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)

        try append(to: jsonl, line: "first")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(counter.count == 1)
    }

    @Test func burstCoalescesIntoOneFire() async throws {
        let (root, jsonl) = try makeRootWithSession()
        let counter = FireCounter()
        let watcher = SessionFileWatcher(
            roots: [root],
            debounceMillis: 200,
            minIntervalSeconds: 0.5,
            rescanIntervalSeconds: 60
        ) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)

        for index in 0 ..< 10 {
            try append(to: jsonl, line: "burst-\(index)")
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(counter.count == 1)
    }

    @Test func minIntervalCooldownDefersSecondFire() async throws {
        let (root, jsonl) = try makeRootWithSession()
        let counter = FireCounter()
        let watcher = SessionFileWatcher(
            roots: [root],
            debounceMillis: 100,
            minIntervalSeconds: 0.5,
            rescanIntervalSeconds: 60
        ) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)

        try append(to: jsonl, line: "one")
        try await Task.sleep(nanoseconds: 200_000_000)
        // First fire should have landed by now.
        #expect(counter.count == 1)

        // Second event during the cooldown window — watcher should defer it, not drop it.
        try append(to: jsonl, line: "two")
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(counter.count == 2)
    }

    @Test func newProjectDirDetectedAfterRescan() async throws {
        let (root, _) = try makeRootWithSession()
        let counter = FireCounter()
        let watcher = SessionFileWatcher(
            roots: [root],
            debounceMillis: 150,
            minIntervalSeconds: 0.3,
            rescanIntervalSeconds: 0.2
        ) { counter.increment() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let projects = root.appendingPathComponent("projects")
        let newSession = projects.appendingPathComponent("new-session")
        try FileManager.default.createDirectory(at: newSession, withIntermediateDirectories: true)
        let newFile = newSession.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: newFile.path, contents: Data())

        // Wait long enough for the next rescan to bind the new dir.
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = counter.count

        try append(to: newFile, line: "appended-after-rescan")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(counter.count > before)
    }

    @Test func stopHaltsEvents() async throws {
        let (root, jsonl) = try makeRootWithSession()
        let counter = FireCounter()
        let watcher = SessionFileWatcher(
            roots: [root],
            debounceMillis: 150,
            minIntervalSeconds: 0.3,
            rescanIntervalSeconds: 60
        ) { counter.increment() }
        watcher.start()
        try await Task.sleep(nanoseconds: 250_000_000)

        try append(to: jsonl, line: "before-stop")
        try await Task.sleep(nanoseconds: 400_000_000)
        let beforeStop = counter.count
        #expect(beforeStop >= 1)

        watcher.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        for index in 0 ..< 5 {
            try append(to: jsonl, line: "after-stop-\(index)")
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(counter.count == beforeStop)
    }

    private func makeRootWithSession() throws -> (root: URL, jsonl: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projects = root.appendingPathComponent("projects/test-session")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let jsonl = projects.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: jsonl.path, contents: Data())
        return (root, jsonl)
    }

    private func append(to url: URL, line: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
