# 12. Enterprise 는 시간 창이 없다

팀 계정은 5시간, 주간 전체, 주간 Fable 세 창으로 묶인다. Enterprise 는 아니다.

---

## 1. 실측

Enterprise 계정의 Usage API 응답이다. 앱에서 그 계정을 한 번 열어 토큰이
캐시된 뒤 딱 한 번 불렀다.

```json
{
  "five_hour": null, "seven_day": null, "seven_day_opus": null,
  "limits": [],
  "spend": {
    "used":  { "amount_minor": 0,    "currency": "USD", "exponent": 2 },
    "limit": { "amount_minor": 7500, "currency": "USD", "exponent": 2 },
    "percent": 0, "severity": "normal", "enabled": true,
    "balance": null, "can_purchase_credits": false
  },
  "extra_usage": { "monthly_limit": 7500, "used_credits": 0.0, "currency": "USD" }
}
```

**시간 창이 하나도 없다.** `limits` 는 빈 배열이고 `five_hour` 와 `seven_day`
계열은 전부 `null` 이다. 토큰 메타의 `rateLimitTier` 도 `default_claude_zero` 다.

대신 돈이 온다. 한도 $75.00 에 사용 $0.00.

## 2. 잔액이 아니라 월 예산이다

처음에는 "충전한 금액" 으로 짐작했다. 필드를 보면 아니다.

| 필드 | 값 | 뜻 |
|---|---|---|
| `monthly_limit` | 7500 | 월 단위 한도 |
| `can_purchase_credits` | false | 사용자가 충전할 수 없다 |
| `balance` | null | 잔액이라는 개념이 없다 |

디스클레이머도 "Usage credits cover you when you hit your plan limits" 라고
말한다. 관리자가 정한 월 예산이고, 플랜 한도를 넘겼을 때 쓰는 예비다.

결론(돈으로 보여준다)은 짐작과 같지만 성격은 다르다.

---

## 3. 우리가 겪은 문제

`limits` 만 읽고 있었다. Enterprise 는 그게 빈 배열이라 200 이 왔는데도
"사용량을 모른다" 고 말했다. 팝오버에는 없는 창 셋이 `?` 로 그려졌다.

```
Naver  [enterprise]
  5시간      ( ? )  (           )   창 안 열림
  주간 전체   ( ? )  (           )   창 안 열림
  주간 Fable ( ? )  (           )   창 안 열림
```

**없는 것을 그리고 있었다.** 모르는 것과 없는 것은 다르다.

---

## 4. 지금

```
Naver  [enterprise]
  월 예산   ( 100% )  (========================)
            $0.00 / $75.00 사용
```

계정마다 **시간 창 셋** 또는 **월 예산 하나** 중 하나를 그린다.

```swift
public struct UsageReport: Sendable, Equatable {
    public let limits: [LimitKind: UsageLimit]
    public let spend: SpendUsage?       // Enterprise 만
}
```

### 등급 경계는 같다

잔여 50% 이상 여유, 15% 이상 정상, 5% 이상 주의, 그 아래 소진. 돈이라고
다르게 볼 이유가 없고, 게이지도 그대로 재사용한다.

### 금액은 응답이 준 단위로 만든다

`amount_minor` 는 최소 단위 정수이고 `exponent` 가 소수 자리다. 달러는
`7500, 2` 라 $75.00 이고, 원이라면 `100000, 0` 이라 100,000 이다.

통화 기호를 소스에 박지 않는다. 통화가 늘 때마다 손대야 하고 저장소 문자
규칙에도 걸린다. `NumberFormatter` 에 코드만 넘긴다. 로케일은 `en_US` 로
두는데, `ko_KR` 로 USD 를 그리면 `US$75.00` 이 되기 때문이다.

### 한도가 0 이면 예산이 아니다

`limitMinor > 0` 일 때만 예산으로 읽는다. 0 으로 나누지 않는다.

---

## 5. 여기에 걸린 다른 규칙들

| | 어떻게 바뀌었나 |
|---|---|
| 막대에서 거르기 | `limits.isEmpty` 가 아니라 `hasUsage` 로 본다. 예산만 있어도 보여줄 것이 있다 |
| 갱신 주기 지문 | 예산 사용액도 넣는다. 시간 창이 없는 계정은 그것만 움직인다 |
| 낡은 값 물려주기 | 예산도 함께 물려준다 |
| 메뉴바 숫자 | `5h`/`1w` 두 줄 대신 `예산` 한 줄 |

시간 창이 없는 계정에 `5h` 를 그리면 그 자체가 거짓말이다.
