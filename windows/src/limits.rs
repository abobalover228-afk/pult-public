// «Лимиты»: виджет (окно "limits"), окна «Аккаунты» и «Карта команд», значок в трее, автозапуск
// и режимы без окна: --statusline, --codex-auto, --limits-json.
use crate::util;
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::menu::{CheckMenuItemBuilder, MenuBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{ChildStdin, ChildStdout};

static CODEX: Mutex<Value> = Mutex::new(Value::Null); // {accounts, updated}
static LOADING: AtomicBool = AtomicBool::new(false);

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn codex_bin() -> PathBuf {
    util::find_bin("codex").unwrap_or_else(|| "codex".into())
}

// ───── Чтение лимитов Codex (официальный app-server; без ходов и платных действий) ─────

fn sanitize(account: &Value, result: &Value) -> Value {
    let one;
    let buckets = match result["rateLimitsByLimitId"].as_object().filter(|m| !m.is_empty()) {
        Some(m) => m,
        None => {
            one = json!({ "codex": result["rateLimits"] });
            one.as_object().unwrap()
        }
    };
    let mut clean = vec![];
    for (key, bucket) in buckets.iter().filter(|(_, b)| b.is_object()) {
        let num = |v: &Value| v.as_f64().filter(|n| n.is_finite());
        let windows: Vec<Value> = ["primary", "secondary"]
            .iter()
            .filter(|k| bucket[**k].is_object())
            .map(|kind| {
                let item = &bucket[*kind];
                let used = num(&item["usedPercent"]).filter(|u| (0.0..=100.0).contains(u));
                json!({ "kind": kind, "used_percent": used, "remaining_percent": used.map(|u| (100.0 - u).max(0.0)),
                        "minutes": num(&item["windowDurationMins"]), "resets_at": num(&item["resetsAt"]) })
            })
            .collect();
        let credits = bucket["credits"].as_object().map(|c| {
            ["hasCredits", "unlimited", "balance"].iter().filter_map(|k| c.get(*k).map(|v| (k.to_string(), v.clone()))).collect::<serde_json::Map<_, _>>()
        });
        let name = [&bucket["limitName"], &bucket["limitId"]].into_iter().find_map(|v| v.as_str().filter(|s| !s.is_empty())).unwrap_or(key);
        clean.push(json!({ "name": name, "plan": bucket["planType"], "windows": windows, "credits": credits }));
    }
    json!({ "available": true, "checked_at": now(), "auth": account["account"]["type"], "plan": account["account"]["planType"], "limits": clean })
}

async fn request(stdin: &mut ChildStdin, lines: &mut Lines<BufReader<ChildStdout>>, id: u64, method: &str, params: Value) -> Option<Value> {
    let mut msg = json!({ "id": id, "method": method });
    if !params.is_null() {
        msg["params"] = params;
    }
    stdin.write_all(format!("{msg}\n").as_bytes()).await.ok()?;
    loop {
        let line = lines.next_line().await.ok()??;
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v["id"] == id {
            // Сырые сообщения сервера, идентификаторы и токены наружу не выдаём.
            return v.get("error").is_none().then(|| v["result"].clone());
        }
    }
}

async fn talk(child: &mut tokio::process::Child) -> Option<Value> {
    let mut stdin = child.stdin.take()?;
    let mut lines = BufReader::new(child.stdout.take()?).lines();
    request(&mut stdin, &mut lines, 1, "initialize", json!({ "clientInfo": { "name": "pult_public", "title": "Pult limits", "version": "1.0" } })).await?;
    stdin.write_all(b"{\"method\":\"initialized\"}\n").await.ok()?;
    let account = request(&mut stdin, &mut lines, 2, "account/read", json!({ "refreshToken": false })).await?;
    if account["account"].is_null() {
        return Some(json!({ "available": false, "error": "Нет входа в Codex для этого пользователя." }));
    }
    let result = request(&mut stdin, &mut lines, 3, "account/rateLimits/read", Value::Null).await?;
    Some(sanitize(&account, &result))
}

/// Лимиты аккаунта Codex через app-server (формат как у limits.py sanitize): {available, plan, limits: [{name, windows: [{kind, used_percent, remaining_percent, minutes, resets_at}]}]}.
pub async fn read(home: &str) -> Value {
    let mut c = util::command(codex_bin());
    c.kill_on_drop(true);
    c.args(["app-server", "--listen", "stdio://"]).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
    if !home.is_empty() {
        c.env("CODEX_HOME", home);
    }
    let mut out = None;
    if let Ok(mut child) = c.spawn() {
        out = tokio::time::timeout(Duration::from_secs(18), talk(&mut child)).await.ok().flatten();
        let _ = child.kill().await;
    }
    out.unwrap_or_else(|| json!({ "available": false, "error": "Лимиты сейчас не получены. Остаток неизвестен." }))
}

/// Все аккаунты параллельно: {accounts: [{name, home, …лимиты}]} — как limits.py --json.
async fn all() -> Value {
    let tasks: Vec<_> = util::accounts()
        .into_iter()
        .map(|a| {
            tokio::spawn(async move {
                let mut v = read(&a.home).await;
                v["name"] = json!(a.name);
                v["home"] = json!(a.home);
                v
            })
        })
        .collect();
    let mut accounts = vec![];
    for t in tasks {
        accounts.push(t.await.unwrap_or_default());
    }
    json!({ "accounts": accounts })
}

async fn refresh(app: &AppHandle) {
    if LOADING.swap(true, SeqCst) {
        return;
    }
    let _ = app.emit("limits", ());
    let v = all().await;
    *CODEX.lock().unwrap() = json!({ "accounts": v["accounts"], "updated": now() * 1000.0 });
    LOADING.store(false, SeqCst);
    let _ = app.emit("limits", ());
}

// ───── Терминал, аккаунты, автозапуск ─────

/// Новое окно терминала с командой; CODEX_HOME передаётся окружением.
fn terminal(line: &str, codex_home: Option<&str>) {
    #[cfg(windows)]
    let mut c = {
        use std::os::windows::process::CommandExt;
        let mut c = std::process::Command::new("cmd");
        c.arg("/K").raw_arg(line).creation_flags(0x10); // CREATE_NEW_CONSOLE
        let mut path: Vec<PathBuf> = ["codex", "claude"].iter().filter_map(|b| util::find_bin(b)?.parent().map(Path::to_path_buf)).collect();
        path.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()));
        if let Ok(p) = std::env::join_paths(path) {
            c.env("PATH", p);
        }
        if let Some(h) = codex_home {
            c.env("CODEX_HOME", h);
        }
        c
    };
    #[cfg(not(windows))]
    let mut c = {
        let export = codex_home.map(|h| format!("export CODEX_HOME='{h}'; ")).unwrap_or_default();
        let script = format!("{export}export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; {line}");
        let script = script.replace('\\', "\\\\").replace('"', "\\\"");
        let mut c = std::process::Command::new("osascript");
        c.args(["-e", &format!("tell application \"Terminal\" to do script \"{script}\""), "-e", "tell application \"Terminal\" to activate"]);
        c
    };
    let _ = c.current_dir(util::home()).spawn();
}

