import XCTest
@testable import MediaConverterCore

final class ContainerAppLocatorTests: XCTestCase {
    func testDerivesContainerAppURL() {
        let ext = URL(fileURLWithPath: "/Apps/MediaConverter.app/Contents/PlugIns/ConvertQuickAction.appex")
        let app = ContainerAppLocator.appURL(fromExtensionBundleURL: ext)
        XCTAssertEqual(app?.path, "/Apps/MediaConverter.app")
    }
    func testReturnsNilForUnexpectedShape() {
        let bad = URL(fileURLWithPath: "/a/b/c/d")
        XCTAssertNil(ContainerAppLocator.appURL(fromExtensionBundleURL: bad))
    }
}
