#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
python3 -m unittest discover -s signaling -p 'test_*.py'
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache Sources/Pult/TeamBoard.swift Checks/TeamBoardChecks.swift -o .build/TeamBoardChecks
.build/TeamBoardChecks
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache Sources/Pult/TeamBoard.swift Sources/Pult/ProjectGit.swift Sources/Pult/TeamProject.swift Checks/TeamProjectChecks.swift -o .build/TeamProjectChecks
.build/TeamProjectChecks
