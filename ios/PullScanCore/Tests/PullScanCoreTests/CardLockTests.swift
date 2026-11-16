import PullScanCore
import XCTest

/** Same cases as the Android CardLockTest. */
final class CardLockTests: XCTestCase {
    private func card(_ id: String) -> Card { Card(id: id, name: id, set: "set", number: "1") }
    private lazy var a = card("a")
    private lazy var b = card("b")
    private lazy var c = card("c")
    private lazy var d = card("d")
    private lazy var noise = card("noise")

    private func frame(_ m: (Card, Float)...) -> [Match] { m.map { Match($0.0, $0.1) } }

    func testLocksAfterTwoFramesAndHoldsThroughDips() {
        let lock = CardLock(autoAddMs: 0)
        lock.update(frame((a, 0.55), (b, 0.5)), now: 0)
        XCTAssertNil(lock.state)
        lock.update(frame((a, 0.52), (b, 0.5)), now: 100)
        XCTAssertEqual(lock.state?.card.id, "a")
        // Dips below 50% and a reprint briefly on top: still a.
        lock.update(frame((a, 0.45), (b, 0.44)), now: 200)
        lock.update(frame((b, 0.51), (a, 0.50)), now: 300)
        lock.update(frame((a, 0.49)), now: 400)
        XCTAssertEqual(lock.state?.card.id, "a")
        XCTAssertEqual(lock.state?.best, 0.52)   // the score it locked at; dips don't lower it
    }

    func testReleasesAfterTwoFramesBelow40() {
        let lock = CardLock(autoAddMs: 0)
        lock.update(frame((a, 0.7)), now: 0); lock.update(frame((a, 0.7)), now: 1)
        lock.update(frame((noise, 0.35)), now: 2)
        XCTAssertEqual(lock.state?.card.id, "a")   // one blurry frame isn't enough
        lock.update(frame((noise, 0.30)), now: 3)
        XCTAssertNil(lock.state)
    }

    func testSwitchesWhenAnotherCardBeatsTheBestTwice() {
        let lock = CardLock(autoAddMs: 0)
        lock.update(frame((a, 0.62)), now: 0); lock.update(frame((a, 0.62)), now: 1)
        lock.update(frame((b, 0.70), (a, 0.4)), now: 2)
        XCTAssertEqual(lock.state?.card.id, "a")
        lock.update(frame((b, 0.72), (a, 0.4)), now: 3)
        XCTAssertEqual(lock.state?.card.id, "b")
    }

    func testAutoAddsOncePerLockOnlyWhenConfident() {
        let lock = CardLock(autoAddMs: 2000)
        lock.update(frame((a, 0.55)), now: 0); lock.update(frame((a, 0.55)), now: 0)
        XCTAssertFalse(lock.update(frame((a, 0.58)), now: 5000))   // low confidence: never auto-added
        lock.release()

        lock.update(frame((a, 0.7)), now: 0); lock.update(frame((a, 0.7)), now: 0)
        XCTAssertFalse(lock.update(frame((a, 0.48)), now: 1500))
        XCTAssertTrue(lock.update(frame((a, 0.46)), now: 2000))
        XCTAssertFalse(lock.update(frame((a, 0.7)), now: 4000))
        XCTAssertEqual(lock.state?.added, true)

        // Card removed, then put back (or the next copy): a new cycle.
        lock.update(frame((noise, 0.3)), now: 4100); lock.update(frame((noise, 0.3)), now: 4200)
        lock.update(frame((a, 0.7)), now: 5000); lock.update(frame((a, 0.7)), now: 5100)
        XCTAssertTrue(lock.update(frame((a, 0.7)), now: 7100))
    }

    func testManualAddSuppressesAutoAdd() {
        let lock = CardLock(autoAddMs: 1000)
        lock.update(frame((a, 0.7)), now: 0); lock.update(frame((a, 0.7)), now: 0)
        lock.markAdded()
        XCTAssertFalse(lock.update(frame((a, 0.7)), now: 5000))
        XCTAssertNil(lock.remaining(now: 5000))
    }

    func testCandidateOrderStaysPutAndNewOnesAppend() {
        let lock = CardLock(autoAddMs: 0)
        lock.update(frame((a, 0.7), (b, 0.6), (c, 0.5), (noise, 0.3)), now: 0)
        lock.update(frame((a, 0.7), (b, 0.6), (c, 0.5), (noise, 0.3)), now: 1)
        XCTAssertEqual(lock.state?.others.map(\.card.id), ["b", "c"])   // < 40% not listed
        lock.update(frame((a, 0.7), (c, 0.65), (d, 0.45), (b, 0.55)), now: 2)
        XCTAssertEqual(lock.state?.others.map(\.card.id), ["b", "c", "d"])
        XCTAssertEqual(lock.state?.others[1].score, 0.65)   // best score, not latest
        XCTAssertEqual(lock.state?.others[0].score, 0.60)
    }

    func testPickReplacesPrimaryAndSticks() {
        let lock = CardLock(autoAddMs: 1000)
        lock.update(frame((a, 0.7), (b, 0.68)), now: 0); lock.update(frame((a, 0.7), (b, 0.68)), now: 0)
        lock.choose(b)
        XCTAssertEqual(lock.state?.card.id, "b")
        XCTAssertEqual(lock.state?.added, true)
        XCTAssertEqual(lock.state?.others.map(\.card.id), ["a"])
        // a keeps scoring higher, but it's a known candidate and the user picked b.
        for i in 0..<5 { XCTAssertFalse(lock.update(frame((a, 0.75), (b, 0.68)), now: 5000 + Int64(i))) }
        XCTAssertEqual(lock.state?.card.id, "b")
    }

    func testCancelRestartsTheTimer() {
        let lock = CardLock(autoAddMs: 2000)
        lock.update(frame((a, 0.7)), now: 0); lock.update(frame((a, 0.7)), now: 0)
        lock.restartTimer(now: 1500)   // sheet was open from 1.0 s to 1.5 s
        XCTAssertFalse(lock.update(frame((a, 0.7)), now: 2500))
        XCTAssertEqual(lock.remaining(now: 2500), 1000)
        XCTAssertTrue(lock.update(frame((a, 0.7)), now: 3500))
    }
}
