import Foundation

/// A plain text record of what the app did and what the devices said back, kept always.
///
/// It exists for the report that matters most — "the icon said muted, Teams said
/// muted, and I was still heard" — which cannot be reproduced on demand and cannot be
/// answered by guessing. The file holds every decision the app made and every reading
/// the HAL and Teams gave back, so it can simply be sent.
///
/// Nothing here runs on the caller's time beyond taking the timestamp: the write
/// happens on its own queue, so the keypress costs what it cost before.
enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacMute", isDirectory: true)
    static let file = directory.appendingPathComponent("MacMute.log")

    /// One previous file is kept, so a session that rolled over mid-meeting still has
    /// its beginning.
    private static let previous = directory.appendingPathComponent("MacMute.1.log")
    private static let limit: UInt64 = 2_000_000

    private static let queue = DispatchQueue(label: "com.tuanbt.macmute.log", qos: .utility)
    private static var handle: FileHandle?
    private static var size: UInt64 = 0
    /// Which file the handle is writing to, so a handle that has been parted from the
    /// path can be told apart from one still writing where the settings panel points.
    private static var inode: ino_t = 0

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let now = Date()
        queue.async {
            let line = clock.string(from: now) + " " + message + "\n"
            append(Data(line.utf8))
        }
    }

    /// Blocks until everything queued so far is on disk. For quitting, and for handing
    /// the file to Finder.
    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    // MARK: - Queue confined

    private static func append(_ data: Data) {
        // A handle follows its file wherever it is moved. Dragging the log to the Trash
        // from the Finder window "Show Log in Finder" opens did not stop the logging, it
        // sent every line after it into the Trash, and the folder stayed empty for the
        // rest of the session — two and a half days of it, the first time it happened.
        if handle == nil || !stillAtPath() { open() }
        if size + UInt64(data.count) > limit { rotate() }
        guard let handle else { return }
        handle.write(data)
        size += UInt64(data.count)
    }

    /// One `stat` per line, on this queue and not the caller's.
    private static func stillAtPath() -> Bool {
        var info = stat()
        return stat(file.path, &info) == 0 && info.st_ino == inode
    }

    private static func open() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        size = (try? handle?.seekToEnd()) ?? 0
        var info = stat()
        if let handle, fstat(handle.fileDescriptor, &info) == 0 { inode = info.st_ino } else { inode = 0 }
    }

    private static func rotate() {
        let manager = FileManager.default
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: file, to: previous)
        open()
    }
}
