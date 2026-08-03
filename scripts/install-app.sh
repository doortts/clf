#!/bin/bash
# 메뉴바 앱을 ~/Applications 로 옮긴다.
#
# .build 안에서 돌면 로그인 항목 등록이 헛일이다. make-app.sh 가 매번 번들을
# 지우고 다시 만들기 때문에 승인을 받아도 다음 빌드에 사라진다.
# ~/Applications 는 관리자 권한이 필요 없다.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=${1:-$HOME/Applications}
./scripts/make-app.sh release >/dev/null

mkdir -p "$DEST"
# 돌고 있으면 먼저 내린다. 실행 중인 번들을 덮어쓰면 다음 실행이 깨진다
pkill -f "clf.app/Contents/MacOS/clf" 2>/dev/null || true
sleep 1
rm -rf "$DEST/clf.app"
cp -R .build/clf.app "$DEST/clf.app"
codesign --force --sign - "$DEST/clf.app" 2>/dev/null

echo "  $DEST/clf.app"
echo "  open '$DEST/clf.app'"
echo "  설정에서 '로그인할 때 실행' 을 켤 수 있다"
