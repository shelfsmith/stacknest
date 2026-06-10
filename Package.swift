// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StackNest",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "StackroomFormat", targets: ["StackroomFormat"]),
        .library(name: "LibraryStore", targets: ["LibraryStore"]),
        .library(name: "ImageCache", targets: ["ImageCache"]),
        .library(name: "ArchiveAdapter", targets: ["ArchiveAdapter"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "LibraryServer", targets: ["LibraryServer"]),
        .executable(name: "stackroom-import", targets: ["StackroomImportCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "StackroomFormat",
            path: "Sources/StackroomFormat"
        ),
        .target(
            name: "LibraryStore",
            dependencies: [
                "StackroomFormat",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/LibraryStore",
            linkerSettings: [.linkedLibrary("icucore")]
        ),
        .target(
            name: "ImageCache",
            path: "Sources/ImageCache"
        ),
        .systemLibrary(
            name: "Carchive",
            path: "Sources/ArchiveAdapter/Carchive"
            // No pkgConfig — headers are resolved via __has_include in Carchive.h.
            // Linking uses the macOS SDK's universal libarchive.tbd (declared in module.modulemap)
            // so Universal (arm64 + x86_64) builds work even when Homebrew is arch-specific.
        ),
        .target(
            name: "ArchiveAdapter",
            dependencies: ["Carchive"],
            path: "Sources/ArchiveAdapter",
            exclude: ["Carchive"],
            linkerSettings: [.linkedLibrary("archive")]
        ),
        .target(
            name: "AppCore",
            dependencies: ["LibraryStore", "ArchiveAdapter", "Carchive"],
            path: "Sources/AppCore"
        ),
        .target(
            name: "LibraryServer",
            dependencies: [
                "LibraryStore",
                "AppCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/LibraryServer"
        ),
        .executableTarget(
            name: "StackroomImportCLI",
            dependencies: [
                "AppCore",
                "LibraryStore",
                "StackroomFormat",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/StackroomImportCLI"
        ),
        .testTarget(
            name: "StackroomFormatTests",
            dependencies: ["StackroomFormat"],
            path: "Tests/StackroomFormatTests",
            resources: [.copy("../Fixtures")]
        ),
        .testTarget(
            name: "LibraryStoreTests",
            dependencies: ["LibraryStore", "StackroomFormat"],
            path: "Tests/LibraryStoreTests",
            resources: [.copy("../Fixtures")]
        ),
        .testTarget(
            name: "ImageCacheTests",
            dependencies: ["ImageCache"],
            path: "Tests/ImageCacheTests"
        ),
        .testTarget(
            name: "ArchiveAdapterTests",
            dependencies: ["ArchiveAdapter"],
            path: "Tests/ArchiveAdapterTests",
            resources: [.copy("../Fixtures")]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "LibraryStore", "StackroomFormat"],
            path: "Tests/AppCoreTests",
            resources: [.copy("PDFFixtures")]
        ),
        .testTarget(
            name: "LibraryServerTests",
            dependencies: [
                "LibraryServer",
                "LibraryStore",
                "StackroomFormat",
                "AppCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/LibraryServerTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "StackroomImportCLITests",
            dependencies: ["StackroomImportCLI"],
            path: "Tests/StackroomImportCLITests",
            resources: [.copy("../Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
