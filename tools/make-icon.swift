// 앱 아이콘을 그린다. 디자인 파일 대신 코드로 두는 이유는 색과 비율을 고치고
// 다시 돌리면 끝나기 때문이다. 결과물(.icns)은 커밋하지 않는다.
//
// 그림: 유아사 마사아키 오마주. 손으로 그린 듯 흔들리는 획이 clf 를 만들고,
// 마젠타 판이 한 칸 밀려 있는 인쇄 사고 같은 색이 뒤에 깔린다. 시안과
// 좌표가 같다. docs/design/icon-anime-mockups.html
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let teal    = NSColor(srgbRed: 0.071, green: 0.647, blue: 0.627, alpha: 1)
let magenta = NSColor(srgbRed: 0.878, green: 0.271, blue: 0.482, alpha: 1)
let cream   = NSColor(srgbRed: 0.992, green: 0.953, blue: 0.847, alpha: 1)
let yellow  = NSColor(srgbRed: 1.000, green: 0.824, blue: 0.247, alpha: 1)
let dark    = NSColor(srgbRed: 0.141, green: 0.114, blue: 0.239, alpha: 1)

/// 획 하나 = [시작x, 시작y, 그다음부터 6개씩 (제어1, 제어2, 끝)].
/// 시안 SVG 의 cubic 경로 그대로다. 원점이 좌상단인 256 칸이고 그릴 때 뒤집는다.
let letterC: [Double] = [92, 84, 64, 76, 50, 96, 53, 120, 56, 147, 76, 158, 95, 149]
let letterL: [Double] = [122, 58, 117, 90, 131, 104, 122, 146]
let letterF: [Double] = [163, 54, 156, 92, 170, 110, 161, 150]
let armTop: [Double] = [147, 90, 166, 81, 182, 86, 197, 79]
let armMid: [Double] = [149, 122, 166, 115, 180, 120, 191, 115]
/// 구석에서 도는 소용돌이 해.
let sun: [Double] = [206, 52, 222, 44, 236, 54, 234, 68, 232, 80, 220, 86, 210, 80,
                     202, 74, 204, 62, 212, 60, 218, 58, 224, 64, 220, 69]
/// 지렁이 선 둘. 시안의 q(2차) 곡선을 3차로 바꾼 값이다.
let wave1: [Double] = [28, 206, 34.67, 199.33, 41.33, 199.33, 48, 206,
                       54.67, 212.67, 61.33, 212.67, 68, 206,
                       74.67, 199.33, 81.33, 199.33, 88, 206]
let wave2: [Double] = [30, 228, 35.33, 222.67, 40.67, 222.67, 46, 228,
                       51.33, 233.33, 56.67, 233.33, 62, 228]

/// 글자 획과 굵기. 마젠타 판과 크림 판이 같은 경로를 쓴다.
let letters: [(path: [Double], width: Double)] = [
    (letterC, 18), (letterL, 18), (letterF, 18), (armTop, 13), (armMid, 11),
]

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = Double(px)

    // macOS 아이콘 여백. 꽉 채우면 다른 앱 아이콘보다 커 보인다
    let inset = s * 0.09
    let side = s - inset * 2
    let plate = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                             xRadius: side * 0.225, yRadius: side * 0.225)
    plate.addClip()
    teal.setFill()
    NSBezierPath(rect: NSRect(x: inset, y: inset, width: side, height: side)).fill()

    let k = side / 256

    /// 좌상단 원점 경로를 AppKit 의 좌하단 원점으로 뒤집어 긋는다.
    /// 16px 에서는 획이 1px 아래로 내려가 사라지므로 1px 로 받친다.
    func stroke(_ pts: [Double], width: Double, color: NSColor,
                dx: Double = 0, dy: Double = 0) {
        func at(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: inset + (x + dx) * k, y: inset + (256 - (y + dy)) * k)
        }
        let p = NSBezierPath()
        p.move(to: at(pts[0], pts[1]))
        var i = 2
        while i + 5 < pts.count {
            p.curve(to: at(pts[i + 4], pts[i + 5]),
                    controlPoint1: at(pts[i], pts[i + 1]),
                    controlPoint2: at(pts[i + 2], pts[i + 3]))
            i += 6
        }
        p.lineWidth = max(width * k, 1)
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }

    // 어긋난 마젠타 판이 먼저, 크림 획이 위에. 시안처럼 마젠타는 전부 18 굵기라
    // 가는 팔 뒤로 삐져나오는 폭이 더 크다. 그게 인쇄 사고의 맛이다
    for l in letters { stroke(l.path, width: 18, color: magenta, dx: 7, dy: 6) }
    for l in letters { stroke(l.path, width: l.width, color: cream) }

    stroke(sun, width: 5, color: yellow)
    stroke(wave1, width: 4, color: cream.withAlphaComponent(0.85))
    stroke(wave2, width: 4, color: dark.withAlphaComponent(0.7))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for px in sizes {
    let data = draw(px).representation(using: .png, properties: [:])!
    // iconutil 이 요구하는 이름 규칙. 512@2x 가 1024 다
    if px <= 512 { try data.write(to: out.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try data.write(to: out.appendingPathComponent("icon_\(px/2)x\(px/2)@2x.png")) }
}
print("  \(sizes.count)개 크기를 그렸다")
