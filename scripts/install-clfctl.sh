#!/bin/sh
# clfctl 을 릴리스로 빌드해 PATH 에 링크한다.
#
# 저장소 안의 .build/debug/clfctl 은 상대 경로라 다른 디렉토리에서 부를 수 없고,
# swift build 를 다시 돌릴 때마다 자리가 바뀔 수 있다.
set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
BIN="${CLF_BIN_DIR:-$HOME/.local/bin}"

cd "$REPO"
echo "빌드하는 중"
swift build -c release --product clfctl

mkdir -p "$BIN"
ln -sf "$REPO/.build/release/clfctl" "$BIN/clfctl"

echo "링크했다  $BIN/clfctl"
case ":$PATH:" in
  *":$BIN:"*) echo "PATH 에 있다. clfctl 로 바로 부르면 된다" ;;
  *) echo
     echo "PATH 에 없다. 셸 설정에 다음을 넣는다"
     echo "  export PATH=\"$BIN:\$PATH\"" ;;
esac
