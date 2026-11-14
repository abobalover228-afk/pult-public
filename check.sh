#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
python3 -m unittest discover -s Checks -p 'test_*.py' -v
for file in Resources/helpers/*.sh; do zsh -n "$file"; done
sources=(Sources/Pult/Chat.swift Sources/Pult/Codex.swift Sources/Pult/Markdown.swift Sources/Pult/Support.swift Sources/Pult/Views.swift Sources/Pult/Commands.swift Sources/Pult/Questions.swift Sources/Pult/Queue.swift)
for check in InlineChecks QuestionQueueChecks; do
  xcrun swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${sources[@]}" "Checks/$check.swift" -o ".build/$check"
  ".build/$check"
done