/// Вход (если его нет), затем Codex — как open_codex.sh.
fn open_codex(codex_home: &str, login_only: bool) {
    let (nul, then) = if cfg!(windows) { ("nul", "&") } else { ("/dev/null", ";") };
    let line = if login_only {
        "codex login".to_string()
    } else {
        format!("codex login status >{nul} 2>&1 || codex login {then} codex --sandbox workspace-write --ask-for-approval on-request --no-alt-screen")
    };
    terminal(&line, Some(codex_home));
}

/// Новая папка ~/.codex-N, запись в ~/.codex-accounts.json и вход в новом терминале — как add_account.sh.
fn add_account() -> Result<(), String> {
    let file = util::home().join(".codex-accounts.json");
    let mut rows: Vec<util::Account> = match std::fs::read(&file) {
        Ok(d) => serde_json::from_slice(&d).map_err(|_| "Некорректный файл аккаунтов")?,
        Err(_) => vec![util::Account { name: "Codex".into(), home: "~/.codex".into() }],
    };
    let mut i = 2;
    while util::home().join(format!(".codex-{i}")).exists() {
        i += 1;
    }
    let dir = util::home().join(format!(".codex-{i}"));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let dir = dir.to_string_lossy().to_string();
    rows.push(util::Account { name: format!("Codex {i}"), home: dir.clone() });
    let tmp = file.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(&rows).unwrap_or_default()).and_then(|_| std::fs::rename(&tmp, &file)).map_err(|e| e.to_string())?;
    open_codex(&dir, true);
    Ok(())
}

