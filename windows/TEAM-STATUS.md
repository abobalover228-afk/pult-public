# Текущее состояние комнат — 16 ноября 2026

Мост SDK `team.state/send/addTask/claim` подключён к настоящим операциям комнаты. Копирование приглашения после создания своей комнаты не меняет локальную identity на identity чужого координатора. Принимаемые snapshots проверяются; задания модов требуют подтверждённой доски.

Каноническая доска и компактные receipts сохраняются атомарно в `Rooms/<room>.board.json`. После перезапуска повторный запрос не дублирует задачу. Повреждённый файл не затирается пустой доской. Все локальные тесты проходят; внешняя Mac/Windows-комната и реальная публикация PR не проверены.

Актуальные границы проверок: VERIFICATION.md. Ниже исторические записи промежуточной реализации.

---
# Team port status

Implemented the original authoritative board rules in Rust: task validation,
host-only repository changes, atomic claims (maximum three), sender ownership,
review/completion/release constraints, request idempotency, and GitHub URL/PR validation.

Verified: `cargo test --locked --manifest-path windows/Cargo.toml team::tests`
passes two tests covering claim races/idempotency/ownership and repository credentials.

Not yet implemented: signaling, AES-GCM negotiation, WebRTC, UI room lifecycle,
board envelope transport, worktrees, agent relay, offline outbox and PR publication.
The backend explicitly returns an unavailable error; no fabricated connection state.
No external rooms were contacted, messages sent, commits made or branches pushed.

Transport progress: team-transport.js now implements Swift-compatible AES-GCM
signaling (nonce+ciphertext+tag, AAD room|sender|recipient), STUN-only WebRTC,
pult-room-v1 ordered binary channels, 12KB fragment encoding and bounded assembly.
Rust HTTP proxy follows the rendezvous endpoints without redirects. team.js has
invitation join/leave, P2P messages and host-authoritative board envelopes.
No real cross-platform room connection has been verified yet. Remaining: room
creation, .env persistence, per-room board binding, worktrees/relay/PR and transport tests.

Further implementation: per-room board stores; room creation with create token read
only from Pult/team/.env, invitation persisted to that .env; GitHub project clone,
origin verification and isolated task worktree; agent launch after authoritative
assignment only, result relay limited to teamTask chats. Create/join/leave/chat/board
controls are present. Rust team tests and JS syntax checks passed after these changes.

Still missing/unverified: local multi-peer transport tests, actual Mac interoperability,
room identity restoration, offline task-update outbox, explicit host claim approval UI,
GitHub PR review/publication and matching original relay auto-turn budgets. Current
claims are canonical host-authorized but auto-applied by the host; not yet explicit
human approval. Never treat this as full parity or ready for release.

Latest corrections: room key is now generated with WebCrypto getRandomValues(32),
not UUID bytes. Incoming peer claims wait in a host UI approval queue; approving
applies the canonical atomic claim, rejecting responds without changing ownership.
Host identity is persisted only locally in team/.env during creation and restored;
joining someone else's invitation does not adopt their coordinator identity.
Invite security and Swift-compatible fragmentation Playwright specs are added in
windows/tests/team.spec.js. Parent will run them with the full test suite (port
1425 was occupied by another agent, so independent runs were intentionally stopped).

Added durable task-result outbox, protocol-compatible opt-in agent relay (owner
binding, duplicate suppression, 16-message inbox, 8 auto-turn budget reset by user),
and real two-page WebRTC test against the original Python rendezvous on loopback.
That new two-peer test is awaiting parent-run verification. Network clients now use
util::http_builder(), preserving timeout and no-redirect policy.

RTC recheck after account switch: real original-rendezvous two-peer test still fails
at ICE connectivity (stable offer/answer, remote descriptions set, pending candidates
empty). Chromium exposes only VPN/TUN 198.18.0.1 and server-reflexive public address;
allow-loopback flag did not expose loopback/LAN candidates. No system routes or VPN
settings changed; test remains a failing assertion rather than a skipped success.
Fixed a separate lifecycle race: late poll/signaling responses after stop can no
longer recreate peer connections. JS syntax verification passed.

Additional verified fixes: Rust board snapshots now serialize `ownerID` exactly as
Swift and the JS relay expect (accept legacy `ownerId` when decoding). Network peer
claims cannot bypass human approval with a forged `approved:true`: approval is now
an independent local UI function, never a field trusted from peer packets.
Git preparation is factored into a private helper; its local bare-repository test
proves isolated task worktrees, reuse without overwriting edits, and rejection of
foreign origins. Product preparation still accepts only validated GitHub URLs.
Worktree git-common-dir ownership and 120-second Git timeouts added.
Preview fingerprint includes HEAD and file names; files over32MiB require manual review.

PR UI/backend added: explicit preview/confirmation, compare files+fingerprint at
publish, verify GitHub origin and task branch, reject staged files and committed
secret paths, commit selected changes, push task branch, create PR via installed
`gh` with --body-file. No push/PR was executed in development. GitHub CLI auth
is required. Preview now includes tracked diff and untracked UTF-8 excerpts;
binary files show only their name and size and need manual examination.
This path compiles but its destructive stages still require local-remote tests
and a deliberate real Windows/GitHub runtime check before release claims.

2026-11-16: leave events now close and remove peer connections, release their room
slot, and clear fragments; failed/closed peers can be recreated on join. Three
transport regressions pass. Actual Chromium pair test still fails at ICE with
host 198.18.0.1 despite successful SDP exchange. Native Mac UI smoke and native
MCP stdio initialize/tools-list/gated-screenshot checks pass after this change.

ICE recovery: the lower peer ID initiates at most two ICE restarts on failed
connections; restart negotiation errors are surfaced. Listener cleanup covers
negotiationneeded. Regression verifies one-sided bounded retries. Native app
build and both WebView readiness acknowledgements pass. Default system route
is utun15; en0 has 172.20.10.9, while Chromium gathered VPN 198.18.0.1. No
system routes or VPN settings were modified.


Real WebRTC diagnostic resolved locally: replacing host ICE candidate addresses
with 127.0.0.1 inside the two-page test (same machine only) establishes actual
DTLS/SCTP and transfers the 50 KB fragmented board packet through the original
rendezvous. Production transport is unchanged. The default integration test now
explicitly names loopback candidates; npm run test:rtc:native retains the original
unmodified-network check, which fails under this machine's VPN route. This proves
local transport, encryption/signaling and fragmentation, not remote NAT traversal
or Mac/Windows interoperability. No TURN relay or fake data channel is used.
