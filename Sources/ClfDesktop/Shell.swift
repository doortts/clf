import Foundation

/// 짧은 조회 명령 하나를 돌리고 표준 출력을 받는다.
///
/// **두 가지를 반드시 지킨다.** 둘 다 안 지키면 갱신 루프가 통째로 죽는다.
///
/// 하나. **아무도 안 읽는 파이프를 자식에게 주지 않는다.** `standardError` 에
/// `Pipe()` 를 꽂아 두고 읽지 않으면, 자식이 stderr 로 64KB 를 넘게 뱉는 순간
/// write 에서 막히고 우리 `waitUntilExit()` 는 영원히 안 돌아온다. 죽은
/// 마운트가 있는 기계에서 `lsof` 가 마운트마다 경고 한 줄씩 뱉는 것이 딱 그
/// 경우다.
///
/// 둘. **시한을 건다.** 자식이 다른 이유로 멈춰도 여기서 빠져나온다.
/// `UsageModel.refresh` 는 `refreshing` 을 세워 두고 `defer` 로 내리는데, 이
/// 함수가 안 돌아오면 그 `defer` 가 영영 안 돌고 **Claude 도 Codex 도 다시는
/// 안 읽힌다.** 화면은 옛 숫자를 든 채 조용해서 사용자는 멈춘 줄도 모른다.
enum Shell {
    static func run(_ path: String, _ arguments: [String],
                    timeout: TimeInterval = 5) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }

        let gate = ExitGate()
        let pid = process.processIdentifier
        let killer = DispatchWorkItem { gate.terminateIfRunning(pid) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 문을 먼저 닫고 예약을 거둔다. 이 차례라야 이미 뜬 타이머도 헛손질한다.
        // 반대로 하면 그 틈에 재사용된 pid 로 남의 프로세스에 신호를 보낸다
        gate.finish()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 자식이 끝났는지를 시한 타이머와 나눠 본다.
private final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func terminateIfRunning(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        kill(pid, SIGTERM)
    }
}
