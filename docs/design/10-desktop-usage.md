# 10. 데스크톱 앱 사용량 읽기

[09 문서](09-desktop-org-switch.md)에서 데스크톱 앱의 자동 전환을 하지 않기로 정했다.
그러면 남는 일은 하나다. **계정별 잔여를 보여주는 것.**

앱은 활성 계정 하나의 사용량만 보여준다. 나머지가 얼마나 남았는지는 일일이
전환해 봐야 안다. 이 문서는 그 셋을 한 번에 읽는 방법이다.

---

## 1. 앱이 보여주는 세 줄

```
5-hour limit          Resets in 3 hr 1 min   15%
Weekly - all models   Resets Fri 6:00 AM     11%
Weekly - Fable                                0%
```

이 셋의 출처는 `https://api.anthropic.com/api/oauth/usage` 다.

```json
{
  "limits": [
    {"kind": "session",       "percent": 48, "resets_at": "...", "severity": "normal"},
    {"kind": "weekly_all",    "percent": 15, "resets_at": "...", "severity": "normal"},
    {"kind": "weekly_scoped", "percent": 1,  "resets_at": "...", "severity": "normal"}
  ],
  "five_hour": {"utilization": 48.0, "resets_at": "..."},
  "seven_day": {"utilization": 15.0, "resets_at": "..."}
}
```

`percent` 는 **사용률**이다. 잔여는 `100 - percent` 로 파생시킨다.
`limits` 배열이 세 줄을 그대로 담으므로 그것만 읽으면 된다.

단 팀 계정에 한한다. Enterprise 는 `limits` 가 비어 있고 `spend` 로 월 예산이
온다. [12 문서](12-enterprise-spend.md)

---

## 2. 스코프 문제와 그 해법

이 엔드포인트는 `user:profile` 스코프를 요구한다.

```
403 {"type":"error","error":{"type":"permission_error",
     "message":"OAuth token does not meet scope requirement user:profile"}}
```

`claude setup-token` 이 주는 토큰은 `user:inference` 뿐이라 여기서 막힌다.
[08 검증](08-verification.md) 7-5절에서 확인한 그대로다.

**그런데 데스크톱 앱이 쓰는 토큰에는 그 스코프가 있다.**

앱은 계정별 OAuth 토큰을 `config.json` 의 `oauth:tokenCacheV2` 에 캐시한다.
캐시 키가 스코프까지 담고 있어 눈으로 확인된다.

```
9d1c250a-...:746e81ae-...:https://api.anthropic.com:user:inference user:file_upload user:profile user:sessions:claude_code
             ^^^^^^^^^^^ 계정 uuid                                                  ^^^^^^^^^^^^ 이게 필요했다
```

값은 Chromium safe storage 로 암호화돼 있고, 키는 [09 문서](09-desktop-org-switch.md)
3절에서 이미 푼 그 키다.

```
키   = PBKDF2-SHA1(Keychain["Claude Safe Storage"], "saltysalt", 1003회, 16바이트)
IV   = 0x20 * 16
값   = "v10" + AES-128-CBC(...)
```

쿠키와 달리 이쪽은 base64 로 감싸여 있고 32바이트 도메인 해시 접두사가 없다.
바로 JSON 이다.

---

## 3. 토큰을 소모하지 않는다

이것이 응답 헤더 편승과 갈리는 지점이다.

| | 응답 헤더 | Usage API |
|---|---|---|
| 요청이 필요한가 | **그렇다.** 실제 추론 요청에 편승 | 아니다. 읽기 전용 호출 |
| 얻는 것 | 5시간, 주간 전체 | **셋 다.** 모델별 주간 포함 |
| 비활성 계정 | 못 읽는다 | **읽는다** |
| 필요한 스코프 | 없음 | `user:profile` |

메뉴바가 주기적으로 갱신해야 하므로 요청을 소모하지 않는 쪽이 유일하게 쓸 만하다.

---

## 4. 도구

Swift 로 옮겼다. `ClfDesktop` 타겟이 본체이고 메뉴바 앱이 이걸 그대로 쓴다.

```
clfctl desktop usage            표로
clfctl desktop usage --json     기계가 읽을 형태로
clfctl desktop usage --active   활성 계정만
```

`scripts/desktop-usage.py` 가 먼저 만든 원형이었다. 두 구현이 같은 숫자를 내는
것을 확인한 뒤 한동안 대조용으로 두었는데, **지금은 지웠다.** Swift 쪽에 세션
폴백과 별도 창 토큰 병합이 들어가면서 원형이 뒤처졌고, 틀린 답을 내는 대조본은
대조가 아니다.

### 무엇을 테스트로 잠갔나

