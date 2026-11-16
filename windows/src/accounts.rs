// Аккаунты Codex: кто вошёл (почта и тариф из локального auth.json), вход по одноразовому коду прямо в Пульте,
// переименование, порядок и удаление из списка. В сеть сам не ходит: вход делает официальный `codex login --device-auth`.
use crate::util::{self, Account};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, BufReader};

/// Идущие входы: id → процесс `codex login`.
static LOGINS: Mutex<Option<HashMap<String, tokio::process::Child>>> = Mutex::new(None);

fn file() -> PathBuf { util::home().join(".codex-accounts.json") }

fn save(rows: &[Account]) -> Result<(), String> {
    let home = util::home().to_string_lossy().to_string();
    let list: Vec<Value> = rows.iter().map(|a| {
        let short = a.home.strip_prefix(&home).map(|rest| format!("~{rest}")).unwrap_or_else(|| a.home.clone());
        json!({ "name": a.name, "home": short })
    }).collect();
    util::atomic_write(&file(), &serde_json::to_vec_pretty(&list).map_err(|e| e.to_string())?)
}

/// Почта, тариф и срок подписки из id_token в auth.json. Токены наружу не отдаются.
pub fn profile(home: &str) -> Value {
    use base64::Engine;
    let Ok(bytes) = std::fs::read(Path::new(home).join("auth.json")) else { return json!({ "signedIn": false }) };
    let Ok(root) = serde_json::from_slice::<Value>(&bytes) else { return json!({ "signedIn": false }) };
    if root["OPENAI_API_KEY"].as_str().is_some_and(|k| !k.is_empty()) { return json!({ "signedIn": true, "plan": "API-ключ" }); }
    let Some(token) = root["tokens"]["id_token"].as_str() else { return json!({ "signedIn": false }) };
    let claims = token.split('.').nth(1)
        .and_then(|p| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(p.trim_end_matches('=')).ok())
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok()).unwrap_or(Value::Null);
    let auth = &claims["https://api.openai.com/auth"];
    json!({ "signedIn": true, "email": claims["email"], "plan": auth["chatgpt_plan_type"], "paidUntil": auth["chatgpt_subscription_active_until"] })
}

fn strip_ansi(line: &str) -> String {
    let mut out = String::new(); let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' { for c in chars.by_ref() { if c.is_ascii_alphabetic() { break; } } } else { out.push(c); }
    }
    out
}
/// Ссылка и одноразовый код из вывода `codex login --device-auth`.
fn parse(line: &str) -> (Option<String>, Option<String>) {
    let text = strip_ansi(line); let word = text.trim();
    let url = word.split_whitespace().find(|w| w.starts_with("https://")).map(str::to_string);
    let code = (url.is_none() && word.len() <= 16 && word.contains('-') && word.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '-')
        && word.split('-').count() == 2).then(|| word.to_string());
    (url, code)
}

/// Имя для нового аккаунта: начало почты, без повторов.
fn name_for(email: &str, rows: &[Account]) -> String {
    let base = email.split('@').next().filter(|s| !s.is_empty()).unwrap_or("Codex").chars().take(24).collect::<String>();
    let mut name = base.clone(); let mut i = 2;
    while rows.iter().any(|a| a.name == name) { name = format!("{base} {i}"); i += 1; }
    name
}

fn next_home() -> PathBuf {
    let mut i = 2;
    while util::home().join(format!(".codex-{i}")).exists() { i += 1; }
    util::home().join(format!(".codex-{i}"))
}

