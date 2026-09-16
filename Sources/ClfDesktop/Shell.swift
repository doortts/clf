import Foundation

/// 짧은 조회 명령 하나를 돌리고 표준 출력을 받는다. 못 받으면 nil 이다.
///
/// **실패와 빈 출력을 가른다.** 둘을 같은 빈 문자열로 뭉뚱그리면 잘린 결과가
/// 옳은 결과 행세를 한다. 이 함수를 부르는 쪽은 그 답으로 "앱이 꺼져 있다" 나
/// "창이 하나도 없다" 를 말하므로 구별이 곧 정직함이다.
///
/// **아무도 안 읽는 파이프를 자식에게 주지 않는다.** `standardError` 에
/// `Pipe()` 를 꽂아 두고 읽지 않으면, 자식이 stderr 로 64KB 를 넘게 뱉는 순간
/// write 에서 막히고 `waitUntilExit()` 는 영원히 안 돌아온다. 죽은 마운트가
/// 있는 기계에서 `lsof` 가 마운트마다 경고 한 줄씩 뱉는 것이 딱 그 경우다.
///
/// 그러면 `UsageModel.refresh` 의 `refreshing` 이 선 채로 굳고 **Claude 도
/// Codex 도 다시는 안 읽힌다.** 화면은 옛 숫자를 든 채 조용해서 사용자는 멈춘
/// 줄도 모른다.
///
/// 시한은 **최선을 다할 뿐 보장이 아니다.** 자식이 손자를 남기고 그 손자가 우리
/// 출력 파이프를 물려받았으면, 자식을 죽여도 파이프가 안 닫혀 읽기가 안 끝난다.
/// `lsof` 가 정확히 그런 프로그램이라 그쪽은 `-S` 로 lsof 자신에게 시한을 건다.
enum Shell {
    static func run(_ path: String, _ arguments: [String],
                    timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let gate = ExitGate()
        let pid = process.processIdentifier
        let killer = DispatchWorkItem { gate.terminate(pid) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        gate.reap(process)
        killer.cancel()
        guard !gate.timedOut else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 자식이 끝났는지를 시한 타이머와 나눠 본다.
private final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var killed = false

    /// 시한에 걸렸나. 걸렸으면 출력이 잘렸으므로 답으로 쓰면 안 된다.
    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return killed
    }

    /// **기다리는 일을 문 밖에서 한다.** 문을 쥔 채 기다리면 시한 타이머가 그
    /// 문에 걸려 자식이 죽을 때까지 못 움직인다. 시한이 이름만 남는다. 출력을
    /// 닫고 남아 있는 자식에서 실측으로 1초짜리 시한이 6초까지 끌려갔다.
    ///
    /// 남는 위험은 좁다. 자식이 거둬져 pid 가 풀린 뒤 이 문을 닫기 전에 타이머가
    /// 뜨면 재사용된 pid 로 신호가 간다. 창이 마이크로초이고 그 순간에 시한이
    /// 만료돼야 한다. 문을 쥐고 기다리는 대가가 초 단위라 이쪽을 택했다.
    func reap(_ process: Process) {
        process.waitUntilExit()
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// TERM 을 먼저 보내고 그래도 살아 있으면 KILL 로 올린다. 신호를 한 번만
    /// 보내면 TERM 을 무시하는 자식이 영원히 산다.
    func terminate(_ pid: pid_t) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        killed = true
        kill(pid, SIGTERM)
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            kill(pid, SIGKILL)
        }
    }
}
