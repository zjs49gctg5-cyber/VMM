// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VMM",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "VMM", targets: ["VMM"]), .executable(name:"VMMMCPBridge",targets:["VMMMCPBridge"]), .executable(name:"VMMAnimationWorker",targets:["VMMAnimationWorker"])],
    targets: [.target(name:"MCPTransport"), .executableTarget(name:"VMMMCPBridge",dependencies:["MCPTransport"]), .systemLibrary(name: "CZlib"), .target(name:"CAnimationSupport"), .target(name:"AnimationScriptRuntime",dependencies:["CAnimationSupport"]), .executableTarget(name:"VMMAnimationWorker",dependencies:["AnimationScriptRuntime"]), .executableTarget(name: "VMM", dependencies: ["CZlib","AnimationScriptRuntime","MCPTransport"]), .testTarget(name: "VMMTests", dependencies: ["VMM"])]
)
