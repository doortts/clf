#!/bin/bash
# 메뉴바 앱을 .app 번들로 조립한다.
#
# Xcode 프로젝트를 두지 않는 이유는 타겟 정의가 Package.swift 와 두 곳으로
# 갈라지기 때문이다. 번들이 필요한 것은 세 가지뿐이라 손으로 만드는 편이 싸다.
#   - Contents/MacOS/<실행파일>
#   - Contents/Info.plist  (LSUIElement 로 Dock 아이콘을 없앤다)
#   - Contents/Resources/clf.icns
#   - 임시 서명            (없으면 실행이 막힌다)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
APP=.build/clf.app
BUNDLE_ID=com.suwonchae.clf
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)

swift build -c "$CONFIG" --product ClfApp

# 아이콘은 코드로 그린다. 결과물은 커밋하지 않고 소스가 바뀔 때만 다시 만든다.
# Dock 에는 안 뜨지만 메뉴바 관리 앱(Bartender 류)의 목록이 이걸로 항목을 그린다.
# 아이콘이 없으면 이름 없는 빈 줄이 되어 사용자가 못 찾는다.
ICON=.build/clf.icns
if [ ! -f "$ICON" ] || [ tools/make-icon.swift -nt "$ICON" ]; then
  swiftc -O tools/make-icon.swift -o .build/make-icon
  rm -rf .build/clf.iconset
  .build/make-icon .build/clf.iconset >/dev/null
  iconutil -c icns .build/clf.iconset -o "$ICON"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/ClfApp" "$APP/Contents/MacOS/clf"
cp "$ICON" "$APP/Contents/Resources/clf.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>clf</string>
  <key>CFBundleDisplayName</key>       <string>clf</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>clf</string>
  <key>CFBundleIconFile</key>          <string>clf</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <!-- 메뉴바에만 산다. Dock 아이콘도 없고 앱 전환기에도 안 나온다 -->
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# 서명. CLF_SIGN_IDENTITY 가 있으면 Developer ID 로 서명한다. 공증에는
# hardened runtime 과 보안 타임스탬프가 필수다. 값이 없으면 지금처럼 임시
# 서명으로 떨어져 로컬 빌드가 계속 돌아간다. docs/design/14-self-update.html
if [ -n "${CLF_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp \
           --sign "$CLF_SIGN_IDENTITY" "$APP"
  echo "  Developer ID 서명: $CLF_SIGN_IDENTITY"
else
  # 임시 서명. 배포용은 아니지만 이게 없으면 로컬에서도 실행이 막힌다
  codesign --force --sign - "$APP" 2>/dev/null
fi

echo "  $APP  ($CONFIG, $VERSION)"
echo "  open $APP        메뉴바에 뜬다"
echo "  pkill -f clf.app  내린다"
