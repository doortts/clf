#!/usr/bin/env python3
"""Claude 데스크톱 앱이 아는 모든 계정의 사용량을 읽는다.

앱은 활성 계정 하나의 사용량만 보여준다. 나머지가 얼마나 남았는지는 일일이
전환해 봐야 안다. 이 스크립트가 그 셋을 한 번에 읽는다.

앱은 계정별 OAuth 토큰을 config.json 의 oauth:tokenCacheV2 에 캐시해 두는데,
그 토큰들이 user:profile 스코프를 갖고 있다. Usage API 가 요구하는 그 스코프다.
setup-token 으로는 403 이 나던 호출이 이 토큰으로는 통한다.
docs/design/10-desktop-usage.md

  (인자 없음)   표로 보여준다
  --json       기계가 읽을 형태로
  --active     활성 계정 하나만

요청을 보내지 않는다. 토큰을 소모하지 않는다.
"""

import argparse
import base64
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/Claude"
CONFIG = SUPPORT / "config.json"
COOKIES = SUPPORT / "Cookies"
HOST = ".claude.ai"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

# 앱이 보여주는 세 줄. 이 순서로 그린다.
ROWS = [("session", "5시간"), ("weekly_all", "주간 전체"), ("weekly_scoped", "주간 Fable")]


def safe_storage_key() -> bytes:
    pw = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Safe Storage", "-w"],
        capture_output=True, text=True).stdout.strip()
    if not pw:
        sys.exit("Claude Safe Storage 키를 못 읽었다. Keychain 접근을 허용했는지 본다")
    return hashlib.pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, 16)


def decrypt(key: bytes, blob: bytes) -> bytes:
    """Chromium safe storage. v10 접두사 + AES-128-CBC + PKCS7."""
    if blob[:3] not in (b"v10", b"v11"):
        return blob
    out = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc", "-K", key.hex(),
         "-iv", "20" * 16, "-nopad"], input=blob[3:], capture_output=True).stdout
    return out[: -out[-1]] if out else b""


def org_tokens(key: bytes) -> dict[str, dict]:
    """계정 uuid -> 토큰 레코드. 캐시 키가 clientId:orgId:host:scopes 형식이다."""
    cfg = json.loads(CONFIG.read_text())
    blob = cfg.get("oauth:tokenCacheV2") or cfg.get("oauth:tokenCache")
    if not blob:
        sys.exit("config.json 에 oauth 토큰 캐시가 없다. 앱에 로그인돼 있는지 본다")
    cache = json.loads(decrypt(key, base64.b64decode(blob)).decode())
    return {k.split(":")[1]: v for k, v in cache.items() if len(k.split(":")) > 1}


def active_org(key: bytes) -> str | None:
    """lastActiveOrg 쿠키. 평문은 SHA256(host) 32바이트 + 값이다."""
    tmp = tempfile.mktemp()
    shutil.copy(COOKIES, tmp)
    try:
        row = sqlite3.connect(tmp).execute(
            "select encrypted_value from cookies where host_key=? and name='lastActiveOrg'",
            (HOST,)).fetchone()
    finally:
        os.unlink(tmp)
    return decrypt(key, row[0])[32:].decode() if row else None