async fn login(app: &AppHandle, a: &Value) -> Result<Value, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let fresh = a["home"].as_str().is_none_or(str::is_empty);
    let home = if fresh {
        let dir = next_home();
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        // Те же настройки и MCP, что у основного аккаунта.
        let _ = std::fs::copy(util::home().join(".codex/config.toml"), dir.join("config.toml"));
        dir.to_string_lossy().to_string()
    } else { util::expand(a["home"].as_str().unwrap()) };
    let bin = util::find_bin("codex").ok_or("Не найден codex. Установи Codex CLI")?;
    let mut child = util::command(bin).args(["login", "--device-auth"]).env("CODEX_HOME", &home).env("NO_COLOR", "1")
        .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).kill_on_drop(true)
        .spawn().map_err(|_| "Не удалось запустить codex login")?;
    let (out, err) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
    LOGINS.lock().unwrap().get_or_insert_with(HashMap::new).insert(id.clone(), child);
    let (app2, id2, home2) = (app.clone(), id.clone(), home.clone());
    tokio::spawn(async move {
        let mut lines = BufReader::new(out).lines(); let mut errors = BufReader::new(err).lines();
        let (mut url, mut code, mut tail) = (None::<String>, None::<String>, String::new());
        loop {
            let line = tokio::select! { l = lines.next_line() => l, l = errors.next_line() => l };
            let Ok(Some(line)) = line else { break };
            let (u, c) = parse(&line);
            if u.is_some() && url.is_none() { url = u; }
            if c.is_some() && code.is_none() { code = c; }
            let clean = strip_ansi(&line); if !clean.trim().is_empty() { tail = clean.trim().chars().take(300).collect(); }
            if let (Some(u), Some(c)) = (&url, &code) {
                if !tail.is_empty() && tail.contains(c.as_str()) {
                    let _ = app2.emit("accounts", json!({ "id": id2, "stage": "code", "url": u, "code": c, "expires": 15 }));
                }
            }
        }
        let child = LOGINS.lock().unwrap().as_mut().and_then(|m| m.remove(&id2));
        let ok = match child { Some(mut c) => c.wait().await.is_ok_and(|s| s.success()), None => { finish_cancel(&home2, fresh); return; } };
        let p = profile(&home2);
        if !ok || p["signedIn"] != true {
            finish_cancel(&home2, fresh);
            let _ = app2.emit("accounts", json!({ "id": id2, "stage": "error", "message": if tail.is_empty() { "Вход не завершён".to_string() } else { tail } }));
            return;
        }
        let email = p["email"].as_str().unwrap_or_default().to_string();
        let mut rows = util::accounts();
        // Тот же человек уже есть в списке — второй раз не добавляем, лимит у них общий.
        let twin = rows.iter().find(|a| a.home != home2 && !email.is_empty() && profile(&a.home)["email"] == email.as_str()).map(|a| a.name.clone());
        let mut name = rows.iter().find(|a| a.home == home2).map(|a| a.name.clone());
        if fresh && twin.is_none() {
            let n = name_for(&email, &rows); rows.push(Account { name: n.clone(), home: home2.clone() }); name = Some(n);
            let _ = save(&rows);
        } else if fresh { finish_cancel(&home2, true); }
        let _ = app2.emit("accounts", json!({ "id": id2, "stage": "done", "email": email, "plan": p["plan"], "name": name.or(twin.clone()), "duplicate": twin }));
        let _ = app2.emit("limits", ());
    });
    Ok(json!({ "id": id, "home": home }))
}

/// Новый аккаунт не вошёл — убираем пустую папку, чтобы не плодить ~/.codex-N.
fn finish_cancel(home: &str, fresh: bool) {
    if fresh && !Path::new(home).join("auth.json").exists() && Path::new(home).starts_with(util::home()) { let _ = std::fs::remove_dir_all(home); }
}

fn login_browsers() -> Vec<(PathBuf, &'static str, &'static str)> {
    let mut browsers: Vec<(PathBuf, &str, &str)> = Vec::new();
    #[cfg(target_os = "macos")]
    for root in [util::home().join("Applications"), PathBuf::from("/Applications")] {
        for (app, bin, flag) in [("Google Chrome", "Google Chrome", "--incognito"), ("Microsoft Edge", "Microsoft Edge", "--inprivate"), ("Brave Browser", "Brave Browser", "--incognito"), ("Firefox", "firefox", "--private-window")] {
            browsers.push((root.join(format!("{app}.app/Contents/MacOS/{bin}")), app, flag));
        }
    }
    #[cfg(target_os = "windows")]
    for root in ["PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA"].iter().filter_map(std::env::var_os) {
        for (path, name, flag) in [("Microsoft/Edge/Application/msedge.exe", "Microsoft Edge", "--inprivate"), ("Google/Chrome/Application/chrome.exe", "Google Chrome", "--incognito"), ("Mozilla Firefox/firefox.exe", "Firefox", "--private-window")] {
            browsers.push((PathBuf::from(&root).join(path), name, flag));
        }
    }
    #[cfg(target_os = "macos")]
    browsers.push((PathBuf::from("/Applications/Safari.app/Contents/MacOS/Safari"), "Safari", ""));
    browsers.retain(|(path, _, _)| path.is_file());
    let mut names = std::collections::HashSet::new();
    browsers.retain(|(_, name, _)| names.insert(*name));
    browsers
}

