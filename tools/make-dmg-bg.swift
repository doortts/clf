// DMG 창의 배경 그림을 그린다. 디자인 파일 대신 코드로 두는 이유는 아이콘
// 좌표와 배경의 화살표가 같은 값을 봐야 하기 때문이다. 둘이 어긋나면 화살표가
// 아이콘을 안 가리키고, 그건 눌러 보기 전에는 안 보인다.
// 결과물(png)은 커밋하지 않는다.
//
// 그림: docs/design/dmg-window-mockup.html 의 시안 C.
// 밝은 배경 위쪽에 이 앱이 설치되면 보게 될 메뉴바 막대를 옅게 그린다.
//
// 아이콘 라벨(clf.app, Applications)은 Finder 가 그린다. 여기서 그리는 것은
// 배경, 메뉴바 모티프, 화살표, 아래 안내 한 줄이다.
import AppKit
import Foundation

// 창 안쪽 치수. scripts/release.sh 의 AppleScript 가 같은 값을 쓴다
let W = 660.0
let H = 400.0

/// 아이콘 중심. AppleScript 의 `set position` 이 이 값을 그대로 받는다.
let leftIcon = NSPoint(x: 180, y: 180)
let rightIcon = NSPoint(x: 480, y: 180)
/// 아이콘 한 변. Finder 에 적는 값과 같아야 화살표가 아이콘에 안 겹친다.
let iconSide = 112.0

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let scale = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 1

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let bgTop = rgb(251, 251, 253)
let bgBottom = rgb(233, 234, 236)
let inkHint = rgb(110, 110, 115)
let inkBar = rgb(91, 91, 96)
let arrowInk = rgb(142, 142, 147)
// 게이지 색. README 의 표와 같다. 30% 이상 초록, 15% 이상 기본색,
// 5% 초과 노랑, 5% 이하 빨강. 주간 Fable 은 여유 구간에서만 파랑이다
let green = rgb(52, 199, 89)
let blue = rgb(10, 132, 255)
let yellow = rgb(255, 204, 0)
let neutral = rgb(142, 142, 147)

let px = Int(W * scale)
let py = Int(H * scale)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: scale, y: scale)

/// 시안은 좌상단 원점이고 AppKit 은 좌하단이다. 좌표는 시안 값을 그대로 적고
/// 그리는 자리에서만 뒤집는다. 시안과 코드를 눈으로 견줄 수 있어야 한다.
func flip(_ y: Double) -> Double { H - y }
/// 좌상단 기준 사각형.
func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSRect {
    NSRect(x: x, y: flip(y + h), width: w, height: h)
}

// ---- 배경 -----------------------------------------------------------------
// 시안의 170deg 다. AppKit 은 90 이 아래에서 위라 거의 반대쪽을 준다
NSGradient(starting: bgBottom, ending: bgTop)!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 95)

// ---- 메뉴바 모티프 --------------------------------------------------------
// 설치하면 무엇이 보이는지 설치 전에 한 번 보여준다. 옅게 둔다. 이 그림이
// 눈에 먼저 들어오면 끌어다 놓으라는 말을 가린다
let stripHeight = 34.0
NSColor.black.withAlphaComponent(0.055).setFill()
box(0, 0, W, stripHeight).fill()

let mono = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

/// 잔여로 색을 고른다. README 의 표가 이 함수다. 값을 바꾸면 색이 따라온다.
func gaugeColor(_ percent: Int, fable: Bool = false) -> NSColor {
    if percent >= 30 { return fable ? blue : green }
    if percent >= 15 { return neutral }
    if percent > 5 { return yellow }
    return rgb(255, 59, 48)
}

