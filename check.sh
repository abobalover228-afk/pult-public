#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
python3 -m unittest discover -s Checks -p 'test_*.py' -v
for file in Resources/helpers/*.sh; do zsh -n "$file"; done
sources=()
for file in Sources/Pult/*.swift; do
  [[ "$file" == "Sources/Pult/App.swift" || "$file" == "Sources/Pult/TeamRun.swift" ]] || sources+=("$file")
done
for check in ConversationChecks APIChecks PromptCoachChecks InlineChecks QuestionQueueChecks FileLinkQueueChecks IntegrationChecks EventRoutingChecks LargeInputChecks; do
  xcrun swiftc -suppress-warnings -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${sources[@]}" "Checks/$check.swift" -o ".build/$check"
  ".build/$check"
done

xcrun swiftc -suppress-warnings -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Limits/WidgetState.swift Checks/WidgetChecks.swift -o .build/WidgetChecks
.build/WidgetChecks
xcrun swiftc -suppress-warnings -parse-as-library Sources/Pult/Codex.swift Checks/LargeInputChecks.swift -o .build/LargeInputChecks
.build/LargeInputChecks
