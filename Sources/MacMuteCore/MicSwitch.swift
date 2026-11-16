import Foundation

/// Tells a call moving to another microphone apart from someone unmuting in it.
///
/// Changing the microphone in Teams' own menu is anything but quiet underneath. Teams
/// stops capturing from one device and starts on the other, at times with seconds of
/// nothing in between, and takes the mute off whichever device it opens: the log has it
/// doing that to the built-in microphone, with Teams itself muted, three times in one
/// week. With a microphone like the K30, Teams also matches its own mute to the device
/// it has just been handed. Any of that can show Teams live for a moment, and following
/// Teams then opens the microphone — and with Teams following the device, an open
/// microphone keeps Teams live. Muted, with the K30 plugged in, one change of microphone
/// in that menu left Teams unmuted.
///
/// So while the call is between microphones, and for a few seconds after it lands on
/// the next, Teams showing live is put down to the switch rather than to the user. What
/// the app does about it is decided above this; here is only the question of when.
///
/// Free of CoreAudio, the way `TeamsSync` is free of the Accessibility API, because
/// every case worth testing is a timing case.
public struct MicSwitch {

    /// How long a switch is given to settle after its last change, and how long a device
    /// must have been capturing for its stopping to be the call moving off it. What a
    /// switch does to Teams shows within a second of the new device starting, and the
    /// button is read twice a second.
    public static let settle: TimeInterval = 3

    /// When each device capturing now began.
    private var since: [UInt32: TimeInterval] = [:]
    /// The latest change belonging to a switch; nil until the call first moves.
    private var lastMove: TimeInterval?

    public init() {}

    /// A call began, capturing from these. It has not moved yet.
    public mutating func begin(capturing devices: Set<UInt32>, at now: TimeInterval) {
        since = [:]
        for id in devices { since[id] = now }
        lastMove = nil
    }

    /// The call is over, and nothing it did says anything about the next one.
    public mutating func end() {
        since = [:]
        lastMove = nil
    }

    /// Devices started and stopped capturing in the middle of a call.
    ///
    /// A device the call had been capturing from stopping is the call moving off it,
    /// and every change after that is part of the same move until it has settled. Teams
    /// sometimes starts the new device first and stops the old one 12 to 20 ms later,
    /// well before anything it does to its button shows, so the move is dated from the
    /// stop whichever way round it goes.
    ///
    /// A device opened for a moment and closed again is not a move. Teams does exactly
    /// that to the built-in microphone as a call joins, for about 0.2 s while the call's
    /// own microphone captures throughout, and the first thing many people do on
    /// joining is unmute.
    public mutating func changed(started: Set<UInt32>, stopped: Set<UInt32>,
                                 at now: TimeInterval) {
        let wasSwitching = isSwitching(at: now)
        let movedOff = stopped.contains { id in
            since[id].map { now - $0 >= Self.settle } ?? false
        }
        for id in stopped { since[id] = nil }
        for id in started { since[id] = now }
        if movedOff || wasSwitching { lastMove = now }
    }

    /// True while the call is between microphones: moved off one and capturing from
    /// nothing yet, or not long enough on the next for Teams to have settled.
    public func isSwitching(at now: TimeInterval) -> Bool {
        guard let lastMove else { return false }
        return since.isEmpty || now - lastMove < Self.settle
    }
}
