// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PMuxViewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PMuxViewer", targets: ["PMuxViewer"]),
    ],
    targets: [
        // C bridge wrapping parsec-dso.h for Swift
        .target(
            name: "CParsecBridge",
            path: "Sources/CParsecBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-Wno-unused-function", "-Wno-missing-field-initializers"]),
            ],
            linkerSettings: [
                .linkedFramework("OpenGL"),
            ]
        ),

        // Main Swift app
        .executableTarget(
            name: "PMuxViewer",
            dependencies: ["CParsecBridge"],
            path: "Sources/PMuxViewer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Security"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("GameController"),
                .linkedFramework("OpenGL"),
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),

        .testTarget(
            name: "PMuxViewerTests",
            dependencies: ["CParsecBridge"],
            path: "Tests/PMuxViewerTests"
        ),
    ]
)
