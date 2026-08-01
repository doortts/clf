# 11. 메뉴바 앱

[10 문서](10-desktop-usage.md)에서 데이터 계층을 다 만들었다. 남은 것은 화면이다.

---

## 1. Xcode 프로젝트를 두지 않는다

앱 번들은 세 가지만 있으면 된다.

```
clfl.app/Contents/MacOS/clfl        SPM 이 만든 실행 파일
clfl.app/Contents/Info.plist        LSUIElement 로 Dock 아이콘을 없앤다
                                    임시 서명. 없으면 로컬에서도 실행이 막힌다
```

Xcode 프로젝트를 두면 타겟 정의가 `Package.swift` 와 두 곳으로 갈라지고,
커맨드라인에서 빌드가 안 된다. `scripts/make-app.sh` 가 손으로 조립한다.

```
./scripts/make-app.sh          릴리스로 빌드하고 번들을 만든다
./scripts/make-app.sh debug    디버그로
open .build/clfl.app
```

`ClflApp` 은 평범한 SPM 실행 타겟이다. `swift build` 로 컴파일 오류를 바로 본다.

---

## 2. 무엇이 어디에 있나

| | |
|---|---|
| `ClflDesktop` | 읽기, 설정, 주기, 글자 만들기. 전부 테스트 가능 |
| `ClflApp` | SwiftUI 뷰와 상태 하나 |

뷰에서 테스트할 것이 남지 않게 갈랐다. 잔여를 몇 퍼센트로 쓸지, 이름을 어떻게
줄일지, 리셋까지 몇 시간인지는 전부 순수 함수라 `ClflDesktopTests` 가 잠근다.
`ClflApp` 에는 판단이 없다.

`UsageModel` 하나가 읽기와 설정과 주기를 쥔다. 뷰는 읽기만 한다.

---

## 3. 막대

```
84%
```

숫자 하나다. 그림 없이 글자만 쓴다. 잔여 숫자가 곧 아이콘이다.

**셋 중 가장 좁은 창을 보여준다.** 5시간이 97% 남아도 주간이 84% 면 84% 가
사실이다. 널널한 쪽을 보여주면 안심시키고 끝난다.

조직을 여럿 그릴 때는 이름을 줄인다.

```
T40 84%  T52 100%
```

숫자로 끝나는 이름은 앞 낱말의 첫 글자를 붙인다. `NAVER_TEAM_40` 은 `T40` 이다.
한 계정이 쓰는 조직들은 접두사가 같은 경우가 많아 뒤쪽이 구별에 쓸모 있다.
숫자로 안 끝나면 앞 세 글자를 쓴다. `Naver` 는 `Nav`.

사용량을 못 읽은 조직은 `?` 다. 0% 로 그리면 한도가 다 찬 것처럼 보인다.

---

## 4. 팝오버

```
  * NAVER_TEAM_40  [team]                      사용 중
      5시간        [==================..]   97%   4시간 38분 뒤
      주간 전체     [================....]   84%   5일 4시간 뒤
      주간 모델별   [===================.]   99%   5일 4시간 뒤

    NAVER_TEAM_52  [team]
      5시간        [====================]  100%   창 안 열림
      ...

    Naver
      앱에서 이 조직을 한 번 열면 사용량이 읽힌다

  설정  새로고침                        01:21 갱신  종료
```

막대에 무엇이 뜨든 팝오버에는 켜 둔 조직이 전부 나온다.

사용률 0% 인 창은 리셋 시각이 없다. `-` 로 얼버무리지 않고 `창 안 열림` 이라고
쓴다. 관측하지 못한 것과 0으로 관측한 것은 다르다.

읽기에 실패해도 이전 값을 지우지 않는다. 한 번 실패했다고 화면을 비우면
사용자가 알고 있던 것까지 잃는다. 실패는 위에 한 줄로 덧붙인다.

---

## 5. 설정

팝오버 안에서 접었다 편다. 창을 따로 띄울 만큼 항목이 많지 않다.

- 막대 범위: `활성 조직만` / `보이는 조직 전부`
- 조직마다 체크박스와 위아래 화살표

바뀌는 즉시 `~/Library/Application Support/clfl/desktop.json` 에 쓰고 화면에
반영한다. 확인 단추가 없다.

순서를 아직 안 정한 상태에서 화살표를 누르면, 지금 보이는 차례를 그대로 받아
거기서 한 칸 옮긴다. 사용자가 본 것과 다른 순서로 튀지 않는다.

---

## 6. 실기기에서 확인한 것

메뉴바 앱은 눈으로 봐야 한다. 그런데 이 기계에는 Bartender 5 가 있어서 새 항목이
숨김 영역으로 들어간다. 접근성 API 로 확인했다.

