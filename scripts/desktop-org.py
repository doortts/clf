#!/usr/bin/env python3
"""Claude 데스크톱 앱의 활성 조직을 읽고 바꾼다.

앱은 조직 선택을 claude.ai 의 lastActiveOrg 쿠키에만 담는다. 그 쿠키는
Chromium safe storage 로 암호화돼 있지만 키가 Keychain 에 있으므로 읽고
쓸 수 있다. docs/design/09-desktop-org-switch.md

  status            지금 활성 조직
  list              로그인된 조직 목록
  switch <이름|uuid>  조직을 바꾼다. 앱을 껐다 켠다

실측으로 확인했다. 앱이 부팅하며 이 쿠키를 읽고 그 조직으로 시작하며,
그대로 유지된다. ~/Library/Logs/Claude/main.log 에 이렇게 남는다.

  Updated allowlist enabled state for org <uuid>: false
  [LocalSessionManager] Org changed from <이전> to <이후>

주의: switch 는 앱을 종료한다. 열려 있던 대화 창이 닫힌다.
앱이 도는 동안에는 쿠키를 바꿔도 UI 가 안 따라온다. 이미 메모리에 든 값으로
그려져 있기 때문이다. 그래서 종료 -> 쓰기 -> 실행 순서다.
"""

import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

APP = "/Applications/Claude.app"
COOKIES = Path.home() / "Library/Application Support/Claude/Cookies"
HOST = ".claude.ai"
IV = b"\x20" * 16


def safe_storage_key() -> bytes:
    """Chromium 쿠키 암호화 키. Keychain 의 'Claude Safe Storage' 에서 파생한다."""
    pw = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Safe Storage", "-w"],
        capture_output=True, text=True, check=True).stdout.strip()
    if not pw:
        sys.exit("Claude Safe Storage 키를 못 읽었다. Keychain 접근을 허용했는지 본다")
    return hashlib.pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, 16)


def aes(mode: str, key: bytes, data: bytes) -> bytes:
    r = subprocess.run(
        ["openssl", "enc", mode, "-aes-128-cbc", "-K", key.hex(), "-iv", IV.hex(), "-nopad"],
        input=data, capture_output=True)
    if r.returncode != 0:
        sys.exit(f"openssl 실패: {r.stderr.decode()[:200]}")
    return r.stdout


def decrypt(key: bytes, enc: bytes) -> str:
    """평문은 SHA256(host) 32바이트 + 실제 값이다."""
    if not enc or enc[:3] not in (b"v10", b"v11"):
        return enc.decode(errors="replace")
    padded = aes("-d", key, enc[3:])
    plain = padded[: -padded[-1]]
    return plain[32:].decode(errors="replace")


def encrypt(key: bytes, value: str) -> bytes:
    plain = hashlib.sha256(HOST.encode()).digest() + value.encode()
    pad = 16 - (len(plain) % 16)
    return b"v10" + aes("-e", key, plain + bytes([pad]) * pad)


def read_cookie(name: str) -> bytes | None:
    """DB 를 복사해서 읽는다. 앱이 쥐고 있는 파일을 직접 열지 않는다."""
    tmp = tempfile.mktemp()
    shutil.copy(COOKIES, tmp)
    try:
        row = sqlite3.connect(tmp).execute(
            "select encrypted_value from cookies where host_key=? and name=?",
            (HOST, name)).fetchone()
        return row[0] if row else None
    finally:
        os.unlink(tmp)


def orgs(key: bytes) -> list[dict]:
    session = read_cookie("sessionKey")
    if not session:
        sys.exit("sessionKey 쿠키가 없다. 앱에 로그인돼 있는지 본다")
    req = urllib.request.Request(
        "https://claude.ai/api/organizations",
        headers={"cookie": f"sessionKey={decrypt(key, session)}",
                 "user-agent": "Mozilla/5.0 (Macintosh) Claude/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
    return data.get("organizations", data) if isinstance(data, dict) else data


def app_running() -> bool:
    """pgrep -x 는 이 앱을 못 잡는다. System Events 가 유일하게 맞는 답을 준다.

    처음에 pgrep 을 믿었다가 실행 중인 앱을 꺼졌다고 판정했고, 종료 단계를
    건너뛴 채 쿠키를 써서 메모리 값에 덮여버렸다.
    """
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to return (name of processes) contains "Claude"'],
        capture_output=True, text=True)
    return r.stdout.strip() == "true"


def cmd_status(key: bytes) -> None:
    enc = read_cookie("lastActiveOrg")
    if not enc:
        sys.exit("lastActiveOrg 쿠키가 없다. 앱에서 조직을 한 번 골라본다")
    current = decrypt(key, enc)
    names = {o["uuid"]: o["name"] for o in orgs(key)}
    print(f"  활성 조직  {names.get(current, '?')}  ({current})")
    print(f"  앱 상태    {'실행 중' if app_running() else '꺼짐'}")


def cmd_list(key: bytes) -> None:
    enc = read_cookie("lastActiveOrg")
    current = decrypt(key, enc) if enc else None
    for o in orgs(key):
        mark = "*" if o["uuid"] == current else " "
        caps = o.get("capabilities", [])
        plan = "Enterprise" if "raven_enterprise" in caps else "Team"
        print(f"  {mark} {o['uuid']}  {o['name']:<18} {plan}")
    print("\n  * 가 지금 활성 조직")


def cmd_switch(key: bytes, target: str) -> None:
    found = [o for o in orgs(key)
             if o["uuid"] == target or o["name"].lower() == target.lower()]
    if len(found) != 1:
        sys.exit(f"'{target}' 에 맞는 조직이 {len(found)}개다. list 로 확인한다")
    org = found[0]

    enc = read_cookie("lastActiveOrg")
    if enc and decrypt(key, enc) == org["uuid"]:
        print(f"  이미 {org['name']} 이다")
        return

    if app_running():
        print("  앱을 종료한다. 열려 있는 대화 창이 닫힌다")
        subprocess.run(["osascript", "-e", 'tell application "Claude" to quit'],
                       capture_output=True)
        # 종료하면서 메모리의 쿠키를 디스크로 내린다. 그게 끝나야 우리가 쓴다
        for _ in range(60):
            if not app_running():
                break
            time.sleep(0.5)
        else:
            sys.exit("앱이 종료되지 않았다. 직접 끄고 다시 시도한다")
        time.sleep(1.5)

    # 원본은 그대로 두고 사본에 써서 바꿔치기한다
    tmp = tempfile.mktemp()
    shutil.copy(COOKIES, tmp)
    conn = sqlite3.connect(tmp)
    conn.execute("update cookies set encrypted_value=?, value='' "
                 "where host_key=? and name='lastActiveOrg'",
                 (encrypt(key, org["uuid"]), HOST))
    conn.commit()
    conn.close()
    shutil.move(tmp, COOKIES)
    print(f"  쿠키를 {org['name']} 로 바꿨다")

    subprocess.run(["open", "-a", APP], check=True)
    print("  앱을 다시 켰다. 창이 뜨면 왼쪽 아래에서 확인한다")


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    if not COOKIES.exists():
        sys.exit(f"{COOKIES} 가 없다. Claude 데스크톱 앱이 설치돼 있는지 본다")

    key = safe_storage_key()
    cmd = args[0]
    if cmd == "status":
        cmd_status(key)
    elif cmd == "list":
        cmd_list(key)
    elif cmd == "switch":
        if len(args) < 2:
            sys.exit("switch <이름|uuid> 형식으로 준다")
        cmd_switch(key, args[1])
    else:
        sys.exit(f"모르는 명령: {cmd}")


if __name__ == "__main__":
    main()