파일과 Keychain 과 네트워크를 뺀 나머지가 전부 순수 함수다.

| 테스트 | 잡는 것 |
|---|---|
| `parseUsage` | `limits` 배열 해석, 모르는 `kind` 무시, 마이크로초 타임스탬프 |
| `safeStorageKey` | PBKDF2 파라미터. 하나만 틀려도 실제 데이터를 못 푼다 |
| `decryptV10` / `encryptV10` | 왕복. 접두사 없는 값은 손대지 않는다 |
| `parseTokenCache` | 캐시 키에서 계정 uuid 뽑기, `user:profile` 판정 |
| 스냅샷 조립 | 활성 계정 우선, 한 계정 실패가 나머지를 죽이지 않음 |

`UsageFetching` 프로토콜이 네트워크 경계다. 테스트는 가짜를 꽂는다.

```
* NAVER_TEAM_40  (지금 앱에서 쓰는 계정)
    5시간        [##########..........] 잔여  51%   29분 뒤 리셋
    주간 전체      [###.................] 잔여  85%   5일 5시간 뒤 리셋
    주간 모델별     [....................] 잔여  99%   5일 5시간 뒤 리셋

  NAVER_TEAM_52
    5시간        [....................] 잔여 100%   창 안 열림
    주간 전체      [....................] 잔여 100%   창 안 열림
    주간 모델별     [....................] 잔여 100%   창 안 열림

  아직 못 읽는 계정: Naver
  앱에서 한 번 열면 토큰이 캐시돼 다음부터 읽힌다
```

활성 계정을 맨 위에 둔다. 잔여 15% 아래면 `주의` 를 붙인다.

---

## 5. 두 가지 한계

**앱에서 한 번도 열지 않은 계정은 못 읽는다.** 토큰 캐시에 없기 때문이다.
위 예에서 `Naver` 가 그렇다. 계정 목록은 세션 쿠키로 얻으므로 이름은 알지만
사용량은 모른다. 그 사실을 숨기지 않고 말한다.

**사용률 0% 인 창은 리셋 시각이 없다.** 창이 아직 안 열린 것이다. `-` 로 얼버무리지
않고 `창 안 열림` 이라고 쓴다. 관측하지 못한 것과 0으로 관측한 것은 다르다.

토큰이 만료되면 401 이 온다. 그때도 앱에서 그 계정을 한 번 열면 갱신된다.
갱신은 앱이 하게 두고 우리는 읽기만 한다.

---

## 6. 이것이 메뉴바에 뜻하는 것

`--json` 이 그대로 UI 의 입력이다.

```json
[{"uuid": "...", "name": "NAVER_TEAM_40", "active": true,
  "plan": "team", "tier": "default_claude_max_5x",
  "limits": {"session":       {"percent": 49, "resets_at": "...", "severity": "normal"},
             "weekly_all":    {"percent": 15, "resets_at": "...", "severity": "normal"},
             "weekly_scoped": {"percent": 1,  "resets_at": "...", "severity": "normal"}}}]
```

[ui-spec.html](ui-spec.html) 의 도트 블록 3줄이 이 셋에 그대로 대응한다.
세 줄 = session / weekly_all / weekly_scoped.

`severity` 는 서버가 직접 주는 경고 등급이다. 우리가 임계값을 정하는 대신 이 값을
쓸 수 있는지 살펴볼 만하다. 아직 `normal` 외의 값을 관측하지 못했다.

---

## 7. 무엇을 보여줄지는 사용자가 정한다

조합이 사람마다 다르다.

| 쓰는 사람 | 조합 |
|---|---|
| 이 저장소 사용자 | 팀 둘 + Enterprise 하나 |
| 다른 사람 | 팀 하나 + Enterprise 하나 |
| 또 다른 사람 | Enterprise 하나 |

목록을 고정할 수 없으므로 설정으로 뺀다.

### 보여줄 것이 아니라 숨길 것을 담는다

```swift
public struct DesktopPreferences: Codable, Sendable, Equatable {
    public var hidden: Set<String>   // 명시적으로 끈 계정
    public var order: [String]       // 정한 순서. 없는 것은 뒤에 붙는다
}
```

보여줄 목록만 저장하면 **계정이 새로 생겼을 때 설정을 열기 전까지 영영 안 보인다.**
숨길 것을 담으면 새 계정이 자동으로 보인다. 기본값이 옳은 쪽으로 기운다.

순서를 안 정했으면 활성 계정이 먼저, 나머지는 이름순이다. 정했으면 그쪽이 이긴다.
활성 계정 우선은 기본값일 뿐 사용자 의사를 덮지 않는다.

### 못 읽는 계정도 설정에는 나온다

