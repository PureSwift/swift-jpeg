// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-jpeg",
    products: [
        .library(
            name: "JPEG",
            targets: ["JPEG"]
        ),
        .library(
            name: "JPEGAccelerate",
            targets: ["JPEGAccelerate"]
        ),
        .executable(
            name: "jpeg-benchmark",
            targets: ["JPEGBenchmark"]
        ),
        .library(
            name: "TurboJPEGABI",
            type: .dynamic,
            targets: ["TurboJPEGABI"]
        ),
    ],
    targets: [
        // The codec engine.
        //
        // This target imports nothing, not even Foundation, and must stay that
        // way: it is what allows the library to build for Embedded Swift and to
        // be reused behind a C ABI without dragging a platform layer along.
        // Byte input and output are abstracted behind protocols in
        // `Bytestream.swift` rather than being performed here.
        .target(name: "JPEG"),

        // The vendored TurboJPEG header, plus generated stubs for the exported
        // symbols that are not implemented yet.
        .target(
            name: "CTurboJPEG",
            exclude: ["LICENSE"]
        ),

        // Runtime processor feature detection. C because Swift has neither
        // inline assembly nor a cpuid intrinsic.
        .target(name: "CCPUFeatures"),

        // Accelerated kernels, selected at run time. Compiled for the baseline;
        // only the individual kernels carry a target attribute, so this builds
        // and runs anywhere and uses AVX2 only where cpuid permits.
        .target(
            name: "CJPEGAccel",
            dependencies: ["CCPUFeatures"]
        ),

        // Installs the accelerated kernels into the engine's dispatch seam.
        // Separate from the engine because it imports things and the engine
        // must not.
        .target(
            name: "JPEGAccelerate",
            dependencies: ["JPEG", "CJPEGAccel", "CCPUFeatures"]
        ),

        // The benchmark. Imports Foundation freely — the no-imports rule
        // applies to the engine, not to what measures it.
        .executableTarget(
            name: "JPEGBenchmark",
            dependencies: ["JPEG", "JPEGAccelerate"]
        ),

        // The C ABI boundary. Depends on the engine; the engine knows nothing
        // about it, which is the point.
        .target(
            name: "TurboJPEGABI",
            dependencies: ["JPEG", "CTurboJPEG", "JPEGAccelerate"]
        ),

        // Tests may import Foundation freely — the no-imports rule applies to
        // the engine, not to what exercises it.
        .testTarget(
            name: "JPEGTests",
            dependencies: ["JPEG", "JPEGAccelerate"],
            resources: [.copy("Images")]
        ),
    ]
)

for target in package.targets {
    var settings = target.swiftSettings ?? []
    settings.append(.enableUpcomingFeature("ExistentialAny"))
    target.swiftSettings = settings
}
