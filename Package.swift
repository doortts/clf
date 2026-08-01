// swift-tools-version: 6.0
import PackageDescription

// ClflApp 은 여기 없다. 앱 번들, Info.plist, 서명, 리소스가 필요해 SPM 실행 타겟으로
// 만들 수 없다. Xcode 프로젝트가 이 패키지를 로컬 의존성으로 참조한다.
// docs/design/04-implementation.md 2절

let package = Package(
    name: "clfl",
    platforms: [.macOS(.v13)],          // MenuBarExtra 요구 사항
    products: [
        .library(name: "ClflCore",  targets: ["ClflCore"]),
        .library(name: "ClflStore", targets: ["ClflStore"]),
        .library(name: "ClflProxy", targets: ["ClflProxy"]),
        // Claude 데스크톱 앱의 상태를 읽는다. 우리 저장소가 아니라 남의 것이라
        // ClflStore 와 섞지 않는다. docs/design/10-desktop-usage.md
        .library(name: "ClflDesktop", targets: ["ClflDesktop"]),
        // 앱 없이 단계별로 실행하고 내부 상태를 들여다보는 도구.
        // docs/design/08-verification.md
        .executable(name: "clflctl", targets: ["clflctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        // 의존성 0 이 이 구성의 핵심이다. NIO 가 한 번 들어오면 테스트가 이벤트
        // 루프를 요구하기 시작하고, claulay 에서 옮겨올 오프라인 테스트 자산이
        // 무너진다. docs/design/01-architecture.md 2절
        .target(name: "ClflCore"),

        .target(name: "ClflStore", dependencies: ["ClflCore"]),

        .target(name: "ClflDesktop", dependencies: ["ClflCore"]),

        .target(
            name: "ClflProxy",
            dependencies: [
                "ClflCore",
                "ClflStore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),

        .executableTarget(
            name: "clflctl",
            dependencies: [
                "ClflCore", "ClflStore", "ClflProxy", "ClflDesktop",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "ClflCoreTests",  dependencies: ["ClflCore"]),
        .testTarget(name: "ClflStoreTests", dependencies: ["ClflStore"]),
        .testTarget(name: "ClflDesktopTests", dependencies: ["ClflDesktop"]),
        // 가짜 업스트림을 소켓 수준에서 세운다. 프레이밍을 우리가 정해야
        // 청크 경계와 content-encoding 을 시험할 수 있다.
        .testTarget(
            name: "ClflProxyTests",
            dependencies: [
                "ClflProxy", "ClflStore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
