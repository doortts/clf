// 앱 아이콘을 그린다. 디자인 파일 대신 코드로 두는 이유는 색과 비율을 고치고
// 다시 돌리면 끝나기 때문이다. 결과물(.icns)은 커밋하지 않는다.
//
// 그림: 몬드리안 오마주. 검은 격자가 clf 세 글자를 만들고 빨강 노랑 파랑
// 블록이 구석을 잡는다. 시안과 좌표가 같다.
// docs/design/icon-artist-mockups.html
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let paper  = NSColor(srgbRed: 0.965, green: 0.949, blue: 0.910, alpha: 1)
let black  = NSColor(srgbRed: 0.082, green: 0.082, blue: 0.082, alpha: 1)
let red    = NSColor(srgbRed: 0.835, green: 0.204, blue: 0.165, alpha: 1)
let yellow = NSColor(srgbRed: 0.949, green: 0.788, blue: 0.298, alpha: 1)
let blue   = NSColor(srgbRed: 0.141, green: 0.337, blue: 0.643, alpha: 1)

/// 시안 좌표 그대로. 원점이 좌상단인 256 칸이고 그릴 때 뒤집는다.
/// f 의 팔을 오른쪽 기둥에 붙이면 한글 'ㅐ' 로 읽힌다. 사이를 띄운 값이다.
let shapes: [(x: Double, y: Double, w: Double, h: Double, color: NSColor)] = [
    // c: 오른쪽이 열린 사각
    (30, 72, 66, 12, black),
    (30, 72, 12, 112, black),
    (30, 172, 66, 12, black),
    // l: 기둥 하나
    (118, 40, 12, 144, black),
    // f: 기둥과 그것을 관통하는 팔 둘
    (158, 40, 12, 144, black),
    (146, 40, 50, 12, black),
    (146, 104, 42, 12, black),
    // 지면이 되는 수평선과 오른쪽 기둥
    (0, 196, 256, 12, black),
    (214, 0, 12, 196, black),
    // 색 블록. 블록은 반드시 검은 선과 한 변을 나눈다
    (226, 0, 30, 76, red),
    (226, 76, 30, 12, black),
    (0, 208, 60, 48, yellow),
    (56, 208, 12, 48, black),
    (196, 208, 60, 48, blue),
    (196, 208, 12, 48, black),
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
    paper.setFill()
    NSBezierPath(rect: NSRect(x: inset, y: inset, width: side, height: side)).fill()

    let k = side / 256
    for r in shapes {
        // 좌상단 원점을 AppKit 의 좌하단 원점으로 뒤집는다. 16px 에서는
        // 12칸 선이 1px 아래로 내려가 사라지므로 1px 로 받친다
        let rect = NSRect(x: inset + r.x * k,
                          y: inset + (256 - r.y - r.h) * k,
                          width: max(r.w * k, 1),
                          height: max(r.h * k, 1))
        r.color.setFill()
        NSBezierPath(rect: rect).fill()
    }

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
