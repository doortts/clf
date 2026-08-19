import Foundation

/// 업데이트가 쓰는 자리들.
///
/// 캐시와 로그의 수명이 다르다. 받은 DMG 는 재부팅에 지워져도 되지만 교체
/// 실패 로그는 아니다. **교체 실패는 재부팅으로 조사하는 종류의 일이라**
/// 임시 폴더에 두면 정작 볼 때 없다.
public struct UpdatePaths: Sendable {
    /// `~/Library/Caches/clf/update`
    public let cacheRoot: URL
    /// `~/Library/Logs/clf`
    public let logRoot: URL

    public init(cacheRoot: URL? = nil, logRoot: URL? = nil) {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        self.cacheRoot = cacheRoot
            ?? caches.appendingPathComponent("clf").appendingPathComponent("update")
        self.logRoot = logRoot
            ?? library.appendingPathComponent("Logs").appendingPathComponent("clf")
    }

    /// 태그 하나가 쓰는 폴더. 받은 DMG 와 꺼낸 번들이 여기 같이 있다.
    public func staging(tag: String) -> URL {
        cacheRoot.appendingPathComponent(UpdateInstaller.slug(tag))
    }

    public func dmg(tag: String) -> URL {
        staging(tag: tag).appendingPathComponent("clf-\(UpdateInstaller.slug(tag)).dmg")
    }

    /// 마운트 지점을 우리가 정한다. `hdiutil` 이 알아서 고르게 두면 어디에
    /// 붙었는지 다시 알아내야 하고, 떼는 데 실패하면 Finder 에 볼륨이 쌓인다.
    public func mountPoint(tag: String) -> URL {
        staging(tag: tag).appendingPathComponent(".mount")
    }

    /// DMG 에서 꺼낸 번들. 이것을 helper 가 제자리에 넣는다.
    public func stagedApp(tag: String) -> URL {
        staging(tag: tag).appendingPathComponent("clf.app")
    }

    public func helper(tag: String) -> URL {
        staging(tag: tag).appendingPathComponent("install.sh")
    }

    /// `~/Library/Logs/clf/update-v0.5.0.log`
    public func log(tag: String) -> URL {
        logRoot.appendingPathComponent("update-\(UpdateInstaller.slug(tag)).log")
    }

    /// ETag 는 설정에 두지 않는다. 캐시 값이라 설정 파일과 수명이 다르고,
    /// 없으면 그냥 다시 받으면 된다.
    public var etag: URL { cacheRoot.appendingPathComponent("etag") }

    /// ETag 와 짝이 되는 응답 본문.
    ///
    /// **둘은 같이 있어야 한다.** ETag 만 남기면 `304` 를 받았을 때 손에 아무
    /// 값이 없다. 앱을 다시 켜면 메모리의 릴리즈는 사라지고 ETag 파일은 남으니,
    /// 그 상태에서 `304` 를 최신으로 읽으면 있는 새 버전을 영영 못 본다.
    public var latestJSON: URL { cacheRoot.appendingPathComponent("latest.json") }
}

/// 번들을 갈아 끼우는 쪽. 프로세스를 띄우지 않고 볼 수 있는 것만 여기 둔다.
///
/// 스크립트 문자열, 경로 결정, `spctl` 판정 셋이 실제로 틀릴 수 있는 것이고
/// 셋 다 순수 함수다. docs/design/14-self-update.html 8절
public enum UpdateInstaller {

    /// 태그를 파일 이름으로 쓸 수 있게 다듬는다.
    ///
    /// 태그 문자열은 우리가 만든 것이 아니라 **응답이 준 것**이다. `/` 가 든
    /// 태그는 실제로 있고, 그대로 경로에 넣으면 없는 폴더를 가리키거나 캐시
    /// 밖으로 나간다. 나간 자리를 helper 가 `rm -rf` 로 지운다.
    public static func slug(_ tag: String) -> String {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = cleaned.map { ch -> Character in
            if ch.isASCII, ch.isLetter || ch.isNumber { return ch }
            if ch == "." || ch == "-" || ch == "_" { return ch }
            return "-"
        }
        // 글자도 숫자도 없는 것은 이름이 아니다. `..` 하나가 통과하면 캐시의
        // 부모를 가리키고, 점과 붙임표만 남은 이름은 어차피 사람도 못 읽는다
        guard mapped.contains(where: { $0.isLetter || $0.isNumber }) else { return "unknown" }
        return String(mapped)
    }

    /// 쉘에 넘길 경로 하나. 공백과 인용부호가 든 경로가 진짜로 있다.
    ///
    /// 홑따옴표로 감싸고 안에 든 홑따옴표만 끊어 이어붙인다. 이 방식은
    /// 나머지 모든 문자를 글자 그대로 만든다.
    public static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 부모가 죽기를 기다리는 최대 시간. 0.5초씩 센다.
    public static let waitSteps = 30

