import Foundation

/// Decides whether a press of the shortcut was a tap or a hold.
///
/// The toggle itself happens on the press, exactly as it always did, so the shortcut
/// keeps its speed and a hold never clips the first syllable. This type only answers
/// the question the release asks: did the user mean that, or were they borrowing the
/// other state for as long as their finger was down?
///
/// Kept here, free of AppKit, because every interesting case is a timing case — an
/// auto-repeat, a release that never arrives, a screen that locks mid-press — and none
/// of them are reproducible by hand.
public struct HoldGesture {

    /// What the release should do to the state the press produced.
    public enum Outcome: Equatable {
        /// A tap. The toggle stands.
        case keep
        /// A hold. Put the microphone back the way it was before the press.
        case revert(to: Bool)
    }

    /// Below this a press reads as a tap. Well clear of an ordinary keystroke (80 to
    /// 120 ms) and of a slow, deliberate one, because the two failures are not equal:
    /// reading a hold as a tap leaves the user muted, while reading a tap as a hold
    /// undoes the mute they asked for and leaves them audible.
    public static let holdThreshold: TimeInterval = 0.4

    /// No press may outlive this. macOS drops the release event when focus moves, the
    /// screen locks, or the front app hangs mid-press, and without a ceiling that would
    /// leave the microphone open in precisely the situation push-to-talk exists to
    /// prevent.
    public static let maxHold: TimeInterval = 30

    private var pressedAt: TimeInterval?
    private var stateBeforePress = false

    public init() {}

    /// True between a press and whatever ends it.
    public var isHolding: Bool { pressedAt != nil }

    /// How long the press in flight has lasted. Diagnostics only — the decisions above
    /// each read the clock themselves.
    public func held(at now: TimeInterval) -> TimeInterval? {
        pressedAt.map { now - $0 }
    }

    /// Records the press. `stateBefore` is the mute state the toggle just replaced.
    ///
    /// A press arriving while one is already in flight is ignored rather than restarting
    /// the clock, so a key that auto-repeats cannot shred a single hold into a string of
    /// toggles.
    public mutating func began(stateBefore: Bool, at now: TimeInterval) {
        guard pressedAt == nil else { return }
        pressedAt = now
        stateBeforePress = stateBefore
    }

    /// Ends the press normally. Returns nil when nothing is in flight — a release that
    /// arrives after the watchdog already gave up, or the first release after the
    /// feature was switched on mid-press.
    public mutating func ended(at now: TimeInterval) -> Outcome? {
        guard let start = pressedAt else { return nil }
        pressedAt = nil
        return now - start >= Self.holdThreshold ? .revert(to: stateBeforePress) : .keep
    }

    /// The watchdog. Returns a revert once the press has outlived `maxHold`, and nothing
    /// while it is still plausible.
    public mutating func expired(at now: TimeInterval) -> Outcome? {
        guard let start = pressedAt, now - start >= Self.maxHold else { return nil }
        pressedAt = nil
        return .revert(to: stateBeforePress)
    }

    /// Ends the press without consulting the clock, for the cases where macOS has taken
    /// the keyboard away mid-hold: sleep, a locked screen, a switched session, the
    /// shortcut being rebound. The key cannot be reported up, so the safe answer is the
    /// state the user was in before they pressed it.
    public mutating func abandon() -> Outcome? {
        guard pressedAt != nil else { return nil }
        pressedAt = nil
        return .revert(to: stateBeforePress)
    }

    /// Drops the press in flight without acting on it, for when something else has
    /// already decided the mute state outright.
    public mutating func cancel() { pressedAt = nil }
}
