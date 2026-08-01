// 앱 아이콘을 그린다. 디자인 파일 대신 코드로 두는 이유는 색과 비율을 고치고
// 다시 돌리면 끝나기 때문이다. 결과물(.icns)은 커밋하지 않는다.
//
// 그림: 둥근 사각형 위에 잔여 막대 셋. 팝오버가 보여주는 것과 같은 모양이라
// 메뉴바 목록에서 봐도 무엇인지 안다.
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// 잔여가 많은 것부터. 실제 화면에서도 5시간이 대개 제일 여유 있다.
let bars: [(fill: Double, color: NSColor)] = [
    (0.92, NSColor(srgbRed: 0.20, green: 0.82, blue: 0.35, alpha: 1)),
    (0.62, NSColor(srgbRed: 0.20, green: 0.82, blue: 0.35, alpha: 1)),
    (0.34, NSColor(srgbRed: 1.00, green: 0.72, blue: 0.10, alpha: 1)),
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
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
               ending:   NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1))!
        .draw(in: plate, angle: -90)

    let barH = side * 0.108
    let gap = side * 0.088
    let left = inset + side * 0.17
    let track = side * 0.66
    let total = barH * 3 + gap * 2
    var y = inset + (side - total) / 2 + total - barH

    for bar in bars {
        let bg = NSBezierPath(roundedRect: NSRect(x: left, y: y, width: track, height: barH),
                              xRadius: barH / 2, yRadius: barH / 2)
        NSColor.white.withAlphaComponent(0.13).setFill()
        bg.fill()

        let w = max(barH, track * bar.fill)
        let fg = NSBezierPath(roundedRect: NSRect(x: left, y: y, width: w, height: barH),
                              xRadius: barH / 2, yRadius: barH / 2)
        bar.color.setFill()
        fg.fill()
        y -= barH + gap
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
