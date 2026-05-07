import Foundation
import os

/// Unified logger. Routes through os.Logger (Console.app, `log stream`) AND a tail-friendly
/// rolling file at `~/Library/Logs/ouroburn/ouroburn.log` so users can confirm what's happening
/// without needing the Console app.
enum Log {
    static let subsystem = "dev.sheldonhull.ouroburn"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tracker = Logger(subsystem: subsystem, category: "tracker")
    static let loader = Logger(subsystem: subsystem, category: "loader")
    static let pricing = Logger(subsystem: subsystem, category: "pricing")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    static let fileSink = FileSink()

    static func info(_ category: Logger, _ message: String) {
        category.info("\(message, privacy: .public)")
        fileSink.append(level: "INFO", category: categoryName(category), message: message)
    }

    static func error(_ category: Logger, _ message: String) {
        category.error("\(message, privacy: .public)")
        fileSink.append(level: "ERROR", category: categoryName(category), message: message)
    }

    static func debug(_ category: Logger, _ message: String) {
        category.debug("\(message, privacy: .public)")
        fileSink.append(level: "DEBUG", category: categoryName(category), message: message)
    }

    private static func categoryName(_ logger: Logger) -> String {
        switch logger {
        case app: "app"
        case tracker: "tracker"
        case loader: "loader"
        case pricing: "pricing"
        case ui: "ui"
        default: "?"
        }
    }
}

extension Logger: Equatable {
    public static func == (lhs: Logger, rhs: Logger) -> Bool {
        // Logger has reference semantics under the hood — pointer equality is sufficient for our
        // category dispatch. There are 5 fixed instances; collisions are not possible.
        unsafeBitCast(lhs, to: UnsafeRawPointer.self) == unsafeBitCast(rhs, to: UnsafeRawPointer.self)
    }
}

/// Append-only line-oriented log file. Writes are serialized through a queue so the file isn't
/// corrupted by concurrent pollers.
final class FileSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ouroburn.filesink")
    private let url: URL
    private nonisolated(unsafe) var handle: FileHandle?
    private let formatter: DateFormatter

    init() {
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Logs/ouroburn", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ouroburn-logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        url = logsDir.appendingPathComponent("ouroburn.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
        self.formatter = formatter
    }

    func append(level: String, category: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if handle == nil {
                handle = try? FileHandle(forWritingTo: url)
                try? handle?.seekToEnd()
            }
            let line = "\(formatter.string(from: Date())) [\(level)] [\(category)] \(message)\n"
            try? handle?.write(contentsOf: Data(line.utf8))
            try? handle?.synchronize()
        }
    }

    var location: URL { url }
}