/// Автозапуск при входе в Windows (HKCU\…\Run): Some — задать, None — только прочитать.
#[cfg(windows)]
fn autostart(set: Option<bool>) -> bool {
    let Ok((run, _)) = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER).create_subkey(r"Software\Microsoft\Windows\CurrentVersion\Run") else { return false };
    match (set, std::env::current_exe()) {
        (Some(true), Ok(exe)) => drop(run.set_value("Pult", &format!("\"{}\" --limits", exe.display()))),
        (Some(false), _) => drop(run.delete_value("Pult")),
        _ => {}
    }
    run.get_value::<String, _>("Pult").is_ok()
}
#[cfg(not(windows))]
fn autostart(_set: Option<bool>) -> bool {
    false
}

// ───── Окна и трей ─────

fn widget(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("limits")
}

fn shown(app: &AppHandle) -> bool {
    widget(app).and_then(|w| w.is_visible().ok()).unwrap_or(false)
}

/// Сохранённая позиция, если она на включённом экране; иначе — внизу по центру основного экрана, над Доком.
fn place(w: &WebviewWindow) {
    let saved = util::setting("dockPos");
    if let (Some(x), Some(y)) = (saved[0].as_i64(), saved[1].as_i64()) {
        let on_screen = w.available_monitors().unwrap_or_default().iter().any(|m| {
            let (p, s) = (m.position(), m.size());
            x + 40 >= p.x as i64 && x + 40 < p.x as i64 + s.width as i64 && y >= p.y as i64 && y + 40 < p.y as i64 + s.height as i64
        });
        if on_screen {
            let _ = w.set_position(tauri::PhysicalPosition::new(x as i32, y as i32));
            return;
        }
    }
    dock_default(w);
}
fn dock_default(w: &WebviewWindow) {
    if let (Ok(Some(m)), Ok(size)) = (w.primary_monitor(), w.outer_size()) {
        let f = m.scale_factor();
        let x = m.position().x + (m.size().width as i32 - size.width as i32) / 2;
        let y = m.position().y + m.size().height as i32 - size.height as i32 - (96.0 * f) as i32;
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    }
}

fn show(app: &AppHandle, on: bool) {
    let Some(w) = widget(app) else { return };
    if on {
        place(&w);
        let _ = w.show();
        let _ = w.set_focus();
    } else {
        let _ = w.hide();
    }
    util::set_setting("limitsShown", json!(on));
}

fn open(app: &AppHandle, label: &str, title: &str, size: (f64, f64), min: (f64, f64)) -> Result<(), String> {
    let w = match app.get_webview_window(label) {
        Some(w) => w,
        None => WebviewWindowBuilder::new(app, label, WebviewUrl::App("limits.html".into())).title(title).inner_size(size.0, size.1).min_inner_size(min.0, min.1).build().map_err(|e| e.to_string())?,
    };
    let _ = w.unminimize();
    let _ = w.show();
    let _ = w.set_focus();
    Ok(())
}