```
osascript -e 'tell application "System Events" to tell process "clfl" \
  to return value of attribute "AXTitle" of menu bar item 1 of menu bar 2'
-> 84%
```

`clflctl desktop usage --active` 가 같은 숫자를 낸다. 두 경로가 일치한다.

팝오버 자체는 화면 밖에 떠서 캡처가 안 됐다. 접근성 API 로 창을 화면 안으로
옮긴 뒤 찍었다.

```
osascript -e '... set position of window 1 to {300, 120}'
screencapture -x -R 280,100,360,440 popover.png
```

### 단추 이름

`Image(systemName: "chevron.up")` 에는 읽을 글자가 없다. 보이스오버가 아무 말도
못 한다. 전부 `accessibilityLabel` 을 붙였다.

AppleScript 의 `title of button` 은 `missing value` 를 준다. SwiftUI 가 이름을
`AXAttributedDescription` 에 넣는데 AppleScript 가 그걸 못 읽기 때문이다.
접근성 API 로 직접 읽으면 나온다.

```
AXButton  ->  설정 열기
AXButton  ->  지금 새로고침
AXButton  ->  clfl 종료
```

없는 것과 못 읽는 것은 다르다. 도구가 안 보여준다고 없다고 적으면 안 된다.

---

## 7. 로그인 항목

`SMAppService.mainApp` 으로 등록한다. 헬퍼 번들도 launchd plist 도 필요 없다.

### 실측으로 잡은 것

**한 번도 등록한 적이 없으면 `.notRegistered`(0) 가 아니라 `.notFound`(3) 가 온다.**

```
PROBE status=3 path=/Users/cpm4/Applications/clfl.app
PROBE register ok -> 1
```

이름만 보고 `.notFound` 를 "등록 불가" 로 읽었더니 체크박스가 처음부터 꺼진 채
잠겼다. 아무도 이 기능을 못 쓴다. 처음 상태가 그것이므로 `.off` 로 옮긴다.

진짜 불가능한 경우는 시스템에 묻지 않고 자리로 판별한다.

```swift
public static func isStableLocation(_ path: String) -> Bool {
    let volatile = ["/.build/", "/DerivedData/", "/Downloads/", "/tmp/"]
    guard !volatile.contains(where: { path.contains($0) }) else { return false }
    return path.contains("/Applications/")
}
```

`.build` 안에서 돌면 `make-app.sh` 가 다음 빌드에 번들을 지운다. 승인을 받아도
헛일이라 미리 막고 이유를 말한다. `scripts/install-app.sh` 가 `~/Applications`
로 옮긴다. 관리자 권한이 필요 없는 자리다.

### 승인 대기를 켜진 것으로 그리지 않는다

`.requiresApproval` 은 등록은 됐고 사용자가 시스템 설정에서 허용해야 하는
상태다. 체크된 것처럼 그리면 다음 부팅에 안 뜨는데 사용자는 이유를 모른다.
따로 표시하고 설정 화면을 열어주는 단추를 붙인다. 경로를 말로 설명하는 것보다
낫다.

우리가 원한 값이 아니라 시스템이 답한 값을 그린다. 등록이 승인 대기로 떨어질
수 있다.

---

## 8. 429

만들다가 만났다. Usage API 는 짧은 시간에 여러 번 부르면 429 를 준다.
개발 중에 앱을 몇 번 껐다 켜니 세 조직이 전부 막혔다.

```
NAVER_TEAM_40   Usage API HTTP 429
NAVER_TEAM_52   Usage API HTTP 429
```

두 가지를 고쳤다.

**말을 바꿨다.** `Usage API HTTP 429` 는 사용자가 할 수 있는 일을 안 알려준다.
`요청이 너무 잦다. 잠시 뒤 다시 읽는다` 로 쓴다.

**물러선다.** 429 는 실패와 다르다. 서버가 그만 물어보라고 한 것이다. 5분마다
계속 두드리면 창이 안 열린다. 한 번만 받아도 곧바로 15분으로 늘리고 풀리면
바로 돌아온다.

| 상황 | 주기 |
|---|---|
| 값이 변하고 있다 | 5분 |
| 세 번 연속 그대로 | 10분 |
| 못 읽었다 | 5분 (돌아오는 걸 빨리 알아야 한다) |
| **429** | **15분** |

읽기 실패와 429 를 가르는 것이 요점이다. 못 읽는 것은 빨리 되물어야 하고,
막힌 것은 물러나야 한다. 막힌 동안 값이 그대로인 것도 조용한 게 아니므로
연속 횟수를 세지 않는다.

앱이 정상으로 쓰는 주기는 5분에 조직 셋이라 여기 걸릴 일이 없다. 걸린 것은
개발 중 반복 실행 탓이다. 그래도 걸렸을 때 무엇을 하는지는 정해 둬야 한다.
