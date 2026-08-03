import Foundation
import ArgumentParser
import ClfCore

/// 클라이언트에 한 바이트도 쓰기 전에 어디까지 읽어야 하는지 확인한다.
///
/// 경계 판정이 SSE 릴레이 전체를 떠받친다. 여기서 틀리면 스왑 판정이 죽거나
/// 첫 프레임이 두 번 나간다. docs/porting/03-sse-streaming.md
struct SSEPeek: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sse-peek",
        abstract: "SSE 바이트에서 첫 이벤트 프레임 경계를 찾는다")

    @Argument(help: "SSE 원문 파일. - 면 stdin") var file: String

    func run() async throws {
        let data = file == "-"
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: file))
        let bytes = [UInt8](data)

        var cursor = 0
        var skipped = 0
        while true {
            guard let boundary = findSSEBoundary(bytes, from: cursor) else {
                print("  경계를 찾지 못했다. 스트림이 더 필요하다")
                print("  누적    \(bytes.count) 바이트")
                return
            }
            let nextStart = boundary.index + boundary.length
            if isCommentOnlyFrame(bytes[cursor..<boundary.index]) {
                skipped += 1
                cursor = nextStart
                continue
            }
            let head = Array(bytes[0..<nextStart])
            let tail = Array(bytes[nextStart...])

            print("  선행 주석 프레임 \(skipped)개")
            print("  첫 프레임 \(head.count) 바이트, 잔여 \(tail.count) 바이트")
            print()
            print("  --- 첫 프레임 ---")
            print(String(decoding: head, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  " + $0 }.joined(separator: "\n"))

            if let event = parseFirstSSEEvent(head) {
                print("  --- 파싱 ---")
                print("  event   \(event.event)")
                print("  data    \(event.data.prefix(200))")
            }
            return
        }
    }
}