/// Позицию запоминаем только после того, как виджет перетащили рукой.
/// Действие для окна «Аккаунты» (войти, переименовать), пока оно открывается.
static PENDING_UI: std::sync::Mutex<Option<Value>> = std::sync::Mutex::new(None);
static DRAGGED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn init(app: &AppHandle) {
    let only = std::env::args().any(|a| a == "--limits");
    if let Ok(w) = WebviewWindowBuilder::new(app, "limits", WebviewUrl::App("limits.html".into()))
        .title("Лимиты")
        .inner_size(420.0, 150.0)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        // Настоящее размытие рабочего стола под доком, как у виджетов macOS; на Windows — акрил.
        .effects(tauri::window::EffectsBuilder::new()
            .effect(if cfg!(windows) { tauri::window::Effect::Acrylic } else { tauri::window::Effect::HudWindow })
            .state(tauri::window::EffectState::Active).radius(26.0).build())
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .build()
    {
        w.on_window_event(|e| {
            if let WindowEvent::Moved(p) = e {
                if p.x > -30000 && DRAGGED.load(SeqCst) && util::setting("dockPos") != json!([p.x, p.y]) {
                    util::set_setting("dockPos", json!([p.x, p.y]));
                }
            }
        });
    }
    if only || util::setting("limitsShown") != json!(false) {
        show(app, true);
    }
    // Пульт: с --limits не показывается; закрытие при видимом виджете только прячет окно, иначе завершает программу.
    if let Some(main) = app.get_webview_window("main") {
        if only {
            let _ = main.hide();
        }
        let (a, m) = (app.clone(), main.clone());
        main.on_window_event(move |e| {
            if let WindowEvent::CloseRequested { api, .. } = e {
                if shown(&a) {
                    api.prevent_close();
                    let _ = m.hide();
                } else {
                    a.exit(0);
                }
            }
        });
    }
    // Трей: левый щелчок — показать/скрыть виджет, правый — меню. Пункт меню "limits:<метод>" вызывает call.
    let mut menu = MenuBuilder::new(app).text("limits:pult", "Показать Пульт").text("limits:toggle", "Показать/скрыть Лимиты").separator().text("limits:refresh", "Обновить").text("limits:accounts", "Аккаунты…");
    if cfg!(windows) {
        if let Ok(item) = CheckMenuItemBuilder::with_id("limits:autostart", "Запускать при входе в Windows").checked(autostart(None)).build(app) {
            menu = menu.item(&item);
        }
    }
    if let Ok(menu) = menu.separator().text("limits:quit", "Выход").build() {
        let mut tray = TrayIconBuilder::with_id("limits").tooltip("Пульт · Лимиты").menu(&menu).show_menu_on_left_click(false).on_tray_icon_event(|tray, e| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                show(tray.app_handle(), !shown(tray.app_handle()));
            }
        });
        if let Some(icon) = app.default_window_icon() {
            tray = tray.icon(icon.clone());
        }
        let _ = tray.build(app);
    }
    app.on_menu_event(|app, e| {
        if let Some(rest) = e.id().as_ref().strip_prefix("acct:") {
            let mut parts = rest.split(':');
            let (Some(action), Some(Ok(i))) = (parts.next().map(str::to_string), parts.next().map(str::parse::<usize>)) else { return };
            let Some(account) = util::accounts().get(i).cloned() else { return };
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                match action.as_str() {
                    "remove" => drop(crate::accounts::call(&app, "remove", json!({ "home": account.home })).await),
                    "up" | "down" => drop(crate::accounts::call(&app, "move", json!({ "home": account.home, "step": if action == "up" { -1 } else { 1 } })).await),
                    _ => {
                        // Вход и переименование — в окне «Аккаунты»: там видно ссылку, код и поле имени.
                        *PENDING_UI.lock().unwrap() = Some(json!({ "action": action, "home": account.home }));
                        let _ = open(&app, "accounts", "Аккаунты", (520.0, 640.0), (440.0, 480.0));
                        let _ = app.emit("accounts-ui", ());
                    }
                }
                let _ = app.emit("limits", ());
            });
            return;
        }
        if let Some(method) = e.id().as_ref().strip_prefix("limits:") {
            let (app, method) = (app.clone(), method.to_string());
            tauri::async_runtime::spawn(async move {
                let _ = call(&app, &method, Value::Null).await;
            });
        }
    });
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            refresh(&app).await;
            tokio::time::sleep(Duration::from_secs(300)).await;
        }
    });
}

