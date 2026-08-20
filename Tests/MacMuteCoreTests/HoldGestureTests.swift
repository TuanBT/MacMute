import XCTest
@testable import MacMuteCore

/// Every case here is a timing case, which is exactly why they are not reproducible by
/// hand: an auto-repeat, a release that never arrives, a screen locking mid-press.
final class HoldGestureTests: XCTestCase {

    private let threshold = HoldGesture.holdThreshold
    private let ceiling = HoldGesture.maxHold

    // MARK: - Tap versus hold

    func testShortPressIsATapAndTheToggleStands() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: false, at: 100)
        XCTAssertEqual(gesture.ended(at: 100 + threshold / 2), .keep)
        XCTAssertFalse(gesture.isHolding)
    }

    func testLongPressRevertsToTheStateBeforeIt() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 100)
        XCTAssertEqual(gesture.ended(at: 100 + threshold + 1), .revert(to: true))
    }

    /// Push-to-mute is the same gesture read from the other side: held while live, the
    /// microphone goes back to live on release.
    func testHoldingWhileLiveRevertsToLive() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: false, at: 100)
        XCTAssertEqual(gesture.ended(at: 100 + threshold + 1), .revert(to: false))
    }

    /// The boundary belongs to the hold, and a press one tick short of it is still a tap.
    func testThresholdBoundary() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        XCTAssertEqual(gesture.ended(at: threshold), .revert(to: true))

        gesture.began(stateBefore: true, at: 0)
        XCTAssertEqual(gesture.ended(at: threshold - 0.001), .keep)
    }

    // MARK: - Presses that do not arrive cleanly

    /// A key that auto-repeats must not restart the clock, or a two second hold reads as
    /// a string of taps and the microphone is left wherever the last one put it.
    func testRepeatedPressesDoNotRestartTheClock() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        for repeated in stride(from: 0.1, through: 0.9, by: 0.1) {
            gesture.began(stateBefore: false, at: repeated)
        }
        XCTAssertEqual(gesture.ended(at: 1.0), .revert(to: true))
    }

    func testReleaseWithoutAPressDoesNothing() {
        var gesture = HoldGesture()
        XCTAssertNil(gesture.ended(at: 100))
    }

    func testSecondReleaseDoesNothing() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        XCTAssertEqual(gesture.ended(at: 1), .revert(to: true))
        XCTAssertNil(gesture.ended(at: 2))
    }

    // MARK: - The watchdog

    func testCeilingDoesNotFireWhileThePressIsStillPlausible() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        XCTAssertNil(gesture.expired(at: ceiling - 0.001))
        XCTAssertTrue(gesture.isHolding)
    }

    func testCeilingRevertsAPressThatOutlivesIt() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        XCTAssertEqual(gesture.expired(at: ceiling), .revert(to: true))
        XCTAssertFalse(gesture.isHolding)
    }

    /// The release that Carbon owed us can still turn up afterwards. By then the
    /// watchdog has already put the microphone back, and acting again would toggle it.
    func testLateReleaseAfterTheCeilingDoesNothing() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        XCTAssertEqual(gesture.expired(at: ceiling), .revert(to: true))
        XCTAssertNil(gesture.ended(at: ceiling + 5))
    }

    func testCeilingWithNoPressInFlightDoesNothing() {
        var gesture = HoldGesture()
        XCTAssertNil(gesture.expired(at: .greatestFiniteMagnitude))
    }

    // MARK: - Presses macOS takes away

    /// Sleep, a locked screen, a rebound shortcut: the key cannot be reported up, so the
    /// answer is the safe one regardless of how long it had been held.
    func testAbandonRevertsEvenBelowTheThreshold() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        XCTAssertEqual(gesture.abandon(), .revert(to: true))
        XCTAssertFalse(gesture.isHolding)
    }

    func testAbandonWithNoPressInFlightDoesNothing() {
        var gesture = HoldGesture()
        XCTAssertNil(gesture.abandon())
    }

    /// The menu sets an absolute state, so the press in flight must be dropped rather
    /// than reverted — a revert would undo what the user just clicked.
    func testCancelDropsThePressWithoutReverting() {
        var gesture = HoldGesture()
        gesture.began(stateBefore: true, at: 0)
        gesture.cancel()
        XCTAssertFalse(gesture.isHolding)
        XCTAssertNil(gesture.ended(at: 10))
        XCTAssertNil(gesture.abandon())
    }

    // MARK: - The threshold itself

    /// Reading a tap as a hold undoes a mute the user asked for and leaves them audible,
    /// so the threshold has to sit well above an ordinary keystroke of 80 to 120 ms.
    func testThresholdClearsAnOrdinaryKeystroke() {
        XCTAssertGreaterThan(HoldGesture.holdThreshold, 0.2)
        XCTAssertLessThan(HoldGesture.holdThreshold, HoldGesture.maxHold)
    }
}
