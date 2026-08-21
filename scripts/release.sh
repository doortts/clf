#!/bin/bash
# 릴리즈 한 판: 태그, Developer ID 빌드, 공증 두 번, DMG, 릴리즈 두 곳.
# docs/design/14-self-update.html 2절과 docs/design/17-repo-split.html 6절이
# 이 절차의 설계다.
#
# 내보내는 곳이 둘이다. 앱이 부르는 곳은 공개 저장소 하나뿐이지만, 앱이 여는
# 사람용 링크는 전부 사내 GHE 라서 그쪽에도 같은 릴리즈가 서 있어야 한다.
# 특히 error 상태의 "직접 받기" 가 GHE 릴리즈 페이지를 여므로 DMG 를 양쪽에
# 붙인다. 자동 설치가 막힌 사람에게 문이 한 번에 열려야 한다.
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
#   3. 두 호스트에 각각 로그인. 이 기계는 GHE 만 되어 있었다:
#      gh auth login --hostname github.com
#      gh auth login --hostname oss.navercorp.com
#
# 사용:
#   ./scripts/release.sh v0.4.0                  짓고 공증하고 스테이플까지
#   ./scripts/release.sh v0.4.0 --publish        거기에 태그 push + 릴리즈 두 곳
#   ./scripts/release.sh v0.4.0 --skip-notarize  포장만. 몇 초에 끝난다
#
# 1 - 8 은 몇 번을 돌려도 안전해서 기본값이고, 되돌릴 수 없는 9 만 --publish
# 뒤에 둔다. 공증만 해 보려는데 태그 push 까지 딸려 오면 그 명령을 쓸 수가 없다.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=${1:?사용법: ./scripts/release.sh v0.4.0 [--publish] [--skip-notarize]}
shift || true

PUBLISH=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --publish)       PUBLISH=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "모르는 옵션: $arg"; exit 1 ;;
  esac
done

PROFILE=${CLF_NOTARY_PROFILE:-clf-notary}
# 기계용 저장소. Sources/ClfDesktop/ProjectLinks.swift 의 updateRepo 와 같아야
# 한다. 여기만 바꾸면 앱은 옛 주소를 계속 본다
PUBLIC_REPO=github.com/doortts/clf
# 사람용 저장소. 소스 원본과 이슈가 여기 산다
GHE_REPO=oss.navercorp.com/sw-chae/clf
NOTES=".build/notes-$TAG.md"

# ---- 실수를 빌드 전에 잡는다 --------------------------------------------
# 태그 꼴이 아니면 앱의 semver 비교가 이 릴리즈를 영영 못 본다
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "태그는 v0.4.0 꼴이어야 한다: $TAG"; exit 1; }
git diff --quiet && git diff --cached --quiet \
  || { echo "커밋 안 된 변경이 있다. 릴리즈는 커밋된 상태에서만 만든다"; exit 1; }

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  [ -n "${CLF_SIGN_IDENTITY:-}" ] \
    || { echo "CLF_SIGN_IDENTITY 가 비어 있다. 임시 서명으로는 공증이 안 된다"; exit 1; }
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "notarytool 프로필 '$PROFILE' 이 없다. 위 준비물 2를 먼저 한다"; exit 1; }
fi

if [ "$PUBLISH" -eq 1 ]; then
  command -v gh >/dev/null || { echo "gh 가 없다. brew install gh"; exit 1; }
  # 두 호스트를 다 본다. 빌드와 공증이 끝난 뒤에 인증에서 걸리면 아깝다
  for host in github.com oss.navercorp.com; do
    gh auth status --hostname "$host" >/dev/null 2>&1 \
      || { echo "gh 가 $host 에 로그인되어 있지 않다:"; \
           echo "  gh auth login --hostname $host"; exit 1; }
  done
  # 공개 저장소는 이제 살아 있는 소스 미러다. 태그를 밀면 그 커밋들이 같이
  # 올라간다. 사람의 기억에 맡기면 바쁜 날에 새어 나간다
  # docs/design/17-repo-split.html 2절
  if command -v gitleaks >/dev/null; then
    gitleaks detect --no-banner --redact \
      || { echo "gitleaks 가 뭔가를 찾았다. 공개 저장소로 나가기 전에 확인한다"; exit 1; }
  else
    echo "  gitleaks 가 없다. 비밀값 검사를 건너뛴다 (brew install gitleaks)"
  fi
fi

# ---- 0. 릴리즈 노트. 카드에 뜰 글이라 사람이 한 번 읽는다 ----------------
# --generate-notes 를 안 쓴다. 공개 쪽에 자동 생성 노트를 쓰면 GHE 이슈 번호
# 같은 죽은 참조가 들어가고, 그 본문 앞 3줄이 그대로 사용자 카드에 뜬다.
# 빈 본문이면 무엇이 바뀌었는지 모른 채 설치 단추만 보게 된다
mkdir -p .build
if [ ! -s "$NOTES" ]; then
  PREV=$(git describe --tags --abbrev=0 --exclude="$TAG" 2>/dev/null || true)
  {
    if [ -n "$PREV" ]; then git log --format='- %s' "$PREV..HEAD"
    else git log --format='- %s' -20
    fi
  } > "$NOTES"
  echo "  릴리즈 노트 초안을 만들었다: $NOTES"
  echo "  앞 3줄이 사용자 카드에 그대로 뜬다. 다듬은 뒤 다시 실행한다"
  exit 1
fi

# make-app.sh 가 git describe 로 버전을 읽으므로 태그가 빌드보다 먼저다.
# 이미 있는 태그면 그 커밋 위에 서 있는지만 확인한다
git rev-parse "$TAG" >/dev/null 2>&1 || git tag -a "$TAG" -m "clf $TAG"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ] \
  || { echo "HEAD 가 $TAG 커밋이 아니다. 태그 커밋으로 이동해서 다시"; exit 1; }