async fn open_private(url: &str) -> Result<Value, String> {
    let parsed = reqwest::Url::parse(url).map_err(|_| "Некорректная ссылка входа")?;
    if parsed.scheme() != "https" || parsed.host_str() != Some("auth.openai.com") || !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("Разрешена только HTTPS-ссылка входа auth.openai.com".into());
    }
    let choice = util::setting("loginBrowser");
    let choice = choice.as_str().unwrap_or("auto");
    let browsers = login_browsers().into_iter().filter(|(_, name, _)| if choice == "auto" { *name == "Google Chrome" } else { *name == choice });
    for (path, name, flag) in browsers {
        if !path.is_file() { continue; }
        #[cfg(target_os = "macos")]
        let mut command = {
            let mut c = util::command("/usr/bin/open");
            c.arg("-a").arg(path.ancestors().nth(3).unwrap());
            if !flag.is_empty() { c.arg("-n").arg("--args").arg(flag); }
            c.arg(url);
            c
        };
        #[cfg(not(target_os = "macos"))]
        let mut command = { let mut c = util::command(&path); if !flag.is_empty() { c.arg(flag); } c.arg(url); c };
        if let Ok(mut child) = command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn() {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            if child.try_wait().map_err(|e| e.to_string())?.is_some_and(|s| !s.success()) { continue; }
            tokio::spawn(async move { let _ = child.wait().await; });
            return Ok(json!({ "private": !flag.is_empty(), "browser": name }));
        }
    }
    let mut command = if cfg!(windows) { let mut c = util::command("rundll32"); c.arg("url.dll,FileProtocolHandler"); c } else { util::command("/usr/bin/open") };
    let status = command.arg(url).status().await.map_err(|e| e.to_string())?;
    if !status.success() { return Err("Не удалось открыть браузер по умолчанию".into()); }
    Ok(json!({ "private": false, "browser": "по умолчанию" }))
}

pub async fn call(app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    let home = a["home"].as_str().map(util::expand).unwrap_or_default();
    match method {
        "list" => Ok(json!(util::accounts().into_iter().map(|acc| { let mut p = profile(&acc.home); p["name"] = json!(acc.name); p["home"] = json!(acc.home); p }).collect::<Vec<_>>())),
        "login" => login(app, &a).await,
        "browsers" => Ok(json!({ "selected": util::setting("loginBrowser"), "items": login_browsers().iter().map(|(_, name, flag)| json!({ "name": name, "private": !flag.is_empty() })).collect::<Vec<_>>() })),
        "browser" => {
            let name = a["name"].as_str().unwrap_or("auto");
            if name != "auto" && name != "default" && !login_browsers().iter().any(|(_, n, _)| *n == name) { return Err("Браузер не найден".into()); }
            util::set_setting("loginBrowser", json!(name)); Ok(Value::Null)
        }
        "openPrivate" => open_private(a["url"].as_str().unwrap_or_default()).await,
        "cancel" => {
            let id = a["id"].as_str().unwrap_or_default();
            if let Some(mut c) = LOGINS.lock().unwrap().as_mut().and_then(|m| m.remove(id)) { let _ = c.start_kill(); }
            Ok(Value::Null)
        }
        "rename" => {
            let name = a["name"].as_str().map(str::trim).filter(|n| !n.is_empty() && n.chars().count() <= 40).ok_or("Имя — от 1 до 40 символов")?;
            let mut rows = util::accounts();
            if rows.iter().any(|x| x.name == name && x.home != home) { return Err("Такое имя уже есть".into()); }
            rows.iter_mut().find(|x| x.home == home).ok_or("Аккаунт не найден")?.name = name.into();
            save(&rows)?; let _ = app.emit("limits", ()); Ok(Value::Null)
        }
        "move" => {
            let mut rows = util::accounts(); let i = rows.iter().position(|x| x.home == home).ok_or("Аккаунт не найден")?;
            let j = (i as i64 + a["step"].as_i64().unwrap_or(0)).clamp(0, rows.len() as i64 - 1) as usize; rows.swap(i, j);
            save(&rows)?; let _ = app.emit("limits", ()); Ok(Value::Null)
        }
        "remove" => {
            // Только из списка: папка, вход и диалоги остаются на диске.
            let mut rows = util::accounts(); if rows.len() < 2 { return Err("Оставь хотя бы один аккаунт".into()); }
            rows.retain(|x| x.home != home); save(&rows)?; let _ = app.emit("limits", ()); Ok(Value::Null)
        }
        _ => Err(format!("accounts.{method}: нет такого метода")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn device_login_output_is_parsed() {
        assert_eq!(parse("   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m").0.as_deref(), Some("https://auth.openai.com/codex/device"));
        assert_eq!(parse("   \u{1b}[94mM98Q-ID862\u{1b}[0m").1.as_deref(), Some("M98Q-ID862"));
        assert_eq!(parse("2. Enter this one-time code (expires in 15 minutes)").1, None);
        assert_eq!(parse("Welcome to Codex [v0.169.0]").1, None);
    }
    #[test]
    fn names_are_unique() {
        let rows = vec![Account { name: "ivan".into(), home: "/a".into() }];
        assert_eq!(name_for("ivan@example.com", &rows), "ivan 2");
        assert_eq!(name_for("", &rows), "Codex");
    }
}