pub async fn call(app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    let home = a["home"].as_str().unwrap_or_default();
    match method {
        "state" => {
            let claude = std::fs::read(util::home().join(".claude/limits-cache.json")).ok().map(|d| String::from_utf8_lossy(&d).to_string());
            // Список аккаунтов берём свежий: убранный аккаунт исчезает сразу, переименованный — с новым именем, без ожидания обновления лимитов.
            let names = util::accounts();
            let mut codex = CODEX.lock().unwrap().clone();
            if let Some(rows) = codex["accounts"].as_array() {
                let kept: Vec<Value> = names.iter().map(|n| {
                    let mut row = rows.iter().find(|r| r["home"] == n.home.as_str()).cloned().unwrap_or_else(|| json!({ "home": n.home, "available": false, "limits": [] }));
                    row["name"] = json!(n.name); row
                }).collect();
                codex["accounts"] = json!(kept);
            }
            return Ok(json!({ "claude": claude, "codex": codex, "loading": LOADING.load(SeqCst), "names": names }));
        }
        "refresh" => refresh(app).await,
        "changed" => drop(app.emit("limits", ())),
        "toggle" => show(app, !shown(app)),
        "pult" => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
        }
        "accounts" => {
            open(app, "accounts", "Аккаунты", (460.0, 640.0), (420.0, 520.0))?;
            refresh(app).await;
        }
        "map" => open(app, "map", "Карта команд", (1120.0, 760.0), (880.0, 650.0))?,
        "tileMenu" => {
            // Правый щелчок по кольцу аккаунта. Удаление — через подменю, чтобы не убрать случайно.
            let i = util::accounts().iter().position(|x| x.home == util::expand(home)).ok_or("Аккаунт не найден")?;
            let name = a["name"].as_str().unwrap_or("аккаунт");
            let remove = tauri::menu::SubmenuBuilder::new(app, "Убрать из списка").text(format!("acct:remove:{i}"), format!("Да, убрать «{name}»")).text("limits:noop", "Нет, оставить").build().map_err(|e| e.to_string())?;
            let mut menu = MenuBuilder::new(app).text(format!("acct:login:{i}"), if a["signedIn"] == false { "Войти…" } else { "Войти заново…" }).text(format!("acct:rename:{i}"), "Переименовать…");
            if i > 0 { menu = menu.text(format!("acct:up:{i}"), "Сдвинуть левее"); }
            if i + 1 < util::accounts().len() { menu = menu.text(format!("acct:down:{i}"), "Сдвинуть правее"); }
            let menu = menu.item(&remove).separator().text("limits:accounts", "Все аккаунты…").text("limits:add", "Добавить аккаунт…").text("limits:refresh", "Обновить").text("limits:toggle", "Скрыть док").build().map_err(|e| e.to_string())?;
            let target = a["window"].as_str().and_then(|l| app.get_webview_window(l)).or_else(|| widget(app));
            if let Some(w) = target { w.popup_menu(&menu).map_err(|e| e.to_string())?; }
        }
        "noop" => {}
        "add" => { *PENDING_UI.lock().unwrap() = Some(json!({ "action": "add" })); open(app, "accounts", "Аккаунты", (520.0, 640.0), (440.0, 480.0))?; let _ = app.emit("accounts-ui", ()); }
        "takeUi" => return Ok(PENDING_UI.lock().unwrap().take().unwrap_or(Value::Null)),
        "drag" => { DRAGGED.store(true, SeqCst); drop(widget(app).map(|w| w.start_dragging())) }
        "dock" => { util::set_setting("dockPos", Value::Null); if let Some(w) = widget(app) { dock_default(&w); } }
        "fit" => {
            // Док растёт с числом аккаунтов; пока его не двигали, остаётся по центру снизу.
            if let Some(w) = widget(app) {
                let _ = w.set_size(tauri::LogicalSize::new(a["width"].as_f64().unwrap_or(420.0).clamp(160.0, 1400.0), a["height"].as_f64().unwrap_or(150.0).clamp(80.0, 900.0)));
                if util::setting("dockPos").is_null() { dock_default(&w); }
            }
        }
        "menu" => {
            let menu = MenuBuilder::new(app).text("limits:refresh", "Обновить").text("limits:toggle", "Скрыть виджет").text("limits:quit", "Выход").build().map_err(|e| e.to_string())?;
            if let Some(w) = widget(app) {
                w.popup_menu(&menu).map_err(|e| e.to_string())?;
            }
        }
        "open" => open_codex(home, false),
        "login" => open_codex(home, true),
        "usage" => terminal("claude /usage", None),
        "auto" => {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            if cfg!(windows) {
                let _ = std::process::Command::new(exe).arg("--codex-auto").current_dir(util::home()).spawn(); // консоль откроет себе сам
            } else {
                terminal(&format!("'{}' --codex-auto", exe.display()), None);
            }
        }
        "url" => {
            let url = a["url"].as_str().filter(|u| u.starts_with("https://") || u.starts_with("http://")).ok_or("не ссылка")?;
            let _ = if cfg!(windows) { util::command("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn() } else { util::command("open").arg(url).spawn() };
        }
        "autostart" => return Ok(json!(autostart(Some(a["on"].as_bool().unwrap_or(!autostart(None)))))),
        "quit" => app.exit(0),
        _ => return Err(format!("limits.{method}: нет такого метода")),
    }
    Ok(Value::Null)
}

// ───── Режимы без окна ─────

/// Режимы командной строки без интерфейса; true — отработали, выходим.
pub fn cli() -> bool {
    match std::env::args().nth(1).as_deref() {
        Some("--statusline") => statusline(),
        Some("--limits-json") => println!("{}", tokio::runtime::Runtime::new().unwrap().block_on(all())),
        Some("--codex-auto") => codex_auto(),
        _ => return false,
    }
    true
}

/// statusLine Claude Code: JSON со stdin → ~/.claude/limits-cache.json (только whitelist квот) → строка статуса.
/// Приватные OAuth-адреса не опрашиваются; без квоты время прошлого успеха не обновляется.
fn statusline() {
    let Ok(payload) = serde_json::from_reader::<_, Value>(std::io::stdin()) else { return };
    let num = |v: &Value| v.as_f64().filter(|n| n.is_finite());
    let (mut clean, mut parts) = (serde_json::Map::new(), vec![]);
    for (key, name) in [("five_hour", "5ч"), ("seven_day", "нед")] {
        let row = &payload["rate_limits"][key];
        let Some(used) = num(&row["used_percentage"]).filter(|u| (0.0..=100.0).contains(u)) else { continue };
        let mut item = json!({ "used_percentage": row["used_percentage"] });
        if num(&row["resets_at"]).is_some() {
            item["resets_at"] = row["resets_at"].clone();
        }
        clean.insert(key.into(), item);
        parts.push(format!("{name} {used:.0}%"));
    }
    if !clean.is_empty() {
        let dir = util::home().join(".claude");
        let _ = std::fs::create_dir_all(&dir);
        let tmp = dir.join(format!(".limits-cache-{}", std::process::id()));
        let data = json!({ "saved_at": now(), "source": "claude-code-statusline", "rate_limits": clean });
        if std::fs::write(&tmp, data.to_string()).and_then(|_| std::fs::rename(&tmp, dir.join("limits-cache.json"))).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
    println!("{}", if parts.is_empty() { "Квота Claude недоступна".into() } else { parts.join(" · ") });
}

// Codex авто: выбирает аккаунт с запасом лимита и переносит диалог между аккаунтами, когда лимит кончился.
// Перенос = копия rollout-…-<id>.jsonl в sessions/ другого аккаунта + `codex resume <id>`; auth.json не копируется.

/// Вывод в консоль. В Windows у оконной программы консоли нет — открываем свою.
fn say(s: &str) {
    #[cfg(windows)]
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("CONOUT$") {
        let _ = writeln!(f, "{s}");
        return;
    }
    println!("{s}");
    let _ = std::io::stdout().flush();
}

fn tty(_name: &str) -> std::process::Stdio {
    #[cfg(windows)]
    if let Ok(f) = std::fs::OpenOptions::new().read(true).write(true).open(_name) {
        return f.into();
    }
    std::process::Stdio::inherit()
}

fn mtime(p: &Path) -> SystemTime {
    p.metadata().and_then(|m| m.modified()).unwrap_or(UNIX_EPOCH)
}

/// sessions/ГГГГ/ММ/ДД/rollout-*.jsonl
fn sessions(home: &str) -> Vec<PathBuf> {
    let ls = |d: PathBuf| std::fs::read_dir(d).into_iter().flatten().flatten().map(|e| e.path());
    ls(Path::new(home).join("sessions"))
        .flat_map(ls)
        .flat_map(ls)
        .flat_map(ls)
        .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("rollout-") && n.ends_with(".jsonl")))
        .collect()
}

