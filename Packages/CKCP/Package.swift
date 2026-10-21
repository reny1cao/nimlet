// swift-tools-version:5.9
// KCP, the ARQ protocol RustDesk runs its direct UDP paths on — the C original
// by Lin Wei (skywind3000/kcp @ 32da082, MIT, see LICENSE), unmodified. Swift
// talks to it through `DirectLink/DirectTunnel.swift`.
import PackageDescription

let package = Package(
    name: "CKCP",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CKCP", targets: ["CKCP"])],
    targets: [.target(name: "CKCP", path: "Sources/CKCP", publicHeadersPath: "include")]
)
