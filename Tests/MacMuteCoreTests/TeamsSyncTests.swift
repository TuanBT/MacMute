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
    /// where it was going, and leave it the opposite of the microphone. It is not read
    /// at all now: the first press is known to be taking Teams to muted, so the second,
    /// which wants it live, is one more press.
    func testSecondPressInsideTheSettleWindowReversesTheFirst() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)

        sync.ask(true, serial: 1, at: 10)
        XCTAssertEqual(sync.read(false, at: 10), .press)
        sync.pressed(at: 10.001)
        sync.ask(false, serial: 2, at: 10.008)
        XCTAssertEqual(sync.wait(at: 10.009), 0)
        XCTAssertEqual(sync.read(false, at: 10.009), .press,
                       "the label still says live, which is the state before the first press")
        sync.pressed(at: 10.009)

        // Both presses have had their time, and Teams is where the newer one sent it.
        XCTAssertEqual(sync.read(false, at: 10.009 + settle), .settled(pressed: true))
    }

    /// A newer press for what the last one is already bringing about has nothing to
    /// press: it waits for the label like any other.
    func testSecondPressForTheSameStateWaitsForTheFirst() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)

        sync.ask(true, serial: 1, at: 10)
        XCTAssertEqual(sync.read(false, at: 10), .press)
        sync.pressed(at: 10)
        sync.ask(true, serial: 2, at: 10.2)
        XCTAssertGreaterThan(sync.wait(at: 10.2), 0)
        XCTAssertEqual(sync.read(false, at: 10.2), .nothing, "stale: the first press has not shown yet")
        XCTAssertEqual(sync.read(true, at: 10 + settle), .settled(pressed: false))
    }

    /// A press that never reached the button moved nothing, so the next request is not
    /// built on it.
    func testPressThatFailedLeavesNothingToReverse() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)

        sync.ask(true, serial: 1, at: 10)
        XCTAssertEqual(sync.read(false, at: 10), .press)
        sync.pressed(at: 10, landed: false)
        XCTAssertNil(sync.inFlight(at: 10.1))
        sync.ask(false, serial: 2, at: 10.2)
        XCTAssertGreaterThan(sync.wait(at: 10.2), 0)
        XCTAssertEqual(sync.read(false, at: 10 + settle), .settled(pressed: false),
                       "Teams never moved, and is already where it was asked to be")
    }

    // MARK: - Teams behind another app

    /// The Omnissa morning: behind a full-screen remote desktop the label turned up as
    /// much as 1.2 s after the press. Read at half a second, a press that had worked
    /// looked like one that had not, and pressing again took Teams straight back.
    func testPressWithTeamsInTheBackgroundIsGivenLongerToShow() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(false, at: 0.4)

        sync.ask(true, serial: 1, at: 10, inBackground: true)
        XCTAssertEqual(sync.read(false, at: 10), .press)
        sync.pressed(at: 10, inBackground: true)
        XCTAssertEqual(sync.wait(at: 10), TeamsSync.backgroundSettle)
        XCTAssertEqual(sync.read(false, at: 10 + settle), .nothing,
                       "not shown yet is not the same as not landed")
        XCTAssertEqual(sync.read(true, at: 11.2), .nothing)
        XCTAssertEqual(sync.read(true, at: 10 + TeamsSync.backgroundSettle), .settled(pressed: true))
        XCTAssertFalse(sync.followsDevice, "a late label is not Teams following the microphone")
    }

    /// Only the wait grows: a press that really did not land is still pressed again.
    func testPressInTheBackgroundThatDoesNotLandIsStillPressedAgain() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(false, serial: 1, at: 1, inBackground: true)
        XCTAssertEqual(sync.read(true, at: 1), .press)
        sync.pressed(at: 1, inBackground: true)
        XCTAssertEqual(sync.read(true, at: 1 + TeamsSync.backgroundSettle), .press)
    }

    /// Two keypresses under a second apart behind Omnissa. The second is decided on what
    /// the first did, not on the label from before both.
    func testNewerPressIsDecidedOnWhatABackgroundPressDid() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(true, at: 0.4)

        sync.ask(false, serial: 1, at: 10, inBackground: true)
        _ = sync.read(true, at: 10)
        sync.pressed(at: 10, inBackground: true)
        sync.ask(true, serial: 2, at: 10.8, inBackground: true)
        XCTAssertEqual(sync.read(true, at: 10.8), .press,
                       "the old label would say Teams is already muted, and leave it live")
    }

    /// 16 November, Teams behind another app, unmute / mute / unmute under a second
    /// apart. The mute waited out what was left of the two seconds, the unmute replaced
    /// it, and Teams was never pressed for the mute: it was left live over a microphone
    /// that had been muted at once, and the user ended up muting it inside Teams.
    func testMuteRightAfterAnUnmuteBehindAnotherAppIsNotHeldBack() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        _ = sync.read(true, at: 0.4)

        sync.ask(false, serial: 1, at: 10, inBackground: true)
        XCTAssertEqual(sync.read(true, at: 10), .press)
        sync.pressed(at: 10.008, inBackground: true)

        sync.ask(true, serial: 2, at: 10.6, inBackground: true)
        XCTAssertEqual(sync.wait(at: 10.6), 0)
        XCTAssertEqual(sync.read(true, at: 10.6), .press, "label still says muted: the unmute has not shown")
        sync.pressed(at: 10.61, inBackground: true)

        sync.ask(false, serial: 3, at: 11.4, inBackground: true)
        XCTAssertEqual(sync.read(true, at: 11.4), .press, "and the next one reverses that in turn")
        sync.pressed(at: 11.41, inBackground: true)

        XCTAssertGreaterThan(sync.wait(at: 11.5), 0, "now it is waited on, to be sure it landed")
        XCTAssertEqual(sync.read(false, at: 11.41 + TeamsSync.backgroundSettle), .settled(pressed: true))
    }

    /// Teams that moves its own mute to the microphone's is left to it, as before: the
    /// press would be the second toggle.
    func testReversingIsLeftToTeamsThatFollowsTheDevice() {
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
        sync.pressed(at: 20.1)   // an earlier request's press, still showing
        sync.ask(true, serial: 3, at: 20.3)
        XCTAssertGreaterThan(sync.wait(at: 20.3), 0)
        XCTAssertEqual(sync.read(true, at: 20.3), .nothing)
    }

    /// Back in front, Teams answers in a tenth of a second again, and is read at the
    /// usual pace.
    func testPressWithTeamsInFrontKeepsTheShortSettle() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 10, inBackground: true)
        _ = sync.read(false, at: 10)
        sync.pressed(at: 10, inBackground: true)
        _ = sync.read(true, at: 10 + TeamsSync.backgroundSettle)

        sync.ask(false, serial: 2, at: 20)
        XCTAssertEqual(sync.read(true, at: 20), .press)
        sync.pressed(at: 20)
        XCTAssertEqual(sync.wait(at: 20), settle)
        XCTAssertEqual(sync.read(false, at: 20 + settle), .settled(pressed: true))
    }

    /// Teams following the microphone by itself shows as late as a press does.
    func testWaitingForTeamsToFollowTheDeviceIsLongerInTheBackground() {
        var sync = TeamsSync()
        sync.begin(at: 0)
        sync.ask(true, serial: 1, at: 10)
        _ = sync.read(false, at: 10)
        sync.pressed(at: 10)
        _ = sync.read(false, at: 10 + settle)
        XCTAssertTrue(sync.followsDevice)
        sync.pressed(at: 10.5)
        _ = sync.read(true, at: 10.5 + settle)

        sync.ask(false, serial: 2, at: 20, inBackground: true)
        XCTAssertEqual(sync.read(true, at: 20 + settle), .nothing)
        XCTAssertEqual(sync.read(false, at: 20 + TeamsSync.backgroundSettle), .settled(pressed: false))
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