def org_names(key: bytes) -> dict[str, str]:
    """계정 이름은 claude.ai 세션으로 얻는다. 토큰 캐시에는 uuid 뿐이다."""
    tmp = tempfile.mktemp()
    shutil.copy(COOKIES, tmp)
    try:
        row = sqlite3.connect(tmp).execute(
            "select encrypted_value from cookies where host_key=? and name='sessionKey'",
            (HOST,)).fetchone()
    finally:
        os.unlink(tmp)
    if not row:
        return {}
    session = decrypt(key, row[0])[32:].decode()
    req = urllib.request.Request(
        "https://claude.ai/api/organizations",
        headers={"cookie": f"sessionKey={session}",
                 "user-agent": "Mozilla/5.0 (Macintosh) Claude/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.load(r)
    except Exception:
        return {}
    orgs = data.get("organizations", data) if isinstance(data, dict) else data
    return {o["uuid"]: o["name"] for o in orgs}


def usage(token: str) -> dict | str:
    """요청을 보내지 않고 읽기만 한다. 토큰을 소모하지 않는다."""
    req = urllib.request.Request(
        USAGE_URL, headers={"authorization": f"Bearer {token}",
                            "anthropic-beta": "oauth-2025-04-20"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        if e.code == 401:
            return "토큰 만료. 앱에서 이 계정을 한 번 열면 갱신된다"
        return f"HTTP {e.code}: {body[:120]}"
    except Exception as e:
        return f"실패: {e}"


def until(iso: str | None) -> str:
    """리셋까지 남은 시간. 절대 시각보다 이쪽이 읽기 쉽다."""
    if not iso:
        return "-"
    try:
        when = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return "-"
    delta = when - datetime.now(timezone.utc)
    mins = int(delta.total_seconds() // 60)
    if mins < 0:
        return "지남"
    if mins < 60:
        return f"{mins}분"
    if mins < 60 * 24:
        return f"{mins // 60}시간 {mins % 60}분"
    return f"{mins // 1440}일 {(mins % 1440) // 60}시간"


def collect(key: bytes, only_active: bool) -> list[dict]:
    tokens = org_tokens(key)
    current = active_org(key)
    names = org_names(key)

    # 앱에서 한 번도 열지 않은 계정은 토큰 캐시에 없다. 없는 것을 말해준다
    missing = [n for u, n in names.items() if u not in tokens]

    out = []
    for org, record in tokens.items():
        if only_active and org != current:
            continue
        entry = {"uuid": org, "name": names.get(org, org[:8]), "active": org == current,
                 "plan": record.get("subscriptionType"), "tier": record.get("rateLimitTier")}
        result = usage(record["token"])
        if isinstance(result, str):
            entry["error"] = result
        else:
            # limits 배열이 세 줄을 그대로 담는다. percent 는 사용률이다
            entry["limits"] = {
                lim["kind"]: {"percent": lim.get("percent"),
                              "resets_at": lim.get("resets_at"),
                              "severity": lim.get("severity")}
                for lim in result.get("limits", [])}
        out.append(entry)
    # 활성 계정을 맨 위에
    out = sorted(out, key=lambda e: (not e["active"], e["name"]))
    if missing and not only_active:
        out.append({"missing": missing})
    return out


def render(entries: list[dict]) -> None:
    for e in entries:
        if "missing" in e:
            print("  아직 못 읽는 계정: " + ", ".join(e["missing"]))
            print("  앱에서 한 번 열면 토큰이 캐시돼 다음부터 읽힌다")
            continue
        mark = "*" if e["active"] else " "
        head = f"{mark} {e['name']}"
        if e["active"]:
            head += "  (지금 앱에서 쓰는 계정)"
        print(head)
        if "error" in e:
            print(f"    {e['error']}")
            print()
            continue
        for kind, label in ROWS:
            lim = e["limits"].get(kind)
            if not lim:
                continue
            pct = lim["percent"]
            remaining = 100 - pct if pct is not None else None
            bar_len = 20
            filled = round((pct or 0) / 100 * bar_len)
            bar = "#" * filled + "." * (bar_len - filled)
            warn = "   주의" if remaining is not None and remaining < 15 else ""
            # 사용률 0 이면 창이 아직 안 열려 리셋 시각이 없다. 없는 것을 없다고 쓴다
            when = f"{until(lim['resets_at'])} 뒤 리셋" if lim["resets_at"] else "창 안 열림"
            print(f"    {label:<10} [{bar}] 잔여 {remaining:>3}%   {when}{warn}")
        print()
    if not any(e.get("active") for e in entries):
        print("  활성 계정을 못 찾았다. 앱에서 계정을 한 번 골라본다")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true", help="기계가 읽을 형태로")
    ap.add_argument("--active", action="store_true", help="활성 계정만")
    args = ap.parse_args()

    if not CONFIG.exists():
        sys.exit(f"{CONFIG} 가 없다. Claude 데스크톱 앱이 설치돼 있는지 본다")

    entries = collect(safe_storage_key(), args.active)
    if args.json:
        print(json.dumps(entries, ensure_ascii=False, indent=2))
    else:
        render(entries)


if __name__ == "__main__":
    main()
