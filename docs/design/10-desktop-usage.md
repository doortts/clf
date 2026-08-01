# 10. 데스크톱 앱 사용량 읽기

[09 문서](09-desktop-org-switch.md)에서 데스크톱 앱의 자동 전환을 하지 않기로 정했다.
그러면 남는 일은 하나다. **조직별 잔여를 보여주는 것.**

앱은 활성 조직 하나의 사용량만 보여준다. 나머지가 얼마나 남았는지는 일일이
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

앱은 조직별 OAuth 토큰을 `config.json` 의 `oauth:tokenCacheV2` 에 캐시한다.
캐시 키가 스코프까지 담고 있어 눈으로 확인된다.

```
9d1c250a-...:746e81ae-...:https://api.anthropic.com:user:inference user:file_upload user:profile user:sessions:claude_code
             ^^^^^^^^^^^ 조직 uuid                                                  ^^^^^^^^^^^^ 이게 필요했다
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
| 비활성 조직 | 못 읽는다 | **읽는다** |
| 필요한 스코프 | 없음 | `user:profile` |

메뉴바가 주기적으로 갱신해야 하므로 요청을 소모하지 않는 쪽이 유일하게 쓸 만하다.

---

## 4. 도구

```
scripts/desktop-usage.py            표로
scripts/desktop-usage.py --json     기계가 읽을 형태로
scripts/desktop-usage.py --active   활성 조직만
```

```
* NAVER_TEAM_40  (지금 앱에서 쓰는 조직)
    5시간        [##########..........] 잔여  51%   29분 뒤 리셋
    주간 전체      [###.................] 잔여  85%   5일 5시간 뒤 리셋
    주간 모델별     [....................] 잔여  99%   5일 5시간 뒤 리셋

  NAVER_TEAM_52
    5시간        [....................] 잔여 100%   창 안 열림
    주간 전체      [....................] 잔여 100%   창 안 열림
    주간 모델별     [....................] 잔여 100%   창 안 열림

  아직 못 읽는 조직: Naver
  앱에서 한 번 열면 토큰이 캐시돼 다음부터 읽힌다
```

활성 조직을 맨 위에 둔다. 잔여 15% 아래면 `주의` 를 붙인다.

---

## 5. 두 가지 한계

**앱에서 한 번도 열지 않은 조직은 못 읽는다.** 토큰 캐시에 없기 때문이다.
위 예에서 `Naver` 가 그렇다. 조직 목록은 세션 쿠키로 얻으므로 이름은 알지만
사용량은 모른다. 그 사실을 숨기지 않고 말한다.

**사용률 0% 인 창은 리셋 시각이 없다.** 창이 아직 안 열린 것이다. `-` 로 얼버무리지
않고 `창 안 열림` 이라고 쓴다. 관측하지 못한 것과 0으로 관측한 것은 다르다.

토큰이 만료되면 401 이 온다. 그때도 앱에서 그 조직을 한 번 열면 갱신된다.
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
