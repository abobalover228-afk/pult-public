#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
python3 -m unittest discover -s Checks -p 'test_*.py' -v
for file in Resources/helpers/*.sh; do zsh -n "$file"; done
sources=(Sources/Pult/Chat.swift Sources/Pult/Codex.swift Sources/Pult/Markdown.swift Sources/Pult/Support.swift Sources/Pult/Views.swift Sources/Pult/Commands.swift Sources/Pult/Questions.swift Sources/Pult/Queue.swift Sources/Pult/IntegratedCommands.swift Sources/Pult/FileLinks.swift Sources/Pult/PromptCoach.swift Sources/Pult/APIConnections.swift Sources/Pult/APIChat.swift Sources/Pult/ConnectionViews.swift Sources/Pult/ConversationState.swift Sources/Pult/FastMode.swift Sources/Pult/FollowingScroll.swift Sources/Pult/TeamRun.swift)
for check in ConversationChecks APIChecks PromptCoachChecks InlineChecks QuestionQueueChecks FileLinkQueueChecks IntegrationChecks; do
  xcrun swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" "${sources[@]}" "Checks/$check.swift" -o ".build/$check"
  ".build/$check"
done

xcrun swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Limits/WidgetState.swift Checks/WidgetChecks.swift -o .build/WidgetChecks
.build/WidgetChecks