fn thread_id(p: &Path) -> String {
    let s = p.file_stem().and_then(|s| s.to_str()).unwrap_or_default();
    s.get(s.len().saturating_sub(36)..).unwrap_or(s).to_string()
}

/// Минимальный остаток по окнам, %; None — нет входа/неизвестно.
async fn left(home: String) -> Option<f64> {
    let d = read(&home).await;
    d["limits"].as_array()?.iter().flat_map(|b| b["windows"].as_array().into_iter().flatten()).filter_map(|w| w["remaining_percent"].as_f64()).reduce(f64::min)
}

async fn left_all(accounts: &[util::Account]) -> Vec<Option<f64>> {
    let tasks: Vec<_> = accounts.iter().map(|a| tokio::spawn(left(a.home.clone()))).collect();
    let mut out = vec![];
    for t in tasks {
        out.push(t.await.ok().flatten());
    }
    out
}

/// Кладёт самую свежую копию диалога tid в sessions/ аккаунта home.
fn sync(accounts: &[util::Account], tid: &str, home: &str) {
    let Some(newest) = accounts.iter().flat_map(|a| sessions(&a.home)).filter(|f| thread_id(f) == tid).max_by_key(|f| mtime(f)) else { return };
    let rel: PathBuf = newest.components().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect(); // ГГГГ/ММ/ДД/rollout-….jsonl
    let target = Path::new(home).join("sessions").join(rel);
    if newest != target {
        let _ = std::fs::create_dir_all(target.parent().unwrap());
        let _ = std::fs::copy(&newest, &target);
    }
}

