// swift-tools-version: 6.0
import PackageDescription

// ClflApp 은 SPM 실행 타겟이다. 앱 번들과 Info.plist 는 scripts/make-app.sh 가
// 손으로 조립한다. Xcode 프로젝트를 두면 타겟 정의가 두 곳으로 갈라지고
// 커맨드라인에서 빌드가 안 된다. docs/design/11-menubar-app.md

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
        // 메뉴바 앱. scripts/make-app.sh 가 번들로 감싼다
        .executable(name: "ClflApp", targets: ["ClflApp"]),
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

        .target(name: "ClflDesktop", dependencies: ["ClflCore", "ClflStore"]),

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

        .executableTarget(name: "ClflApp", dependencies: ["ClflDesktop"]),

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
