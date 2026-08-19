import AVFoundation
import AppKit

/// Plays the mute/unmute confirmation tones.
///
/// The point is not decoration. Without a sound there is no way to tell "the shortcut
/// did nothing" apart from "the shortcut worked but Teams draws the wrong icon", which
/// is the ambiguity that made the old build feel unreliable.
final class Feedback {

    enum Tone: String {
        case mute, unmute, error
    }

    /// Four characters rather than one, because a tone that reads as a clear
    /// confirmation to one person reads as noise to the next. In every pack the mute
    /// tone falls and the unmute tone rises.
    enum Pack: String, CaseIterable {
        case click, soft, pluck, chime

        var title: String {
            switch self {
            case .soft:  return "Soft"
            case .click: return "Click"
            case .pluck: return "Marimba"
            case .chime: return "Chime"
            }
        }

        var detail: String {
            switch self {
            case .soft:  return "Smooth glide, least attention-seeking"
            case .click: return "Shortest — a switch being flipped"
            case .pluck: return "Musical but dry, no ringing tail"
            case .chime: return "Longest, carries over background noise"
            }
        }
    }

    /// AVAudioPlayer.play() measured 17-19 ms warm and 65-79 ms after the output
    /// device had gone idle, even with prepareToPlay called at launch. The mute itself
    /// takes about three milliseconds, so the tone was arriving long after the thing it
    /// was confirming — which is most of what "it feels slow" was.
    ///
    /// An AVAudioEngine that is already running has nothing to wake up: scheduling a
    /// pre-decoded buffer is a fraction of a millisecond. The engine is stopped again
    /// after a couple of minutes idle so a menu bar app is not holding the output
    /// device open all day.
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.tuanbt.macmute.feedback", qos: .userInitiated)

    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var format: AVAudioFormat?
    private var idleTimer: Timer?

    private static let idleShutdown: TimeInterval = 120

    init() {
        for pack in Pack.allCases {
            for tone in [Tone.mute, .unmute] { load(tone, pack: pack) }
        }
        load(.error, pack: nil)

        if let format {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            node.volume = 0.7
            engine.prepare()
        }
        Timing.note("feedback: loaded \(buffers.count) tones "
                    + "(\(Pack.allCases.count) packs x 2, plus error)")
    }

    func play(_ tone: Tone) {
        guard Settings.soundEnabled else { return }
        play(tone, pack: Settings.soundPack)
    }

    /// Starting the engine costs about 38 ms, once. Doing it when an app first opens
    /// the microphone spends that while you are joining a meeting rather than on the
    /// keypress you are waiting for, and the idle timer still releases the output
    /// device if the shortcut never gets used.
    func warmUp() {
        queue.async { [weak self] in
            guard let self, !self.engine.isRunning else { return }
            guard (try? self.engine.start()) != nil else { return }
            DispatchQueue.main.async { self.restartIdleTimer() }
        }
    }

    /// Used by the menu to audition a pack the moment it is picked.
    func play(_ tone: Tone, pack: Pack) {
        guard let buffer = buffers[key(tone, tone == .error ? nil : pack)] else { return }
        let requested = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            guard let self else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            if !self.engine.isRunning {
                guard (try? self.engine.start()) != nil else { return }
            }
            // .interrupts so a quick second press replaces the tone rather than queueing
            // behind it.
            self.node.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !self.node.isPlaying { self.node.play() }
            let playing = DispatchTime.now().uptimeNanoseconds
            Timing.note(String(format: "    sound: queued %.2f ms, schedule %.2f ms",
                               Double(started - requested) / 1e6,
                               Double(playing - started) / 1e6))
            DispatchQueue.main.async { self.restartIdleTimer() }
        }
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleShutdown,
                                         repeats: false) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.node.stop()
                self.engine.stop()
            }
        }
    }

    private func load(_ tone: Tone, pack: Pack?) {
        let directory = pack.map { "Sounds/\($0.rawValue)" } ?? "Sounds"
        guard let url = Bundle.main.url(forResource: tone.rawValue, withExtension: "wav",
                                        subdirectory: directory),
              let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return }
        self.format = format
        buffers[key(tone, pack)] = buffer
    }

    private func key(_ tone: Tone, _ pack: Pack?) -> String {
        "\(pack?.rawValue ?? "-")/\(tone.rawValue)"
    }
}