/// 계정 하나. 코드, 숫자 두 줄, 눈금 게이지 세 줄. 실제 막대와 같은 구성이다.
///
/// 게이지는 회색 트랙이 아니라 **상태색 테두리에 상태색 채움**이다. 트랙으로
/// 그리면 무채색 구간에서 채움이 트랙과 같은 색이 되어 사라진다.
/// 오른쪽 끝 x 를 받아서 왼쪽으로 그리고 다음 항목이 쓸 x 를 돌려준다.
func drawAccount(rightEdge: Double, code: String,
                 five: Int, week: Int, fable: Int) -> Double {
    let gaugeW = 30.0
    let rowH = 4.5
    let gap = 2.5
    var x = rightEdge - gaugeW

    // 위에서부터 5시간, 주간 전체, 주간 Fable
    let rows: [(Int, NSColor)] = [
        (five, gaugeColor(five)),
        (week, gaugeColor(week)),
        (fable, gaugeColor(fable, fable: true)),
    ]
    let stack = rowH * 3 + gap * 2
    var y = stripHeight / 2 - stack / 2
    for (percent, color) in rows {
        let outline = NSBezierPath(roundedRect: box(x + 0.5, y + 0.5,
                                                    gaugeW - 1, rowH - 1),
                                   xRadius: rowH / 2, yRadius: rowH / 2)
        outline.lineWidth = 1
        color.setStroke()
        outline.stroke()
        // 채움은 테두리 안쪽에 눕는다. 0 이어도 둥근 끝이 보이도록 최소폭을 준다
        let inner = gaugeW - 3
        color.setFill()
        NSBezierPath(roundedRect: box(x + 1.5, y + 1.5,
                                      max(inner * Double(percent) / 100, rowH - 3),
                                      rowH - 3),
                     xRadius: (rowH - 3) / 2, yRadius: (rowH - 3) / 2).fill()
        y += rowH + gap
    }

    // 숫자 두 줄. 게이지 왼쪽에 붙고 게이지 묶음과 같은 중심을 쓴다
    let para = NSMutableParagraphStyle()
    para.alignment = .right
    para.lineSpacing = 1
    let numsText = NSAttributedString(
        string: String(format: "%02d\n%02d", five, week),
        attributes: [.font: mono, .foregroundColor: inkBar, .paragraphStyle: para])
    let numsSize = numsText.size()
    x -= numsSize.width + 5
    numsText.draw(in: box(x, stripHeight / 2 - numsSize.height / 2,
                          numsSize.width, numsSize.height))

    // 계정 코드
    let codeText = NSAttributedString(string: code, attributes: [
        .font: monoBold, .foregroundColor: inkBar,
    ])
    let codeSize = codeText.size()
    x -= codeSize.width + 6
    codeText.draw(in: box(x, stripHeight / 2 - codeSize.height / 2,
                          codeSize.width, codeSize.height))
    return x - 18
}

// 오른쪽 끝에서 왼쪽으로. 메뉴바에서 우리 항목이 앉는 방향과 같다.
// 하나는 여유롭고 하나는 거의 다 썼다. 색이 갈리는 것이 이 앱의 요점이다
var edge = W - 18
edge = drawAccount(rightEdge: edge, code: "PRO", five: 34, week: 71, fable: 52)
_ = drawAccount(rightEdge: edge, code: "MAX", five: 8, week: 22, fable: 40)

// ---- 화살표 ---------------------------------------------------------------
// 아이콘 사이만 지난다. 아이콘 좌표에서 계산하므로 위에서 좌표를 옮기면
// 화살표가 따라온다
let arrowY = leftIcon.y
let arrowFrom = leftIcon.x + iconSide / 2 + 22
let arrowTo = rightIcon.x - iconSide / 2 - 22
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: arrowFrom, y: flip(arrowY)))
shaft.line(to: NSPoint(x: arrowTo - 12, y: flip(arrowY)))
shaft.lineWidth = 3
shaft.lineCapStyle = .round
shaft.setLineDash([9, 8], count: 2, phase: 0)
arrowInk.setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: arrowTo - 14, y: flip(arrowY - 8)))
head.line(to: NSPoint(x: arrowTo, y: flip(arrowY)))
head.line(to: NSPoint(x: arrowTo - 14, y: flip(arrowY + 8)))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
arrowInk.setStroke()
head.stroke()

// ---- 안내 한 줄 -----------------------------------------------------------
// 라벨은 Finder 가 아이콘 아래에 그린다. 그 아래로 충분히 내려야 겹치지 않는다
let center = NSMutableParagraphStyle()
center.alignment = .center
let hint = NSAttributedString(string: "clf.app 을 Applications 폴더로 끌어다 놓으세요",
                              attributes: [
    .font: NSFont.systemFont(ofSize: 13),
    .foregroundColor: inkHint,
    .paragraphStyle: center,
])
let hintHeight = hint.size().height
hint.draw(in: box(0, 338, W, hintHeight))

NSGraphicsContext.restoreGraphicsState()

// scale 을 곱해 그렸으므로 픽셀 크기가 다르다. 실제 표시 크기는 tiffutil 이
// 두 장을 한 파일로 묶을 때 정해진다
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("  배경 \(px)x\(py) 를 그렸다: \(out.lastPathComponent)")
