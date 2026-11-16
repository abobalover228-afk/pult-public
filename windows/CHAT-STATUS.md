# Текущее состояние чата — 16 ноября 2026

Добавлены настоящий постраничный каталог Codex, выбор Claude-моделей, effort/Fast/plan и передача параметров в транспорт. Реализованы подсказки команд, закрытие вкладок, CLI без shell-интерполяции аргументов, переключение аккаунтов, песочница, дополнительные папки, review/revert и команды оригинала. Неполные slash-команды не отправляются модели.

Редактирование сохраняет старую ветку и создаёт независимый контекст с историей до изменённого сообщения. Отдельные правила чата применяются в новом контексте при изменении. Остановка сохраняет историю и приостанавливает очередь. Выход процесса завершает ход и гасит карточки разрешений. Pending branch context сохраняется при ошибке старта.

Добавлены локальные ссылки с line/column, фон с затемнением, clipboard images, native drag-drop и миниатюры. Диктовка останавливается повторным нажатием; поздние результаты не попадают в другую вкладку. Настройки записываются атомарно; ошибки записи возвращаются интерфейсу.

Отмена запуска теперь защищена и в Rust: старое поколение не может зарегистрировать процесс после stop, отправить RPC или ответить на разрешение нового процесса. Ошибка старого initialize не убивает заменивший процесс. Межпоточный regression проверяет отмену перед регистрацией.

Общие актуальные результаты: VERIFICATION.md. Ниже исторические записи, они описывают промежуточные состояния.

---
Chat additions: expired permission responses reject stale process generation/busy/done;
completion expires pending cards; stop during connect cancels queued turn by epoch;
Claude old events invalidated on stop; exit emits turnEnd for integrations.
All provider conversations now persist locally, including Claude session and Codex
thread/account; restoring local history supports all providers. Wire request IDs/params
are omitted from saved transcript, pending cards saved expired. Pins and reversible
hide/restore trash use existing thread filters, pinned rows sort first. /fork starts
an independent conversation with previous transcript supplied as data context.
No actual history is deleted.
JS syntax checks passed. Browser tests intentionally left for parent-owned run.
Full parity is NOT done: original PromptCoach, native Claude session list import,
provider-native thread fork versus transcript fork, some command semantics and
end-to-end CLI authentication/real model checks remain unverified/unimplemented.

PromptCoach now has isolated ephemeral Codex transport (or the selected API provider),
strict structured JSON schema/validation, first-round questions, free answers/options,
refinement, retry, timeout/cancel, explicit copy/insert, and stale snapshot/draft checks.
All tool approvals from its private process are rejected. Main chat history is never
sent as instructions and no prompt is sent automatically. Claude source explicitly
uses selected Codex account, matching original coach transport choice. Image attachments are passed as localImage to Codex or image_url data URLs to API
on the first coaching round; other attachments remain filenames in context.
Coach structured parsing browser fixture added; no paid calls made. Syntax checks passed.


2026-11-16 continuation: native Claude JSONL history now imports visible user/assistant
text on open, resumes the original session, and reuses its existing tab. Internal
thinking, tool payloads, meta and sidechain records are excluded. Paths must resolve
inside ~/.claude/projects with the matching session UUID; files above 32 MB are
rejected explicitly. Pin/trash now identify native Claude sessions before a local
snapshot exists. Rust parser regression and native-history UI regression pass.

Native fork continuation: Codex /fork uses thread/fork with a fresh provider thread;
Claude /fork resumes with --fork-session, clears the flag after the CLI reports its
new session ID. UI regressions cover both, source sessions remain intact. Pending
fork state is included in saved local conversations. 29 Rust and 16 chat/desktop
UI tests passed; real paid model turns have not been invoked.

Command parity continuation: /compact routes to Claude stream-json for Claude and
Codex thread/compact/start for Codex; API rejection is explicit. /cd canonicalizes
relative paths against the project directory in Rust and opens a separate chat.
/restart stops the idle provider process while retaining session/thread and
invalidates old events; /branch aliases provider-aware /fork. /model restarts an
existing Claude process so the next turn applies the new model. Busy changes are
rejected. Full browser suite: 32 passed, including local real WebRTC, compact,
project switch and session-preserving restart regressions.

Local branch recovery: saved transcripts now retain pending seed context and
restore it on open; repeated local history clicks reuse localId rather than
creating duplicate tabs. Transcript-based forks persist immediately, including
Claude pending fork flags. Full browser suite: 33 passed.

Disk persistence: saveLocal now uses the existing sync-and-rename atomic writer,
validates UUID filenames, and readLocal resolves only direct JSON children of the
conversation directory (32 MB bound). Rust regression verifies replacement reads
back and rejects traversal/nested foreign files. 30 Rust tests, 33 UI tests and
native main/limits readiness checks pass.

API persistence continuation: removed the duplicate pre-finish save. All providers
now use saveConversation through finish; a disk error preserves the completed
API turn and displays a persistence error. Regression checks exactly one write,
reply retention and completed turnEnd. 34 browser tests, 30 Rust tests, JS syntax,
custom-protocol build and native main/limits smoke-test pass on macOS.
