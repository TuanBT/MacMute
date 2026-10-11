import Foundation

/// Keeps the Teams Mute button and the microphone in step, in both directions.
///
/// Pressing the button whenever the shortcut was pressed was only ever half of it. One
/// week of logs shows the other half going wrong: unmute inside Teams — its own button,
/// its own shortcut, a headset whose button Teams listens to — and the app never heard
/// of it, because it read the button exactly once per call, when the call began. Teams
/// showed you live over a microphone that was still muted, and you talked to nobody.
///
/// Now the button is read for as long as anything has a microphone open, and every
/// reading comes through here to be told apart:
///
///   - one that differs from what the user last asked for is a press that has not
///     landed yet, and the button is pressed again, `maxPresses` times at most;
///   - one that differs from the reading before it, with nothing asked, is Teams moving
///     on its own, and the app follows it;
///   - the first reading of a call is Teams deciding how the call starts, and the app
///     follows that too — unless the user has pressed the shortcut since, in which case
///     that press is delivered instead, because it is the newer word on the matter.
///
/// Telling the first two apart is the whole job: following a press that had not landed
/// yet is how the app would undo the user's own shortcut.
///
/// Free of the Accessibility API, the way `HoldGesture` is free of Carbon, because
/// every case worth testing here is a timing case.
public struct TeamsSync {

    /// Something the user asked for that Teams has not yet been seen to show.
    public struct Request: Equatable {
        /// True for muted.
        public let target: Bool
        /// Which press asked, so a reading taken before a newer one can be told apart.
        public let serial: Int
        public let made: TimeInterval
        public internal(set) var presses = 0
    }

    public enum Step: Equatable {
        /// Nothing to do.
        case nothing
        /// Teams disagrees with the request: press the button, then report `pressed(at:)`.
        case press
        /// Teams shows what was asked. `pressed` is false when it already did.
        case settled(pressed: Bool)
        /// Pressed `maxPresses` times and Teams still disagrees — an organiser's hard
        /// mute does exactly that. The request is dropped, and the user has to be told,
        /// because the microphone and Teams now say different things.
        case gaveUp(target: Bool)
        /// Teams moved without being asked, or this is the first look at it this call.
        case changed(muted: Bool, first: Bool)
    }

    /// The label flips about 100 ms after a press. Read sooner, it still reports the
    /// state the press was leaving — which is how a second press arriving 8 ms after
    /// the first, as a remapped mouse button sends them, used to read "already there",
    /// skip the button, and leave Teams the opposite of the microphone.
    public static let settle: TimeInterval = 0.5
    public static let maxPresses = 3

    public private(set) var request: Request?
    /// What Teams showed at the last reading this call; nil until the first.
    public private(set) var seen: Bool?
    public private(set) var isWatching = false
    private var began: TimeInterval = 0
    private var lastPress: TimeInterval?

    public init() {}

    /// Something opened a microphone, which is what a call starting looks like from
    /// here. A press made before it is not carried in: how a call starts is Teams' to
    /// decide, and a press from before the meeting said nothing about it.
    public mutating func begin(at now: TimeInterval) {
        guard !isWatching else { return }
        isWatching = true
        began = now
        seen = nil
        request = nil
    }

    /// Nothing has had a microphone open for a while: the call is over.
    public mutating func end() {
        isWatching = false
        seen = nil
        request = nil
    }

    /// The user asked for `target` — the shortcut, the menu, either edge of a hold.
    /// Replaces whatever was asked before, landed or not.
    public mutating func ask(_ target: Bool, serial: Int, at now: TimeInterval) {
        request = Request(target: target, serial: serial, made: now)
    }

    /// How long until the label is worth reading.
    public func wait(at now: TimeInterval) -> TimeInterval {
        guard let lastPress else { return 0 }
        return max(0, Self.settle - (now - lastPress))
    }

    /// One reading of the button, true when it says Teams is muted.
    public mutating func read(_ teamsMuted: Bool, at now: TimeInterval) -> Step {
        guard wait(at: now) == 0 else { return .nothing }
        if let request {
            if teamsMuted == request.target {
                seen = teamsMuted
                self.request = nil
                return .settled(pressed: request.presses > 0)
            }
            guard request.presses < Self.maxPresses else {
                seen = teamsMuted
                self.request = nil
                return .gaveUp(target: request.target)
            }
            return .press
        }
        let first = seen == nil
        guard first || seen != teamsMuted else { return .nothing }
        seen = teamsMuted
        return .changed(muted: teamsMuted, first: first)
    }

    /// The button was pressed. A press that failed counts the same, so a button that
    /// keeps refusing is not retried forever.
    public mutating func pressed(at now: TimeInterval) {
        lastPress = now
        request?.presses += 1
    }

    /// How old the last scan that found nothing must be before another is worth it.
    ///
    /// A scan walks the whole window when the button is not there, about a tenth of a
    /// second, and things with nothing to do with Teams hold microphones open for hours
    /// — something on this machine opens the K30 for two minutes at a time, over and
    /// over. So the pace falls away: quick while a call may still be joining, slow once
    /// this is plainly not one, and quick again while a press is waiting on the button.
    public func scanGap(at now: TimeInterval) -> TimeInterval {
        if let request, now - request.made < 5 { return 1 }
        guard isWatching else { return 1 }
        let age = now - began
        if age < 10 { return 1.5 }
        if age < 60 { return 5 }
        return 15
    }
}
