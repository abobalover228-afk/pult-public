# Пульт и Лимиты для Windows

Версия 2.4.1: интерфейс повторяет компоновку оригинального Пульта на Mac — открытые чаты и история слева, квоты внизу, моноширинная лента и компактный ввод с моделью, файлами, голосом и разрешениями. Telegram и сервер доступны в настройках → Подключения.

Rust + Tauri 2. Windows x64 установщик собран и проверен в [GitHub Actions](https://github.com/abobalover228-afk/pult-public/actions/runs/43942330970): 52 UI-теста, 33 Rust-теста, установка в путь с кириллицей и пробелами, запуск обоих окон и MCP установленного приложения. Это рабочая ветка порта Пульта 2.4; все внешние интеграции ещё не проверены.

В одном приложении: Codex, Claude Code и совместимые Chat Completions API; история и ветки, поток ответов, очередь, разрешения и вопросы; выбор модели, effort, Fast и планирование Claude; моды и SDK, командные комнаты, Telegram, голос Windows, MCP и отключённый по умолчанию computer use. Виджет «Лимиты», трей и автозапуск входят в тот же исполняемый файл.

Редактирование создаёт новую ветку, сохраняя прежнее продолжение. Правила можно переопределить для отдельного чата. Поддержаны фон, ссылки на локальные файлы со строками, вставка скриншотов и перетаскивание файлов.

## Разработка

Нужны Rust 1.90+, Node.js 24+, MSVC Build Tools с C++ и WebView2 на Windows. Node.js нужен только для разработки. Codex CLI, Claude Code, Git и дополнительные интеграции устанавливаются отдельно. Авторизация остаётся в CLI.

```sh
cd windows
npm ci --ignore-scripts
npm run vendor
npm run dev
```

На macOS можно проверить оболочку и платформонезависимую логику.

## Проверки и сборка

```sh
npm run check
npx playwright install chromium
npm test
cargo test --locked
cargo build --locked --features custom-protocol
```

`pult --smoke-test` проверяет загрузку обоих настоящих WebView через IPC и завершает приложение. `node scripts/test-mcp-stdio.mjs` проверяет MCP-режим без доступа к экрану.

```sh
npm run build:windows
```

NSIS-установщик появится в `target/release/bundle/nsis/`. Workflow **Windows Rust** собирает и проверяет приложение на Windows и сохраняет установщик с SHA-256 в artifacts; он не публикует релиз. Локальная проверка компиляции через Zig: `npm run check:windows`.

Подробности и границы проверок: [VERIFICATION.md](VERIFICATION.md), [PORT-STATUS.md](PORT-STATUS.md).

## Данные

Настройки, локальные диалоги, вложения и доски: `%APPDATA%/Pult/`. Секреты API, Telegram, SSH/VLESS и приглашения комнат хранятся в локальных `.env`; метаданные отдельно. Эти файлы не зашифрованы, base64 у API-ключей служит только кодированием. Они исключены из Git.

Аккаунты Codex: `%USERPROFILE%/.codex-accounts.json`, формат `[{"name":"Codex","home":"~/.codex"}]`. Приложение не копирует `auth.json` между аккаунтами. Claude-квота читается из `~/.claude/limits-cache.json`.

Режимы: `--limits`, `--statusline`, `--limits-json`, `--codex-auto`, `--mcp-computer`. Чтение лимитов и каталога моделей не создаёт ход модели.

## Лицензии

Marked — MIT, DOMPurify — Apache-2.0 OR MPL-2.0, официальный [плагин уведомлений Tauri](https://v2.tauri.app/plugin/notification/) — Apache-2.0 OR MIT. Тексты выбранных лицензий включены в `ui/vendor/`. Версии закреплены lock-файлами.