./scripts/make-app.sh release
APP=.build/clf.app

# 제출 결과에서 Accepted 를 직접 확인한다. notarytool 은 Invalid 로 끝나도
# 종료 코드가 0 일 수 있어서 믿으면 안 된다. 거절이면 로그를 바로 띄운다
notarize() {
  local file=$1 out id
  if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "  공증 건너뜀: $file"
    return 0
  fi
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

staple() {
  [ "$SKIP_NOTARIZE" -eq 1 ] || xcrun stapler staple "$1"
}

# ---- 1. 앱 공증 + 스테이플 ----------------------------------------------
# 보내기 전에 서명을 먼저 본다. 공증 왕복은 몇 분인데 여기서 걸릴 문제를
# 거기까지 들고 갈 이유가 없다
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  codesign --verify --deep --strict --verbose=2 "$APP"
fi
# notarytool 은 폴더를 안 받아서 zip 으로 싸 올린다. 올리는 용도일 뿐이고
# 릴리즈에는 안 붙는다. ditto 를 쓰는 이유는 zip 명령이 심볼릭 링크와
# 확장 속성을 흘려 서명이 깨지기 때문이다
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  rm -f .build/notarize.zip
  ditto -c -k --keepParent "$APP" .build/notarize.zip
  notarize .build/notarize.zip
fi
staple "$APP"

# ---- 2. 스테이플된 앱으로 DMG -------------------------------------------
# /Applications 심볼릭 링크는 넣지 않는다. clf 는 ~/Applications 에 사는
# 앱이고 창에 뜬 링크가 그쪽으로 유도한다. docs/design/11-menubar-app.md
DMG=".build/clf-$TAG.dmg"
rm -rf .build/dmgroot "$DMG"
mkdir -p .build/dmgroot
# cp -R 은 서명과 심볼릭 링크를 흘린다
ditto "$APP" .build/dmgroot/clf.app
hdiutil create -volname "clf $TAG" -srcfolder .build/dmgroot \
        -ov -format UDZO "$DMG"

# ---- 3. DMG 서명 + 공증 + 스테이플 --------------------------------------
# 브라우저로 직접 받아 여는 사람이 이 티켓을 본다.
#
# **DMG 도 서명해야 한다.** hdiutil 이 만든 것은 서명이 없고, 서명 없는
# DMG 에는 티켓을 붙일 자리가 없다. 그래도 stapler 는 "worked" 를 찍는다.
# 그 상태로 올리면 받은 사람 쪽에서 spctl 이 `no usable signature` 로
# 떨어지고, Gatekeeper 는 애플에 물어봐야 티켓을 안다. 서명은 공증보다
# 먼저다. 뒤에 하면 방금 붙인 티켓이 깨진다
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  codesign --force --timestamp --sign "$CLF_SIGN_IDENTITY" "$DMG"
fi
notarize "$DMG"
staple "$DMG"

# ---- 4. 자기 검증 --------------------------------------------------------
# 앱이 자동 업데이트 때 교체 직전에 하는 것과 같은 검사다. 여기서 안 되는
# 것을 올리면 사용자 쪽 spctl 에서 똑같이 막힌다
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" \
    || { echo "spctl 평가 실패. 올리지 않는다"; spctl -a -vv "$APP"; exit 1; }
  # DMG 도 본다. 스테이플이 조용히 헛일이 되는 경로가 있어서 stapler 의
  # "worked" 만으로는 붙었는지 알 수 없다
  spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 \
    | grep -q "^.*: accepted" \
    || { echo "DMG 의 spctl 평가 실패. 올리지 않는다"; \
         spctl -a -vv -t open --context context:primary-signature "$DMG"; exit 1; }
fi

if [ "$PUBLISH" -eq 0 ]; then
  echo
  echo "  $DMG"
  echo "  내보내려면: ./scripts/release.sh $TAG --publish"
  exit 0
fi

# ---- 5. 올린다. 여기서부터 되돌릴 수 없다 --------------------------------
# 릴리즈 하나를 만든다. 이미 있으면 자산만 덮어쓴다. 두 곳에 올리는 도중에
# 끊길 수 있어서, 같은 명령을 다시 돌리는 것이 복구가 되어야 한다
publish_to() {
  local repo=$1
  if gh release view "$TAG" --repo "$repo" >/dev/null 2>&1; then
    echo "  릴리즈가 이미 있다. 자산만 덮어쓴다: $repo"
    gh release upload "$TAG" "$DMG" --repo "$repo" --clobber
  else
    gh release create "$TAG" "$DMG" --repo "$repo" \
       --title "clf $TAG" --notes-file "$NOTES"
    echo "  릴리즈 생성: $repo"
  fi
}

# **GHE 가 먼저다.** 공개 릴리즈가 생기는 순간부터 앱들이 새 버전을 보고
# "릴리즈 노트" 를 누르기 시작한다. 그 링크의 목적지인 GHE 페이지가 먼저 서
# 있어야 한다. 반대 순서로 하면 죽은 링크가 먼저 나간다
git push origin "$TAG"
git push origin HEAD:main
publish_to "$GHE_REPO"

git push gh "$TAG"
git push gh HEAD:main
publish_to "$PUBLIC_REPO"

echo
echo "  $DMG"
echo "  https://$GHE_REPO/releases/tag/$TAG      (사람용. 링크가 가는 곳)"
echo "  https://$PUBLIC_REPO/releases/tag/$TAG   (기계용. 앱이 보는 곳)"
