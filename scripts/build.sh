#!/bin/bash
# 전체 빌드. 라이브러리와 clfctl 을 만들고 메뉴바 앱을 번들로 감싼다.
#
# 설치는 하지 않는다. ~/Applications 로 옮기려면 install-app.sh,
# clfctl 을 PATH 에 링크하려면 install-clfctl.sh 를 쓴다.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}

swift build -c "$CONFIG"
./scripts/make-app.sh "$CONFIG"
