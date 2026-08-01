// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-jpeg",
    products: [
        .library(
            name: "JPEG",
            targets: ["JPEG"]
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
    ]
)

for target in package.targets {
    var settings = target.swiftSettings ?? []
    settings.append(.enableUpcomingFeature("ExistentialAny"))
    target.swiftSettings = settings
}
