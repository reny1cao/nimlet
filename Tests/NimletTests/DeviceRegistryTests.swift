import XCTest
import Combine

@MainActor
final class DeviceRegistryTests: XCTestCase {
    func testApprovalAndRevocationAreVisibleToSubscribersAndNetworkReaders() {
        let registry = DeviceRegistry.shared
        let id = "registry-test-" + UUID().uuidString
        var observedApproval = false
        var observedRevocation = false
        let subscription = registry.$approved.dropFirst().sink { devices in
            if devices.contains(where: { $0.id == id }) {
                observedApproval = registry.isApproved(id) && !registry.isRevoked(id)
            } else if observedApproval {
                observedRevocation = !registry.isApproved(id) && registry.isRevoked(id)
            }
        }
        registry.approve(deviceID: id, name: "Test fixture")
        XCTAssertTrue(observedApproval, "Published callbacks must see the new authorization snapshot")
        registry.revoke(deviceID: id)
        XCTAssertTrue(observedRevocation)
        registry.approve(deviceID: id, name: "Test fixture")
        XCTAssertTrue(registry.isApproved(id))
        XCTAssertFalse(registry.isRevoked(id))
        registry.revoke(deviceID: id)
        registry.forget(deviceID: id)
        subscription.cancel()
    }
}
