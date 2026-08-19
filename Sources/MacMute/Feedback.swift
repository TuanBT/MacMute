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
        case soft, click, pluck, chime

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

    /// AVAudioPlayer.play() measured 15-30 ms on the main thread even after
    /// prepareToPlay, because the first call spins up the output device. That is a
    /// third of the budget for a shortcut that has to feel instant, so playback runs
    /// off the keypress path entirely.
    private let queue = DispatchQueue(label: "com.tuanbt.macmute.feedback", qos: .userInitiated)

    private var players: [String: AVAudioPlayer] = [:]

    init() {
        // Every pack is preloaded: the files are a few kilobytes each, and building a
        // player lazily would put that cost back on the first keypress after a change.
        for pack in Pack.allCases {
            for tone in [Tone.mute, .unmute] {
                load(tone, pack: pack)
            }
        }
        load(.error, pack: nil)
        Timing.note("feedback: loaded \(players.count) tones "
                    + "(\(Pack.allCases.count) packs x 2, plus error)")
    }

    func play(_ tone: Tone) {
        play(tone, pack: Settings.soundPack)
    }

    /// Used by the menu to audition a pack the moment it is picked.
    func play(_ tone: Tone, pack: Pack) {
        guard let player = players[key(tone, tone == .error ? nil : pack)] else { return }
        queue.async {
            player.currentTime = 0
            player.play()
        }
    }

    private func load(_ tone: Tone, pack: Pack?) {
        let directory = pack.map { "Sounds/\($0.rawValue)" } ?? "Sounds"
        guard let url = Bundle.main.url(forResource: tone.rawValue, withExtension: "wav",
                                        subdirectory: directory),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = 0.7
        player.prepareToPlay()
        players[key(tone, pack)] = player
    }

    private func key(_ tone: Tone, _ pack: Pack?) -> String {
        "\(pack?.rawValue ?? "-")/\(tone.rawValue)"
    }
}
