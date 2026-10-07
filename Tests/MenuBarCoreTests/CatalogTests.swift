import XCTest
@testable import MenuBarCore

final class CatalogTests:XCTestCase {
    func testWindowlessHelperFailuresDoNotBecomeIconFailures() {
        XCTAssertEqual(Catalog.issues(native:[1,2],identified:[1,2],itemErrors:[],rootErrors:["Windowless helper: Accessibility error -25204"]),[])
    }

    func testUnreadableIconIsReportedWhenNativeCoverageIsIncomplete() {
        let issues = Catalog.issues(native:[1,2],identified:[1],itemErrors:[],rootErrors:["Unresponsive app: Accessibility error -25204"])
        XCTAssertTrue(issues.contains("1 menu-bar icon could not be identified"))
        XCTAssertTrue(issues.contains("Unresponsive app: Accessibility error -25204"))
    }

    func testItemFailuresRemainVisibleEvenWhenOtherIconsCoverTheNativeWindows() {
        XCTAssertEqual(Catalog.issues(native:[1],identified:[1],itemErrors:["Ambiguous icon geometry"],rootErrors:["Windowless helper"]),["Ambiguous icon geometry"])
    }

    func testUnsupportedIconIsReportedEvenWithoutAnAccessibilityError() {
        XCTAssertEqual(Catalog.issues(native:[1,2],identified:[1],itemErrors:[],rootErrors:[]),["1 menu-bar icon could not be identified"])
    }
}
