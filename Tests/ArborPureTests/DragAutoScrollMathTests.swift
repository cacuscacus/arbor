import XCTest

@testable import ArborPure

/// Guards drag-autoscroll clamping math against negative-inset clamping bugs
/// (where `NSTableView`'s 28pt column-header clip inset gives a resting origin
/// of `-28` and clamping against `0` scrolled a resting table *down* on click).
final class DragAutoScrollMathTests: XCTestCase {
    func testScrollingUpAtRestingHeaderOriginDoesNotClampToZero() {
        let result = DragAutoScrollMath.nextOriginY(
            currentOriginY: -28,
            clipHeight: 600,
            documentHeight: 1200,
            topInset: 28,
            bottomInset: 0,
            isFlipped: true,
            pointerYInClip: 10,
            topBand: 76,
            bottomBand: 48,
            maxStep: 16,
            acceleration: 1.0
        )

        XCTAssertTrue(result.inEdgeBand)
        XCTAssertEqual(result.nextOriginY, -28, accuracy: 0.001)
        XCTAssertFalse(result.didMove)
    }

    func testScrollingUpReachesNegativeTopInsetToRevealFirstRow() {
        let result = DragAutoScrollMath.nextOriginY(
            currentOriginY: -10,
            clipHeight: 600,
            documentHeight: 1200,
            topInset: 28,
            bottomInset: 0,
            isFlipped: true,
            pointerYInClip: -8,
            topBand: 76,
            bottomBand: 48,
            maxStep: 24,
            acceleration: 1.0
        )

        XCTAssertTrue(result.inEdgeBand)
        XCTAssertEqual(result.nextOriginY, -28, accuracy: 0.001)
        XCTAssertTrue(result.didMove)
    }

    func testScrollingDownFromRestingHeaderOriginStepsSmoothlyWithoutJumpingToZero() {
        let result = DragAutoScrollMath.nextOriginY(
            currentOriginY: -28,
            clipHeight: 600,
            documentHeight: 1200,
            topInset: 28,
            bottomInset: 0,
            isFlipped: true,
            pointerYInClip: 560, // distanceFromBottom = 600 - (560 - (-28)) = 12
            topBand: 76,
            bottomBand: 48,
            maxStep: 16,
            acceleration: 1.0
        )

        XCTAssertTrue(result.inEdgeBand)
        XCTAssertGreaterThan(result.nextOriginY, -28)
        XCTAssertLessThan(result.nextOriginY, 0)
        XCTAssertTrue(result.didMove)
    }

    func testPointerInMiddleBandDoesNotScroll() {
        let result = DragAutoScrollMath.nextOriginY(
            currentOriginY: 100,
            clipHeight: 600,
            documentHeight: 1200,
            topInset: 28,
            bottomInset: 0,
            isFlipped: true,
            pointerYInClip: 400,
            topBand: 76,
            bottomBand: 48,
            maxStep: 16,
            acceleration: 1.0
        )

        XCTAssertFalse(result.inEdgeBand)
        XCTAssertEqual(result.nextOriginY, 100, accuracy: 0.001)
        XCTAssertFalse(result.didMove)
    }

    func testShortNonScrollableDocumentNeverMoves() {
        let result = DragAutoScrollMath.nextOriginY(
            currentOriginY: -28,
            clipHeight: 600,
            documentHeight: 200,
            topInset: 28,
            bottomInset: 0,
            isFlipped: true,
            pointerYInClip: 560,
            topBand: 76,
            bottomBand: 48,
            maxStep: 16,
            acceleration: 1.0
        )

        XCTAssertTrue(result.inEdgeBand)
        XCTAssertEqual(result.nextOriginY, -28, accuracy: 0.001)
        XCTAssertFalse(result.didMove)
    }

    func testBottomClampRespectsBottomInset() {
        let result = DragAutoScrollMath.nextOriginY(
            currentOriginY: 600,
            clipHeight: 600,
            documentHeight: 1200,
            topInset: 28,
            bottomInset: 20,
            isFlipped: true,
            pointerYInClip: 1190,
            topBand: 76,
            bottomBand: 48,
            maxStep: 16,
            acceleration: 2.0
        )

        XCTAssertTrue(result.inEdgeBand)
        XCTAssertEqual(result.nextOriginY, 620, accuracy: 0.001)
        XCTAssertTrue(result.didMove)
    }
}
