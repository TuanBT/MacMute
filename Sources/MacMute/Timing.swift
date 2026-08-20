import Foundation

/// Stopwatch for the keypress path, printed only when MACMUTE_TIMING is set.
///
/// The shortcut has to feel instant, and the only way to keep it that way is to be
/// able to measure it on a real machine with real devices attached.
enum Timing {
    private static let enabled = ProcessInfo.processInfo.environment["MACMUTE_TIMING"] != nil
    private static let labels = ["read state", "sound (pre)", "audio.setMuted",
                                 "sound (post)", "render"]

    static func log(target: Bool, marks: [UInt64]) {
        guard enabled, marks.count == labels.count + 1 else { return }
        var out = "TOGGLE -> " + (target ? "mute" : "unmute") + "\n"
        for (index, label) in labels.enumerated() {
            out += String(format: "  %-16s %6.2f ms\n", (label as NSString).utf8String!,
                          ms(marks[index], marks[index + 1]))
        }
        out += String(format: "  %-16s %6.2f ms\n\n", ("TOTAL" as NSString).utf8String!,
                      ms(marks.first!, marks.last!))
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// One-off diagnostic line, same gate as the stopwatch.
    ///
    /// Stamped, because the questions worth asking of this log are about spacing: a
    /// remapped mouse button that fires the shortcut twice looks identical to two
    /// deliberate presses until you can see they were 8 ms apart.
    static func note(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data((stamp() + " " + message + "\n").utf8))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func stamp() -> String { clock.string(from: Date()) }

    private static func ms(_ from: UInt64, _ to: UInt64) -> Double {
        Double(to - from) / 1_000_000
    }
}
