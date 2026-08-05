#!/bin/bash
# 릴리즈 한 판: 태그, Developer ID 빌드, 공증 두 번, DMG, GitHub 릴리즈.
# docs/design/14-self-update.html 2절이 이 절차의 설계다.
#
# 공증은 앱과 DMG 를 각각 받는다. DMG 만 스테이플하면 꺼낸 .app 에는 티켓이
# 없어서, 앱이 자동 업데이트로 DMG 에서 .app 을 꺼내 쓸 때 spctl 평가에
# 걸린다. 앱을 먼저 스테이플하고 그 결과로 DMG 를 만들어야 양쪽에 붙는다.
#
# 준비물 (기계마다 한 번):
#   1. Developer ID Application 인증서가 로그인 키체인에 있어야 한다
#   2. 공증 자격 저장:
#      xcrun notarytool store-credentials clf-notary \
#          --apple-id <애플 ID> --team-id <팀 ID> --password <앱 암호>
#   3. gh auth login
#
# 사용:
#   CLF_SIGN_IDENTITY="Developer ID Application: 이름 (팀ID)" \
#       ./scripts/release.sh v0.4.0
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=${1:?사용법: CLF_SIGN_IDENTITY=... ./scripts/release.sh v0.4.0}
PROFILE=${CLF_NOTARY_PROFILE:-clf-notary}

# ---- 실수를 빌드 전에 잡는다 --------------------------------------------
# 태그 꼴이 아니면 앱의 semver 비교가 이 릴리즈를 영영 못 본다
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "태그는 v0.4.0 꼴이어야 한다: $TAG"; exit 1; }
[ -n "${CLF_SIGN_IDENTITY:-}" ] \
  || { echo "CLF_SIGN_IDENTITY 가 비어 있다. 임시 서명으로는 공증이 안 된다"; exit 1; }
git diff --quiet && git diff --cached --quiet \
  || { echo "커밋 안 된 변경이 있다. 릴리즈는 커밋된 상태에서만 만든다"; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "notarytool 프로필 '$PROFILE' 이 없다. 위 준비물 2를 먼저 한다"; exit 1; }
command -v gh >/dev/null || { echo "gh 가 없다. brew install gh"; exit 1; }

# make-app.sh 가 git describe 로 버전을 읽으므로 태그가 빌드보다 먼저다.
# 이미 있는 태그면 그 커밋 위에 서 있는지만 확인한다
git rev-parse "$TAG" >/dev/null 2>&1 || git tag "$TAG"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ] \
  || { echo "HEAD 가 $TAG 커밋이 아니다. 태그 커밋으로 이동해서 다시"; exit 1; }

./scripts/make-app.sh release
APP=.build/clf.app

# 제출 결과에서 Accepted 를 직접 확인한다. notarytool 은 Invalid 로 끝나도
# 종료 코드가 0 일 수 있어서 믿으면 안 된다. 거절이면 로그를 바로 띄운다
notarize() {
  local file=$1 out id
  echo "  공증 제출: $file (몇 분 걸린다)"
  out=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait)
  echo "$out"
  if ! grep -q "status: Accepted" <<<"$out"; then
    id=$(awk '/^  id:/{print $2; exit}' <<<"$out")
    echo "공증이 거절됐다. 로그:"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    exit 1
  fi
}

# ---- 1. 앱 공증 + 스테이플 ----------------------------------------------
# notarytool 은 폴더를 안 받아서 zip 으로 싸 올린다. 올리는 용도일 뿐이고
# 릴리즈에는 안 붙는다. ditto 를 쓰는 이유는 zip 명령이 심볼릭 링크와
# 확장 속성을 흘려 서명이 깨지기 때문이다
rm -f .build/notarize.zip
ditto -c -k --keepParent "$APP" .build/notarize.zip
notarize .build/notarize.zip
xcrun stapler staple "$APP"

# ---- 2. 스테이플된 앱으로 DMG -------------------------------------------
# /Applications 심볼릭 링크는 넣지 않는다. clf 는 ~/Applications 에 사는
# 앱이고 창에 뜬 링크가 그쪽으로 유도한다. docs/design/11-menubar-app.md
DMG=".build/clf-$TAG.dmg"
rm -rf .build/dmgroot "$DMG"
mkdir -p .build/dmgroot
cp -R "$APP" .build/dmgroot/
hdiutil create -volname "clf $TAG" -srcfolder .build/dmgroot \
        -ov -format UDZO "$DMG"

# ---- 3. DMG 공증 + 스테이플 ---------------------------------------------
# 브라우저로 직접 받아 여는 사람이 이 티켓을 본다
notarize "$DMG"
xcrun stapler staple "$DMG"

# ---- 4. 자기 검증 --------------------------------------------------------
# 앱이 자동 업데이트 때 교체 직전에 하는 것과 같은 검사다. 여기서 안 되는
# 것을 올리면 사용자 쪽 spctl 에서 똑같이 막힌다
spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" \
  || { echo "spctl 평가 실패. 올리지 않는다"; spctl -a -vv "$APP"; exit 1; }

# ---- 5. 올린다 ------------------------------------------------------------
git push origin "$TAG"
gh release create "$TAG" "$DMG" --generate-notes

echo
echo "  $DMG"
echo "  https://github.com/doortts/clf/releases/tag/$TAG"
