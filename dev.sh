#!/bin/bash
# 개발용 실행. 디버그로 빌드해 번들을 다시 만들고 앱을 이 터미널에 붙여 띄운다.
#
# open 으로 띄우면 stderr 가 터미널에서 끊긴다. 번들 안의 실행 파일을 직접
# 부르면 로그가 그대로 보이고 Ctrl-C 로 내릴 수 있다. Info.plist 는 번들
# 경로로 실행해도 그대로 읽히니 LSUIElement 도 동작한다.
#
# 인자를 주면 앱 대신 clfctl 을 부른다.  ./dev.sh usage --days 7
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -gt 0 ]; then
  swift build --product clfctl
  exec .build/debug/clfctl "$@"
fi

./scripts/make-app.sh debug

# 메뉴바에 두 개가 뜨는 것을 막는다. ~/Applications 에 설치한 것도 같이 내려간다
pkill -f "clf.app/Contents/MacOS/clf" 2>/dev/null || true
exec .build/clf.app/Contents/MacOS/clf &
