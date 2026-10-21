import XCTest
import Network

final class LaunchNetworkPolicyTests: XCTestCase {
    func testLocalAndLinkLocalAddresses() {
        for host in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.2", "169.254.2.3", "127.0.0.1", "::1", "fe80::1234%en0", "fd12::1", "My-Mac.local", "mac.local."] {
            XCTAssertTrue(LaunchNetworkPolicy.allows(host: host), host)
        }
    }
    func testInternetAndMisleadingLocalNamesAreRejected() {
        for host in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.1.2", "100.64.0.1", "2001:4860:4860::8888", "mac.local.evil.com", "example.com", "", "999.1.1.1", "::ffff:8.8.8.8"] {
            XCTAssertFalse(LaunchNetworkPolicy.allows(host: host), host)
        }
    }
    func testBonjourIsLimitedToLocalDomain() {
        XCTAssertTrue(LaunchNetworkPolicy.allows(endpoint: .service(name: "Mac", type: "_mice._tcp", domain: "local.", interface: nil)))
        XCTAssertFalse(LaunchNetworkPolicy.allows(endpoint: .service(name: "Mac", type: "_mice._tcp", domain: "example.com", interface: nil)))
        #if MICE_LAN_ONLY
        XCTAssertFalse(LaunchNetworkPolicy.allowsAwayAccess)
        #else
        XCTAssertTrue(LaunchNetworkPolicy.allowsAwayAccess)
        #endif
    }
}
