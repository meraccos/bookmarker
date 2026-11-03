// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Bookmarker", platforms: [.macOS(.v14)], products: [.executable(name: "Bookmarker", targets: ["Bookmarker"])], targets: [.target(name: "BookmarkCore"), .executableTarget(name: "Bookmarker", dependencies: ["BookmarkCore"]), .executableTarget(name: "BookmarkChecks", dependencies: ["BookmarkCore"], path: "Tests/BookmarkCoreTests")])
