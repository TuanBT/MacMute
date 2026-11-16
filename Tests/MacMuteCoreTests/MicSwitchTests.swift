import XCTest
@testable import MacMuteCore

/// Each case is a sequence of capture changes the log has shown Teams making, read for
/// whether the call was changing microphone at the moment Teams went live.
///
/// The times are ones a Double holds exactly, so that a switch settling at exactly
/// `settle` is tested as that and not as a rounding error either side of it.
final class MicSwitchTests: XCTestCase {

    private let settle = MicSwitch.settle
    private let k30: UInt32 = 212
    private let builtIn: UInt32 = 91

    func testACallThatHasNotMovedIsNotSwitching() {
        var mics = MicSwitch()
        mics.begin(capturing: [k30], at: 0)
        XCTAssertFalse(mics.isSwitching(at: 0.5))
        XCTAssertFalse(mics.isSwitching(at: 600))
    }

    /// Changing microphone in Teams' own menu: the old one stops, nothing captures for a
    /// moment, the new one starts. The switch lasts through the gap, however long, and
    /// settles a few seconds after the new microphone starts.
    func testMovingOffTheCallsMicrophoneIsASwitchUntilTheNextOneSettles() {
        var mics = MicSwitch()
        mics.begin(capturing: [builtIn], at: 0)
        mics.changed(started: [], stopped: [builtIn], at: 60)
        XCTAssertTrue(mics.isSwitching(at: 60.125))
        XCTAssertTrue(mics.isSwitching(at: 62.5), "nothing capturing has no end in sight")

        mics.changed(started: [k30], stopped: [], at: 62.5)
        XCTAssertTrue(mics.isSwitching(at: 62.5 + settle - 0.25))
        XCTAssertFalse(mics.isSwitching(at: 62.5 + settle))
    }

    /// The K30 plugged in mid-call: Teams started it and stopped the built-in microphone
    /// 20 ms later. The switch is dated from the stop.
    func testStartingTheNewMicrophoneFirstIsASwitchFromTheStop() {
        var mics = MicSwitch()
        mics.begin(capturing: [builtIn], at: 0)
        mics.changed(started: [k30], stopped: [], at: 98.73)
        XCTAssertFalse(mics.isSwitching(at: 98.74), "on its own, another microphone opening moves nothing")
        mics.changed(started: [], stopped: [builtIn], at: 98.75)
        XCTAssertTrue(mics.isSwitching(at: 99.5))
        XCTAssertFalse(mics.isSwitching(at: 98.75 + settle))
    }

    /// As a call joins, Teams opens the built-in microphone for 0.2 s while the K30 goes
    /// on capturing. Someone unmuting the moment they join is not a microphone switch.
    func testAMicrophoneOpenedForAMomentAsTheCallJoinsIsNoSwitch() {
        var mics = MicSwitch()
        mics.begin(capturing: [k30], at: 0)
        mics.changed(started: [builtIn], stopped: [], at: 4.5)
        XCTAssertFalse(mics.isSwitching(at: 4.625))
        mics.changed(started: [], stopped: [builtIn], at: 4.75)
        XCTAssertFalse(mics.isSwitching(at: 5))
        XCTAssertFalse(mics.isSwitching(at: 6))
    }

    /// Teams stopping and reopening the same microphone does to it all that a switch
    /// does: the mute comes off the device it opens.
    func testReopeningTheSameMicrophoneIsASwitch() {
        var mics = MicSwitch()
        mics.begin(capturing: [builtIn], at: 0)
        mics.changed(started: [], stopped: [builtIn], at: 1000)
        mics.changed(started: [builtIn], stopped: [], at: 1002.5)
        XCTAssertTrue(mics.isSwitching(at: 1003))
        XCTAssertFalse(mics.isSwitching(at: 1002.5 + settle))
    }

    /// Whatever opens and closes while the call is between microphones is part of the
    /// same move, and the move settles only after the last of it.
    func testChangesDuringASwitchKeepItGoing() {
        var mics = MicSwitch()
        mics.begin(capturing: [builtIn], at: 0)
        mics.changed(started: [], stopped: [builtIn], at: 60)
        mics.changed(started: [k30], stopped: [], at: 60.5)
        mics.changed(started: [builtIn], stopped: [], at: 62)
        mics.changed(started: [], stopped: [builtIn], at: 62.25)
        XCTAssertTrue(mics.isSwitching(at: 62.25 + settle - 0.25))
        XCTAssertFalse(mics.isSwitching(at: 62.25 + settle))
    }

    /// A call whose only microphone stops seconds after it started never settled on it.
    func testAMicrophoneThatNeverSettledStoppingIsNoSwitch() {
        var mics = MicSwitch()
        mics.begin(capturing: [k30], at: 0)
        mics.changed(started: [], stopped: [k30], at: 1)
        XCTAssertFalse(mics.isSwitching(at: 1.5))
    }

    func testANewCallForgetsTheLastOnesSwitch() {
        var mics = MicSwitch()
        mics.begin(capturing: [builtIn], at: 0)
        mics.changed(started: [], stopped: [builtIn], at: 60)
        XCTAssertTrue(mics.isSwitching(at: 61))
        mics.end()
        XCTAssertFalse(mics.isSwitching(at: 61))
        mics.begin(capturing: [k30], at: 70)
        XCTAssertFalse(mics.isSwitching(at: 70.5))
    }
}
