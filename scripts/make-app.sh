#!/bin/bash
# 메뉴바 앱을 .app 번들로 조립한다.
#
# Xcode 프로젝트를 두지 않는 이유는 타겟 정의가 Package.swift 와 두 곳으로
# 갈라지기 때문이다. 번들이 필요한 것은 세 가지뿐이라 손으로 만드는 편이 싸다.
#   - Contents/MacOS/<실행파일>
#   - Contents/Info.plist  (LSUIElement 로 Dock 아이콘을 없앤다)
#   - 임시 서명            (없으면 실행이 막힌다)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
APP=.build/clfl.app
BUNDLE_ID=com.suwonchae.clfl
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)

swift build -c "$CONFIG" --product ClflApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/ClflApp" "$APP/Contents/MacOS/clfl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>clfl</string>
  <key>CFBundleDisplayName</key>       <string>clfl</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>clfl</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <!-- 메뉴바에만 산다. Dock 아이콘도 없고 앱 전환기에도 안 나온다 -->
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# 임시 서명. 배포용은 아니지만 이게 없으면 로컬에서도 실행이 막힌다
codesign --force --sign - "$APP" 2>/dev/null

echo "  $APP  ($CONFIG, $VERSION)"
echo "  open $APP        메뉴바에 뜬다"
echo "  pkill -f clfl.app  내린다"
