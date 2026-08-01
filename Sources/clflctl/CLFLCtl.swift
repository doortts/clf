import Foundation
import ArgumentParser

/// 앱 번들 없이 각 단계를 손으로 돌려보는 도구.
///
/// 목적은 두 가지다. 하나는 UI 를 만들기 전에 판정 계층을 실제로 실행해 보는 것,
/// 다른 하나는 프록시가 도는 동안 내부 상태를 밖에서 읽는 것이다.
/// docs/design/08-verification.md
@main
struct CLFLCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clflctl",
        abstract: "clfl 단계별 실행과 상태 점검",
        discussion: """
        모든 명령은 --data-dir 과 --claude-dir 로 대상 디렉토리를 바꿀 수 있다.
        실제 설정을 건드리지 않고 실험하려면 임시 디렉토리를 준다.
        """,
        subcommands: [
            Doctor.self,
            Settings.self,
            Accounts.self,
            Runtime.self,
            Select.self,
            Classify.self,
            SSEPeek.self,
            Upstream.self,
        ]
    )
}
