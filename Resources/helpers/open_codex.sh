#!/bin/zsh
set -eu
export CODEX_HOME="$1"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "${PULT_PROJECT:-$HOME}"
if ! command -v codex >/dev/null; then
  print 'Не установлен Codex CLI. См. README.'
  read -k 1
  exit 1
fi
if ! codex login status >/dev/null 2>&1; then
  codex login --device-auth
fi
exec codex --sandbox workspace-write --ask-for-approval on-request --no-alt-screen