    /// 앱 밖에서 돌 스크립트 본문.
    ///
    /// **자기를 지우면서 자기를 복사할 수는 없다.** 그래서 교체는 앱 밖에서
    /// 일어난다. 이 스크립트는 앱이 죽은 뒤에 도는 유일한 손이고, 그 시점에는
    /// 화면도 우리 프로세스도 없다. 실패하면 사용자에게는 앱이 다시 안 뜬다는
    /// 사실만 남으므로 **첫 줄에서 출력을 통째로 파일에 돌린다.**
    ///
    /// `set -e` 를 쓰지 않는다. 단계마다 실패를 직접 받아서 로그에 이유를
    /// 남기고, `mv` 가 반만 되면 옛 번들을 되돌려야 한다.
    public static func helperScript(bundle: URL, staged: URL, cache: URL,
                                   log: URL, pid: Int32) -> String {
        let b = quote(bundle.path)
        let new = quote(bundle.path + ".new")
        let old = quote(bundle.path + ".old")
        return """
        #!/bin/bash
        # clf 자동 업데이트. 앱이 죽은 뒤에 도는 유일한 손이다.
        # docs/design/14-self-update.html 5절
        exec >>\(quote(log.path)) 2>&1
        echo "[$(date)] 교체 시작. pid=\(pid)"

        # 1. 부모가 죽기를 기다린다. 돌고 있는 번들을 덮어쓰면 다음 실행이 깨진다
        waited=0
        while kill -0 \(pid) 2>/dev/null; do
          if [ "$waited" -ge \(waitSteps) ]; then
            echo "부모가 안 죽었다. 교체를 포기한다"
            exit 1
          fi
          sleep 0.5
          waited=$((waited + 1))
        done
        echo "부모 종료 확인"

        # 2. 먼저 옆에 다 복사해 둔다. ditto 는 서명과 확장 속성을 지킨다.
        #    cp -R 은 심볼릭 링크와 확장 속성을 흘려서 서명이 깨진다
        rm -rf \(new)
        if ! ditto \(quote(staged.path)) \(new); then
          echo "복사 실패. 원래 번들은 그대로 둔다"
          exit 1
        fi

        # 3. mv 두 번으로 자리를 바꾼다. 같은 볼륨에서 원자적이라 어느 순간에
        #    멈춰도 실행할 수 있는 번들이 한 자리에 있다
        rm -rf \(old)
        if ! mv \(b) \(old); then
          echo "옛 번들을 옮기지 못했다. 교체하지 않는다"
          rm -rf \(new)
          exit 1
        fi
        if ! mv \(new) \(b); then
          echo "새 번들을 제자리에 놓지 못했다. 옛 번들을 되돌린다"
          mv \(old) \(b)
          exit 1
        fi
        rm -rf \(old)
        echo "교체 완료"

        # 4. 다시 띄운다. 경로가 그대로라 로그인 항목 등록도 안 끊긴다
        if ! open \(b); then
          echo "다시 띄우지 못했다. 사용자가 직접 열어야 한다"
        fi

        # 5. 여기까지 왔으면 받은 것을 지운다. 실패한 경로는 위에서 이미 나갔고
        #    받아 둔 DMG 가 사용자에게 남는 가장 짧은 탈출구다
        rm -rf \(quote(cache.path))
        echo "[$(date)] 끝"

        """
    }

    /// `spctl -a -vv` 의 출력이 통과인지.
    ///
    /// **이것이 이 설계의 유일한 안전장치다.** 우리는 helper 에게 번들을
    /// 덮어쓸 권한을 준다. 릴리즈 자산이 바뀌었거나 중간에서 응답이 바뀌었을
    /// 때 그것을 걸러낼 곳은 여기뿐이다.
    ///
    /// 공증 없는 `source=Developer ID` 는 막는다. 서명만 우리 것이고 애플이
    /// 검사한 적은 없다는 뜻이다.
    public static func gatekeeperAccepted(_ output: String) -> Bool {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let accepted = lines.contains { $0 == "accepted" || $0.hasSuffix(": accepted") }
        let notarized = lines.contains { $0 == "source=Notarized Developer ID" }
        return accepted && notarized
    }

    /// 번들을 제자리에서 갈아 끼울 수 있는지.
    ///
    /// 관리자가 `/Applications` 에 넣어 둔 경우 사용자 권한으로는 못 바꾼다.
    /// 그때는 **직접 받기** 만 보여준다. 권한을 올려 달라고 물어보지 않는다.
    public static func canReplace(bundle: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }
}