앱에서 한 번도 열지 않은 계정은 토큰이 없어 사용량을 모른다. 그래도 **이름은
알기 때문에** 설정 목록에는 올린다. 그러지 않으면 사용자가 쓸 조합에 들어 있는데
순서도 못 정하고 미리 숨길 수도 없다.

`DesktopSnapshot.orgs` 는 읽어낸 것만, `knownOrgs` 는 아는 것 전부다.
메뉴바는 앞을, 설정은 뒤를 본다.

```
        순서  이름           플랜        사용량   uuid
  ----  ----  -------------  ----  ----  -------  ---------
  표시  1     NAVER_TEAM_40  team  활성  읽힘     746e81ae-...
  표시  2     NAVER_TEAM_52  team        읽힘     2a063dae-...
  표시  3     Naver          -           못 읽음  2b4a57bf-...
```

### 명령

```
clfctl desktop orgs               아는 계정 전부와 표시 여부
clfctl desktop hide <이름|uuid>    목록에서 뺀다
clfctl desktop show <이름|uuid>    다시 넣는다
clfctl desktop order <이름>...     순서를 정한다
```

이름으로도 uuid 로도 받는다. uuid 를 외울 이유가 없다.

설정은 `~/Library/Application Support/clf/desktop.json` 에 둔다. 우리 설정이므로
우리 디렉토리다. 데스크톱 앱의 파일은 읽기만 하고 절대 쓰지 않는다.

파일이 없거나 깨졌으면 기본값으로 시작한다. 설정 파일 하나 때문에 메뉴바가
안 뜨면 안 된다.

---

## 8. 막대에 그릴 범위

계정이 셋이면 셋을 다 그릴 자리가 없다. 기본은 **활성 계정 하나만** 막대에 두고
나머지는 팝오버로 내린다. 전부 보고 싶으면 바꿀 수 있다.

```
clfctl desktop bar window    창이 열려있는 계정만 (기본)
clfctl desktop bar chosen    설정에서 지정한 계정
```

숨긴 계정은 막대에도 안 나온다. 표시 여부를 두 곳에서 따로 정하면 헷갈린다.
`hidden` 하나가 두 화면을 다 다스리고, `barContent` 는 그중 몇 개를 막대까지
올릴지만 정한다.

활성 계정을 숨겨뒀거나 활성 계정이 아예 없을 때 `activeOnly` 를 곧이곧대로
따르면 막대가 빈다. 그때는 보이는 것 중 첫째를 올린다. 빈 막대는 앱이 죽은
것처럼 보인다.

---

## 9. 갱신 주기는 사용량이 정한다

5분마다 부른다. 이 API 는 토큰을 안 쓰지만 그래도 하루 288번이다.

**아무것도 안 변한 관측이 세 번 이어지면** 조용한 것으로 보고 10분으로 늘린다.
변화가 보이면 곧바로 5분으로 돌아온다.

```
관측  1    기준을 잡는다                      5분
관측  2    그대로                             5분
관측  3    그대로                             5분
관측  4    그대로. 세 번 이어졌다             10분
관측  5    51% -> 53%. 쓰고 있다              5분   (즉시)
```

느려지는 건 천천히, 빨라지는 건 즉시다. 반대로 하면 한도가 차오르는 구간에서
숫자가 늦게 따라온다. 그때가 이 앱을 볼 유일한 이유인데.

### 무엇을 변화로 세는가

읽어낸 **사용률만** 지문에 넣는다.

| | 지문에 넣나 | 왜 |
|---|---|---|
| 계정별 창별 사용률 | 넣는다 | 이게 활동이다 |
| 읽은 시각 | 안 넣는다 | 매번 바뀐다. 넣으면 영영 안 느려진다 |
| 계정 집합 | 넣는다 | 계정이 늘거나 줄면 화면이 달라진다 |
| 리셋 시각 | 안 넣는다 | 창이 리셋되면 사용률이 0 으로 떨어진다. 그걸로 잡힌다 |

**아무것도 못 읽었으면 조용한 게 아니라 모르는 것이다.** 여기서 느려지면 API 가
돌아왔을 때 알아차리는 데 오래 걸린다. 그래서 실패한 관측은 지문을 갱신하지
않고 연속 횟수를 0 으로 되돌린다.

```swift
public struct RefreshPacer: Sendable {
    public static let activeInterval = Duration.seconds(300)
    public static let idleInterval = Duration.seconds(600)
    public static let idleThreshold = 3

    public mutating func observe(_ snapshot: DesktopSnapshot) -> Duration
}
```

순수 함수라 전부 테스트로 잠갔다. 창 리셋, 읽은 시각만 바뀐 경우, 계정 증감,
읽기 실패까지 9개다. 실제 시간을 기다리지 않는다.