/// Новые строки файла диалога: true, если ход оборвался на usage_limit_exceeded.
fn limit_hit(path: &Path, pos: u64) -> (bool, u64) {
    use std::io::{Read, Seek};
    let mut data = vec![];
    let Ok(mut f) = std::fs::File::open(path) else { return (false, pos) };
    if f.seek(std::io::SeekFrom::Start(pos)).is_err() || f.read_to_end(&mut data).is_err() {
        return (false, pos);
    }
    let end = data.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
    let hit = data[..end].split(|b| *b == b'\n').any(|line| serde_json::from_slice::<Value>(line).is_ok_and(|v| v["payload"]["error"]["codex_error_info"] == "usage_limit_exceeded"));
    (hit, pos + end as u64)
}

/// Запускает Codex; возвращает (id диалога, кончился ли лимит).
fn run(a: &util::Account, mut tid: Option<String>, prompt: Option<&str>) -> (Option<String>, bool) {
    say(&format!("\n▶ {}{}", a.name, tid.as_ref().map_or(" · новый диалог".into(), |t| format!(" · диалог {}…", t.get(..8).unwrap_or(t)))));
    let mut c = std::process::Command::new(codex_bin());
    if let Some(t) = &tid {
        c.args(["resume", t]);
    }
    c.arg("--no-alt-screen").args(prompt).env("CODEX_HOME", &a.home).stdin(tty("CONIN$")).stdout(tty("CONOUT$")).stderr(tty("CONOUT$"));
    c.current_dir(std::env::var_os("PULT_PROJECT").map(PathBuf::from).unwrap_or_else(util::home));
    let started = SystemTime::now() - Duration::from_secs(1);
    let Ok(mut child) = c.spawn() else {
        say("Не установлен Codex CLI. См. README.");
        return (tid, false);
    };
    let (mut watched, mut pos, mut hit) = (None::<PathBuf>, 0, false);
    while let Ok(None) = child.try_wait() {
        std::thread::sleep(Duration::from_millis(500));
        let Some(file) = &watched else {
            // файл этого диалога: известный id или новый, созданный после запуска
            let found = sessions(&a.home).into_iter().filter(|f| tid.as_ref().map_or(mtime(f) >= started, |t| thread_id(f) == *t)).max_by_key(|f| mtime(f));
            if let Some(f) = found {
                pos = if tid.is_some() { f.metadata().map_or(0, |m| m.len()) } else { 0 };
                tid = Some(thread_id(&f));
                watched = Some(f);
            }
            continue;
        };
        let (found, next) = limit_hit(file, pos);
        pos = next;
        if found {
            hit = true;
            std::thread::sleep(Duration::from_millis(1500)); // дать Codex дописать сообщение об ошибке
            if cfg!(windows) {
                let _ = std::process::Command::new("taskkill").args(["/T", "/F", "/PID", &child.id().to_string()]).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
            } else {
                let _ = child.kill();
                let _ = std::process::Command::new("stty").arg("sane").status();
            }
            let _ = child.wait();
        }
    }
    (tid, hit)
}

