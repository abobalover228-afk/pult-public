#!/bin/sh
# Сервер комнат Пульта: установка одной командой на Linux с systemd.
#   sudo sh install.sh            — с пересылкой через сервер (для сетей, где прямое соединение не проходит)
#   sudo sh install.sh --no-relay — только знакомство компьютеров, содержимое всегда напрямую
#   sudo sh install.sh --open     — комнаты может создавать кто угодно (без токена)
# Повторный запуск обновляет файлы и сохраняет уже выданный токен.
set -eu

RELAY=1; OPEN=0
for arg in "$@"; do
  case "$arg" in
    --no-relay) RELAY=0 ;;
    --open) OPEN=1 ;;
    *) echo "Неизвестный параметр: $arg" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "Запусти от root: sudo sh install.sh" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "Нужен systemd" >&2; exit 1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null || { echo "Нужен python3 версии 3.9 или новее" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
DIR=/opt/pult-rendezvous
install -d -m 755 "$DIR"
install -m 644 "$SRC/server.py" "$SRC/route.py" "$DIR/"

ENV="$DIR/.env"
TOKEN=""
[ -f "$ENV" ] && TOKEN="$(sed -n 's/^PULT_SIGNAL_CREATE_TOKEN=//p' "$ENV" | head -n 1)"
[ "$OPEN" = 1 ] && TOKEN=""
[ "$OPEN" = 0 ] && [ -z "$TOKEN" ] && TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
umask 077
{
  echo "PULT_SIGNAL_HOST=127.0.0.1"
  echo "PULT_SIGNAL_PORT=8787"
  echo "PULT_SIGNAL_CREATE_TOKEN=$TOKEN"
  echo "PULT_SIGNAL_RELAY=$RELAY"
} > "$ENV"
chmod 600 "$ENV"

install -m 644 "$SRC/pult-rendezvous.service" "$SRC/pult-rendezvous-route.service" "$SRC/pult-rendezvous-route.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable pult-rendezvous.service >/dev/null
systemctl restart pult-rendezvous.service

OK=0
for attempt in 1 2 3 4 5 6 7 8; do
  if python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8787/health", timeout=2)' 2>/dev/null; then OK=1; break; fi
  sleep 1
done
[ "$OK" = 1 ] || { echo "Сервер не ответил. Смотри: journalctl -u pult-rendezvous -n 50" >&2; exit 1; }

CADDY=0
if python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:2019/config/", timeout=2)' 2>/dev/null; then
  CADDY=1
  systemctl enable --now pult-rendezvous-route.timer >/dev/null
  systemctl start pult-rendezvous-route.service || true
fi

echo
echo "Сервер комнат запущен на 127.0.0.1:8787."
[ "$RELAY" = 1 ] && echo "Пересылка через сервер: включена (содержимое зашифровано ключом комнаты, сервер его не видит)." || echo "Пересылка через сервер: выключена."
echo
if [ "$CADDY" = 1 ]; then
  echo "Найден Caddy: путь /pult-link подключён к его HTTPS-сайту."
  echo "Адрес для Пульта:  https://ТВОЙ-ДОМЕН/pult-link"
else
  echo "Пульту нужен HTTPS-адрес. Поставь перед сервером любой HTTPS-прокси. Пример для Caddy (/etc/caddy/Caddyfile):"
  echo "    твой.домен {"
  echo "        handle_path /pult-link/* {"
  echo "            reverse_proxy 127.0.0.1:8787"
  echo "        }"
  echo "    }"
  echo "Адрес для Пульта:  https://твой.домен/pult-link"
fi
echo
if [ -n "$TOKEN" ]; then
  echo "Токен создания комнат (впиши в Пульте: Вместе → ⋯ → Проект, GitHub и имя → Сервер комнат):"
  echo "    $TOKEN"
  echo "Он нужен только тому, кто создаёт комнаты. Кенту достаточно приглашения."
else
  echo "Комнаты может создавать любой, кто знает адрес."
fi
