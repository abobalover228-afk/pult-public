#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
swift build -c release --product Pult
python3 -m unittest discover -s signaling -p 'test_*.py'
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache Sources/Pult/TeamBoard.swift Checks/TeamBoardChecks.swift -o .build/TeamBoardChecks
.build/TeamBoardChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache Sources/Pult/TeamBoard.swift Sources/Pult/ProjectGit.swift Sources/Pult/TeamProject.swift Checks/TeamProjectChecks.swift -o .build/TeamProjectChecks
.build/TeamProjectChecks

framework="$PWD/.build/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
sources=()
for file in Sources/Pult/*.swift; do
  [[ "$file" == "Sources/Pult/App.swift" ]] || sources+=("$file")
done
for check in ModChecks ConversationChecks; do
  xcrun swiftc -swift-version 5 -suppress-warnings -parse-as-library -module-cache-path .build/module-cache -F "$framework" -framework WebRTC -Xlinker -rpath -Xlinker "$framework" "${sources[@]}" "Checks/$check.swift" -o ".build/$check"
  ".build/$check"
done
