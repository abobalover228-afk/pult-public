#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
swift build -c release --product Pult
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/Пульт.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helpers" "$APP/Contents/Frameworks"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PultCommit string $(git rev-parse --short HEAD)" "$APP/Contents/Info.plist"
cp Bundle/*.icns Bundle/WebRTC-LICENSE.md "$APP/Contents/Resources/"
cp Resources/helpers/*.py Resources/helpers/*.sh "$APP/Contents/Resources/helpers/"
FRAMEWORK=".build/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/WebRTC.framework"
cp "$BIN_DIR/Pult" "$APP/Contents/MacOS/Pult"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Pult"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
make_app() {
  local name="$1" executable="$2" identifier="$3" accessory="$4"
  local bundle="dist/$name.app"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  mkdir -p "$bundle/Contents/Resources/helpers"
  cp Resources/helpers/*.py Resources/helpers/*.sh "$bundle/Contents/Resources/helpers/"
  cp "Design/$executable.icns" "$bundle/Contents/Resources/${executable}AppIcon.icns"
  chmod +x "$bundle/Contents/Resources/helpers/"*.sh
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.2.0</string>
<key>CFBundleIconFile</key><string>${executable}AppIcon.icns</string>
<key>CFBundleVersion</key><string>2.2.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><$accessory/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>pultpublic</string><key>CFBundleURLSchemes</key><array><string>pultpublic</string></array></dict></array>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Открывать Codex и вход в аккаунт в Terminal по нажатию пользователя.</string>
</dict></plist>
PLIST
}
make_app 'Лимиты' Limits local.pultpublic.limits true
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "dist/Лимиты.app/Contents/Info.plist"
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -O -parse-as-library -module-name Limits -module-cache-path "$CLANG_MODULE_CACHE_PATH" Sources/Limits/*.swift -o 'dist/Лимиты.app/Contents/MacOS/Limits'
codesign --force --deep --sign - 'dist/Лимиты.app'
codesign --verify --deep --strict 'dist/Лимиты.app'
ditto -c -k --keepParent dist Pult-macOS.zip
shasum -a 256 Pult-macOS.zip > Pult-macOS.zip.sha256