fn codex_auto() {
    #[cfg(windows)]
    unsafe {
        extern "system" {
            fn AllocConsole() -> i32;
            fn SetConsoleOutputCP(cp: u32) -> i32;
        }
        AllocConsole();
        SetConsoleOutputCP(65001);
    }
    let rt = tokio::runtime::Runtime::new().unwrap();
    let accounts = util::accounts();
    let rest = rt.block_on(left_all(&accounts));
    let best = |rest: &[Option<f64>], skip: &[usize]| (0..rest.len()).filter(|i| !skip.contains(i) && rest[*i].unwrap_or(0.0) > 0.0).max_by(|a, b| rest[*a].partial_cmp(&rest[*b]).unwrap());
    let mut cur = best(&rest, &[]).unwrap_or(0);
    say(&format!("Лимиты: {}", accounts.iter().zip(&rest).map(|(a, r)| format!("{} {}", a.name, r.map_or("?".into(), |r| format!("{r}%")))).collect::<Vec<_>>().join(", ")));
    let (mut tid, mut prompt, mut tried) = (None::<String>, None, vec![]);
    loop {
        let a = &accounts[cur];
        if let Some(t) = &tid {
            sync(&accounts, t, &a.home);
        }
        let (t, hit) = run(a, tid, prompt);
        tid = t;
        if !hit {
            break; // обычный выход из Codex — выходим и мы
        }
        tried.push(cur);
        let next = best(&rt.block_on(left_all(&accounts)), &tried);
        let (Some(next), true) = (next, tid.is_some()) else {
            say("\nЛимиты кончились на всех аккаунтах. Диалог сохранён — продолжишь после сброса.");
            break;
        };
        say(&format!("\n⚡ Лимит «{}» кончился → переключаю на «{}» и продолжаю диалог…", a.name, accounts[next].name));
        cur = next;
        prompt = Some("Лимит прошлого аккаунта кончился, тебя переключили на другой аккаунт с этим же диалогом. Продолжай ровно с того места, где остановился.");
    }
    if cfg!(windows) {
        say("\nНажмите Enter, чтобы закрыть окно.");
        if let Ok(f) = std::fs::File::open("CONIN$") {
            let _ = std::io::BufRead::read_line(&mut std::io::BufReader::new(f), &mut String::new());
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotas_exclude_credentials_and_keep_unknown_values_unknown() {
        let account = json!({ "account": { "type": "chatgpt", "planType": "plus", "email": "private@example.test", "accessToken": "secret" } });
        let result = json!({ "rateLimits": { "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1900000000 }, "secondary": { "usedPercent": -10 }, "accessToken": "secret" } });
        let clean = sanitize(&account, &result);
        assert_eq!(clean["limits"][0]["windows"][0]["remaining_percent"], 75.0);
        assert!(clean["limits"][0]["windows"][1]["remaining_percent"].is_null());
        assert!(!clean.to_string().contains("secret"));
        assert!(!clean.to_string().contains("private@"));
    }

    #[test]
    fn separate_limit_buckets_are_preserved() {
        let clean = sanitize(&json!({}), &json!({ "rateLimitsByLimitId": {
            "one": { "primary": { "usedPercent": 0 } },
            "two": { "primary": { "usedPercent": 100 } }
        } }));
        assert_eq!(clean["limits"].as_array().unwrap().len(), 2);
        let remaining: Vec<_> = clean["limits"].as_array().unwrap().iter().map(|l| l["windows"][0]["remaining_percent"].as_f64().unwrap()).collect();
        assert!(remaining.contains(&100.0));
        assert!(remaining.contains(&0.0));
    }
}
