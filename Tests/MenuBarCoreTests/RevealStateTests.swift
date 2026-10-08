import XCTest
import ApplicationServices
@testable import MenuBarCore

final class RevealStateTests:XCTestCase {
    func testHideRequestWaitsForAllMenusAndMouseRelease() throws {
        var state = RevealState(); let token = try state.begin(); state.revealed(); state.requestHide()
        let first = AXElementIdentity(AXUIElementCreateApplication(1))
        let second = AXElementIdentity(AXUIElementCreateApplication(2))
        state.menuOpened(first); state.menuOpened(second)
        state.menuClosed(second); XCTAssertFalse(state.canHide)
        state.menuClosed(first); state.mouse(down:true); XCTAssertFalse(state.canHide)
        state.mouse(down:false); XCTAssertTrue(state.canHide)
        try state.hiding(token); state.finish(); XCTAssertEqual(state.phase,.hidden)
    }
    func testStaleTimerCannotHideNewSession() throws {
        var state = RevealState(); let old = try state.begin(); state.revealed(); state.requestHide(); try state.hiding(old); state.finish()
        _ = try state.begin(); state.revealed(); state.requestHide()
        XCTAssertThrowsError(try state.hiding(old)); XCTAssertEqual(state.phase,.visible)
    }
    func testPopoverTransitionBlocksPendingHide() throws {
        var state = RevealState(); _ = try state.begin(); state.revealed(); state.requestHide()
        state.interfaces(1); XCTAssertFalse(state.canHide)
        state.interfaces(0); XCTAssertTrue(state.canHide)
        state.interfaces(1); XCTAssertFalse(state.canHide)
    }
    func testFailureCannotBeTreatedAsHidden() throws {
        var state = RevealState(); _ = try state.begin(); state.revealed(); state.fail()
        XCTAssertEqual(state.phase,.failed); XCTAssertFalse(state.canHide); XCTAssertThrowsError(try state.begin())
    }
    func testManagerMenuCancelsClosureUntilDismissed() throws {
        var state = RevealState(); _ = try state.begin(); state.revealed(); state.requestHide()
        state.managerMenu(true); XCTAssertFalse(state.shouldCheckClosure)
        state.managerMenu(false); XCTAssertTrue(state.canHide)
    }
    func testWindowRemovalIsCheckedAfterMenuClosure() throws {
        var state = RevealState(); _ = try state.begin(); state.revealed()
        state.interfaces(1); state.requestHide()
        XCTAssertTrue(state.shouldCheckClosure); XCTAssertFalse(state.canHide)
        state.interfaces(0); XCTAssertTrue(state.canHide)
    }
    func testNativeClosureReconcilesMissingMenuClosedNotification() throws {
        var state = RevealState(); _ = try state.begin(); state.revealed()
        state.menuOpened(AXElementIdentity(AXUIElementCreateApplication(1)))
        state.interfaces(2); state.interfaces(1)
        XCTAssertFalse(state.canHide); XCTAssertEqual(state.menus.count,1)
        state.interfaces(0)
        XCTAssertTrue(state.canHide); XCTAssertTrue(state.menus.isEmpty)
    }
    func testDuplicateOpenNotificationDoesNotRetainMenu() throws {
        var state = RevealState(); _ = try state.begin(); state.revealed()
        let menu = AXElementIdentity(AXUIElementCreateApplication(1))
        state.menuOpened(menu); state.menuOpened(menu)
        XCTAssertEqual(state.menus.count,1)
        state.menuClosed(menu); XCTAssertTrue(state.canHide)
    }
    func testNewSessionClearsAllInteractionState() throws {
        var state = RevealState(); let first = try state.begin(); state.revealed()
        state.mouse(down:true); state.managerMenu(true); state.interfaces(1)
        state.finish(); let second = try state.begin(); state.revealed()
        XCTAssertGreaterThan(second,first); XCTAssertFalse(state.pointerDown)
        XCTAssertFalse(state.managerMenuOpen); XCTAssertEqual(state.interfaceCount,0)
        XCTAssertFalse(state.hideRequested); XCTAssertFalse(state.canHide)
    }
    func testSourceTerminationInvalidatesInFlightSession() throws {
        var state = RevealState(); let token = try state.begin()
        state.finish()
        XCTAssertNotEqual(state.generation,token); XCTAssertEqual(state.phase,.hidden)
        XCTAssertThrowsError(try state.hiding(token))
    }
    func testCanceledTransitionCannotStartAnotherRevealBeforeCleanup() throws {
        var state = RevealState(); let token = try state.begin()
        state.cancelTransition()
        XCTAssertEqual(state.phase,.stopping); XCTAssertNotEqual(state.generation,token)
        XCTAssertFalse(state.canHide); XCTAssertThrowsError(try state.begin())
        state.finish(); XCTAssertEqual(state.phase,.hidden)
        XCTAssertNoThrow(try state.begin())
    }

    func testRecoveryIsAnExclusiveCancelableTransition() throws {
        var state = RevealState(); _ = try state.begin(); state.fail()
        let token = try state.retryHiding()
        XCTAssertEqual(state.phase,.hiding)
        XCTAssertThrowsError(try state.begin())
        XCTAssertThrowsError(try state.retryHiding())
        state.cancelTransition()
        XCTAssertNotEqual(state.generation,token)
        XCTAssertEqual(state.phase,.stopping)
        state.finish(); XCTAssertNoThrow(try state.begin())
    }

}
