#!/bin/zsh
# Явно выбранные соседние bundles; не запускаем бинарник напрямую и не ищем копии по ID.
ROOT="${0:A:h}/Apps"
[[ -d "$ROOT/Пульт.app" ]] || ROOT="${0:A:h}/dist"
if [[ ! -d "$ROOT/Пульт.app" || ! -d "$ROOT/Лимиты.app" ]]; then
  print 'Сначала распакуйте полный комплект или выполните ./build.sh'
  exit 1
fi
print 'Перед перезапуском скопируйте черновик и очередь и дождитесь завершения задач.'
read 'answer?Перезапустить эти приложения? [y/N] '
[[ "$answer" = y || "$answer" = Y ]] || exit 0
/usr/bin/osascript -e 'tell application id "local.pultpublic.app" to quit' 2>/dev/null
/usr/bin/osascript -e 'tell application id "local.pultpublic.limits" to quit' 2>/dev/null
/usr/bin/open "$ROOT/Пульт.app"
/usr/bin/open "$ROOT/Лимиты.app"
