import Foundation
import ArgumentParser
import ClfStore

/// 앱 번들 없이 각 단계를 손으로 돌려보는 도구.
///
/// 목적은 두 가지다. 하나는 UI 를 만들기 전에 판정 계층을 실제로 실행해 보는 것,
/// 다른 하나는 프록시가 도는 동안 내부 상태를 밖에서 읽는 것이다.
/// docs/design/08-verification.md
struct CLFCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clfctl",
        abstract: "clf 단계별 실행과 상태 점검",
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
            Serve.self,
            Desktop.self,
        ]
    )
}

/// 진입점을 따로 둬서 명령을 돌리기 전에 한 마디 할 자리를 만든다.
///
/// `~/.local/bin/clfctl` 이 `.build/release/clfctl` 를 가리키는 심볼릭 링크라
/// 조용히 낡는다. 디버그 빌드로 검증해놓고 릴리스를 안 올린 채 다음 날
/// 옛 동작을 보는 일이 실제로 있었다.
@main
enum Entry {
    static func main() async {
        warnIfStale()
        await CLFCtl.main()
    }

    /// 경고만 하고 막지 않는다. 낡은 바이너리로도 하려던 일은 대개 된다.
    /// stdout 이 아니라 stderr 로 보낸다. --json 출력에 섞이면 안 된다.
    private static func warnIfStale() {
        guard let root = BuildFreshness.packageRoot,
              let binary = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let warning = BuildFreshness.warning(executable: binary, sourceRoot: root)
        else { return }
        FileHandle.standardError.write(Data((warning + "\n\n").utf8))
    }
}
