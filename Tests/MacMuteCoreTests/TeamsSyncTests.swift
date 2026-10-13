import XCTest
@testable import MacMuteCore

/// Every case here is a sequence of readings over time, which is what the logs could
/// only show after the fact: a press that had not landed, a change made inside Teams,
/// and a reading taken too soon to tell the two apart.
final class TeamsSyncTests: XCTestCase {

    private let settle = TeamsSync.settle

    // MARK: - Teams moving on its own

    func testFirstReadingOfACallIsReported() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        XCTAssertEqual(sync.read(true, at: 0.4), .changed(muted: true, first: true))
        XCTAssertEqual(sync.read(true, at: 0.9), .nothing, "the same again says nothing new")
    }

    /// The report this exists for: unmuted inside Teams, and the app never heard of it.
    func testChangeMadeInsideTeamsIsReported() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(true, at: 0.4)
        XCTAssertEqual(sync.read(false, at: 30), .changed(muted: false, first: false))
        XCTAssertEqual(sync.read(true, at: 45), .changed(muted: true, first: false))
    }

    // MARK: - The user's own presses

    func testPressThatLandsIsNotMistakenForAChangeInTeams() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)

        sync.ask(true, serial: 1, at: 2)
        XCTAssertEqual(sync.read(false, at: 2), .press)
        sync.pressed(at: 2)
        XCTAssertEqual(sync.read(false, at: 2.05), .nothing, "the label has not flipped yet")
        XCTAssertEqual(sync.read(true, at: 2 + settle), .settled(pressed: true))
        XCTAssertNil(sync.request)
        XCTAssertEqual(sync.read(true, at: 3), .nothing, "its own press is not news")
    }

    func testTeamsAlreadyThereIsNotPressed() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 1)
        XCTAssertEqual(sync.read(true, at: 1), .settled(pressed: false))
    }

    func testPressThatDoesNotLandIsPressedAgainThenGivenUp() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(false, serial: 1, at: 1)
        var now: TimeInterval = 1
        for _ in 0..<TeamsSync.maxPresses {
            XCTAssertEqual(sync.read(true, at: now), .press)
            sync.pressed(at: now)
            now += settle
        }
        XCTAssertEqual(sync.read(true, at: now), .gaveUp(target: false))
        XCTAssertNil(sync.request)
        XCTAssertEqual(sync.seen, true, "Teams' state is what it is, and later changes count from it")
        XCTAssertEqual(sync.read(true, at: now + 1), .nothing)
    }

    /// A remapped mouse button sends the shortcut twice, 8 ms apart. The second press
    /// used to read the label before the first had flipped it, find Teams "already"
    /// where it was going, and leave it the opposite of the microphone.
    func testSecondPressInsideTheSettleWindowWaitsForTheFirst() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)

        sync.ask(true, serial: 1, at: 10)
        XCTAssertEqual(sync.read(false, at: 10), .press)
        sync.pressed(at: 10.001)
        sync.ask(false, serial: 2, at: 10.008)
        XCTAssertGreaterThan(sync.wait(at: 10.009), 0)
        XCTAssertEqual(sync.read(false, at: 10.009), .nothing, "stale: the first press has not shown yet")

        // The first press has landed by now, so Teams is muted and the newer press
        // wants it live.
        XCTAssertEqual(sync.read(true, at: 10.001 + settle), .press)
        sync.pressed(at: 10.6)
        XCTAssertEqual(sync.read(false, at: 10.6 + settle), .settled(pressed: true))
    }

    // MARK: - Teams following the microphone by itself

    /// The K30 call: Teams matched the device mute before the press arrived, and the
    /// press toggled it back. Seen once, the next keypress leaves Teams to it.
    func testFirstPressUndoneMeansTeamsFollowsTheDevice() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)

        sync.ask(true, serial: 1, at: 10)
        XCTAssertEqual(sync.read(false, at: 10), .press)
        sync.pressed(at: 10)
        XCTAssertFalse(sync.followsDevice)
        XCTAssertEqual(sync.read(false, at: 10 + settle), .press, "back where it started")
        XCTAssertTrue(sync.followsDevice)
        sync.pressed(at: 10.5)
        XCTAssertEqual(sync.read(true, at: 10.5 + settle), .settled(pressed: true))

        sync.ask(false, serial: 2, at: 20)
        XCTAssertGreaterThan(sync.wait(at: 20), 0)
        XCTAssertEqual(sync.read(true, at: 20), .nothing,
                       "pressing now is the toggle that undoes Teams following the device")
        XCTAssertEqual(sync.read(true, at: 20.2), .nothing)
        XCTAssertEqual(sync.read(false, at: 20 + settle), .settled(pressed: false))
        XCTAssertTrue(sync.followsDevice, "it did it again, so it is still left to")
    }

    /// The same device, minutes later in the same call, stopped doing it. Waiting once
    /// costs half a second of the Teams indicator; waiting every time would cost it on
    /// every keypress.
    func testTeamsThatStopsFollowingTheDeviceIsPressedAgain() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 10)
        _ = sync.read(false, at: 10)
        sync.pressed(at: 10)
        _ = sync.read(false, at: 10 + settle)
        XCTAssertTrue(sync.followsDevice)
        sync.pressed(at: 10.5)
        _ = sync.read(true, at: 10.5 + settle)

        sync.ask(false, serial: 2, at: 20)
        XCTAssertEqual(sync.read(true, at: 20 + settle), .press)
        XCTAssertFalse(sync.followsDevice)
        sync.pressed(at: 20.5)
        XCTAssertEqual(sync.read(false, at: 20.5 + settle), .settled(pressed: true))

        sync.ask(true, serial: 3, at: 30)
        XCTAssertEqual(sync.wait(at: 30), 0)
        XCTAssertEqual(sync.read(false, at: 30), .press, "straight away, as before")
    }

    /// Several keypresses inside the wait are one request: Teams is read once the last
    /// of them has had time to reach it.
    func testWaitingForTeamsRestartsWithEveryPress() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 10)
        _ = sync.read(false, at: 10)
        sync.pressed(at: 10)
        _ = sync.read(false, at: 10 + settle)
        sync.pressed(at: 10.5)
        _ = sync.read(true, at: 10.5 + settle)

        sync.ask(false, serial: 2, at: 20)
        sync.ask(true, serial: 3, at: 20.3)
        XCTAssertEqual(sync.read(true, at: 20 + settle), .nothing)
        XCTAssertEqual(sync.read(true, at: 20.3 + settle), .settled(pressed: false))
    }

    func testANewCallForgetsThatTeamsFollowedTheDevice() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 10)
        _ = sync.read(false, at: 10)
        sync.pressed(at: 10)
        _ = sync.read(false, at: 10 + settle)
        XCTAssertTrue(sync.followsDevice)
        sync.end()
        sync.begin(at: 100)
        XCTAssertFalse(sync.followsDevice)
        sync.ask(false, serial: 2, at: 101)
        XCTAssertEqual(sync.read(true, at: 101), .press)
    }

    /// A press waiting on a button that is not on screen yet is never read as Teams
    /// changing its mind once the button turns up.
    func testPressWaitingOnTheButtonIsDeliveredWhenItAppears() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 2)     // still in the lobby: no button to press
        XCTAssertEqual(sync.read(false, at: 30), .press,
                       "the shortcut is the newer word on how this call should be")
    }

    func testPressOverACallInProgressIsDeliveredNotFollowed() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)
        sync.ask(true, serial: 1, at: 20)
        XCTAssertEqual(sync.read(false, at: 24), .press, "not .changed: nothing moved inside Teams")
    }

    // MARK: - Calls starting and ending

    func testACallStartingDropsAPressMadeBeforeIt() {
        var sync = TeamsSync()
        sync.ask(true, serial: 1, at: 0)    // between calls, nothing to press
        sync.begin(at: 5)
        XCTAssertNil(sync.request)
        XCTAssertEqual(sync.read(false, at: 5.4), .changed(muted: false, first: true))
    }

    /// Teams stops one device and starts another when it switches. That is not a new
    /// call, and must not reset what has been seen.
    func testBeginningAgainMidCallChangesNothing() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(true, at: 0.4)
        sync.ask(false, serial: 1, at: 3)
        sync.begin(at: 4)
        XCTAssertEqual(sync.seen, true)
        XCTAssertNotNil(sync.request)
    }

    func testEndForgetsTheCall() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(true, at: 0.4)
        sync.ask(false, serial: 1, at: 3)
        sync.end()
        XCTAssertFalse(sync.isWatching)
        XCTAssertNil(sync.seen)
        XCTAssertNil(sync.request)
    }

    // MARK: - Scanning for the button

    func testScanningSlowsDownOnceThisIsPlainlyNotACall() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        XCTAssertEqual(sync.scanGap(at: 5), 1.5)
        XCTAssertEqual(sync.scanGap(at: 30), 5)
        XCTAssertEqual(sync.scanGap(at: 600), 15)
    }

    func testAPressWaitingOnTheButtonScansQuicklyForAWhile() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 600)
        XCTAssertEqual(sync.scanGap(at: 601), 1)
        XCTAssertEqual(sync.scanGap(at: 606), 15, "the press has had its chance; back to the slow pace")
    }

    func testPressBetweenCallsScansAtItsOwnPace() {
        var sync = TeamsSync()
        XCTAssertEqual(sync.scanGap(at: 0), 1)
        sync.ask(true, serial: 1, at: 0)
        XCTAssertEqual(sync.scanGap(at: 0.5), 1)
    }
}
