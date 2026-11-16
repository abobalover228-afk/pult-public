# Текущее состояние интеграций — 16 ноября 2026

Системные уведомления подключены через официальный tauri-plugin-notification 2.8.1 (Apache-2.0 OR MIT). Завершение/запросы внимания уведомляют только при неактивном главном окне; сигнализация бота использует тот же нативный механизм. Есть общий выключатель. Доставка уведомления на установленной Windows ещё не проверена.

Диктовка допускает повторное нажатие для остановки и отменяется при смене вкладки. Автотест проверяет, что поздний результат не меняет чужой черновик. Реальный микрофон и Windows System.Speech не включались.

Актуальные результаты: VERIFICATION.md. Ниже исторические записи; отметка о нереализованных OS notifications устарела.

---
# Integration implementation and verification

Telegram: explicit start/stop, own bot token only in Pult/.env, six-digit pairing code with ten-minute lifetime or manual owner ID, strict matching private-chat/sender owner authorization, callback query authorization, persisted update offset, queue-origin correlation via chat job origin, one-use callback capabilities, approvals/questions through ui.chats.answer, /help /chats /new /status /last /stop, selected chat and photo/document downloads capped at20MiB. Local personal turn results are not forwarded automatically. Metadata and failures do not expose token URLs. Polling stops on configure/unpair; late updates check generation. Questions support textual responses; multi-question responses are collected individually, one question at a time.

Voice: native Windows PowerShell System.Speech using static voice.ps1. JSON passed only through UTF-8 stdin, never interpolated into commands. Dictation, configured language, hands-free send, speaking replies and process cancellation. Requires installed Windows speech recognition/voice language and mic permissions. No microphone was enabled during development. Real Windows speech recording/output still needs runtime verification; Mac returns unsupported.

Updater: latest public GitHub metadata, installable Windows EXE asset requires GitHub SHA256 digest, redirects restricted to GitHub release hosts,250MB bound, PE header and SHA256 check before atomic staging and explicit installer launch. UI refuses while local chats are busy and asks user before install. No release installer downloaded or executed during development. Explicit opt-in automatic updates check once per hour while idle, install only strictly newer stable versions, and block during busy agents or connected rooms.

Support: OpenSSH Client command transport, host/key metadata only.env, fixed status/changes/deploy/log commands, timeout, UI deployment confirmation and log polling. VLESS TCP/WS/gRPC TLS/Reality via installed Xray, credentials only.env and generated config only stdin:, loopback10809, explicit start/stop. proxy_env supplies per-child environment; common parent utility integration required. Bot watcher polls status every 90 seconds after explicit enable and reports service-down and new trade losses of -40% or worse; native OS notifications remain unimplemented.

Verification performed: cargo check passed; support VLESS parser test passed; updater host trust/hash/PE tests and Telegram owner authorization tests added. Browser tests integrations.spec.js added for preventing personal-result forwarding and preserving Telegram job origin. Parent runs full Playwright suite to avoid shared-port conflicts. No live Telegram, SSH, proxy, microphone, update-install or bot-deploy operations were performed.

Integration audit continuation: updater installation now refuses while ui.team reports a connected room; speech reply playback only follows successful turns in the active chat. Telegram automatic replies are restricted to Telegram-origin agent messages created during the current tracked turn, so an empty/error turn cannot forward an older personal reply. Added updater connected-room regression spec. JS syntax and Telegram owner authorization Rust test passed; browser regression tests await root's shared-port run.

Follow-up completion: speech subprocess output capped at 1 MiB, listen/speak timeouts 45/300 seconds, cancellation preserves kill-on-drop; parser tolerates UTF-8 BOM and rejects invalid protocol. Added Rust speech and updater version tests; both passed. Telegram question regression spec added (individual answers), browser tests left to root. Live Windows speech, real auto-installer and remote SSH/Telegram still deliberately untested.
