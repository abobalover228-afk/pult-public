// Общее для всех модулей: пути, поиск CLI, запуск процессов без окна консоли, настройки, аккаунты.
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU8, Ordering};
use tauri::{AppHandle, Manager};
use tauri_plugin_notification::NotificationExt;

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

/// Папка данных приложения (%APPDATA%\Pult на Windows).
pub fn data_dir() -> PathBuf {
    let d = dirs::data_dir().unwrap_or_else(home).join("Pult");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// "~/x" → полный путь.
pub fn expand(p: &str) -> String {
    match p.strip_prefix('~') {
        Some(rest) => format!("{}{}", home().display(), rest),
        None => p.to_string(),
    }
}

/// Полный путь к CLI (codex, claude, git…): PATH, затем обычные места установки. На Windows учитывает .exe/.cmd.
pub fn find_bin(name: &str) -> Option<PathBuf> {
    let exts: &[&str] = if cfg!(windows) { &[".exe", ".cmd", ".bat"] } else { &[""] };
    let mut dirs: Vec<PathBuf> = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
    let h = home();
    dirs.extend([h.join(".local/bin"), h.join(".cargo/bin"), h.join("AppData/Roaming/npm"), h.join(".npm-global/bin"), "/opt/homebrew/bin".into(), "/usr/local/bin".into()]);
    dirs.iter().flat_map(|d| exts.iter().map(move |e| d.join(format!("{name}{e}")))).find(|p| p.is_file())
}

/// Процесс без всплывающего окна консоли.
pub fn command(bin: impl AsRef<Path>) -> tokio::process::Command {
    let c = tokio::process::Command::new(bin.as_ref());
    #[cfg(windows)]
    let c = { let mut c = c; c.creation_flags(0x0800_0000); c };
    let mut c = c;
    c.envs(crate::support::proxy_env());
    c
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct Account {
    pub name: String,
    pub home: String,
}

/// Аккаунты Codex: ~/.codex-accounts.json [{name, home}]; без файла — один ~/.codex.
pub fn accounts() -> Vec<Account> {
    std::fs::read(home().join(".codex-accounts.json"))
        .ok()
        .and_then(|d| serde_json::from_slice::<Vec<Account>>(&d).ok())
        .map(|v| v.into_iter().map(|a| Account { home: expand(&a.home), ..a }).collect())
        .unwrap_or_else(|| vec![Account { name: "Codex".into(), home: expand("~/.codex") }])
}

pub static ENV: Mutex<()> = Mutex::new(());

static SETTINGS: Mutex<Option<Value>> = Mutex::new(None);

fn with_settings<T>(f: impl FnOnce(&mut Value) -> T) -> T {
    let mut g = SETTINGS.lock().unwrap();
    let v = g.get_or_insert_with(|| {
        std::fs::read(data_dir().join("settings.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_else(|| json!({}))
    });
    f(v)
}

/// Настройка по ключу (замена UserDefaults); Null, если нет.
pub fn setting(key: &str) -> Value {
    with_settings(|s| s[key].clone())
}

fn write_setting(key: &str, value: Value) -> Result<(), String> {
    with_settings(|s| {
        let mut next = s.clone(); next[key] = value;
        atomic_write(&data_dir().join("settings.json"), &serde_json::to_vec_pretty(&next).map_err(|_| "Не сохранить настройки")?)?;
        *s = next; Ok(())
    })
}
pub fn set_setting(key: &str, value: Value) {
    if let Err(error) = write_setting(key, value) { eprintln!("Настройки не сохранены: {error}"); }
}

static READY: AtomicU8 = AtomicU8::new(0);

pub fn smoke_test() -> bool { std::env::args().any(|a| a == "--smoke-test") }

pub async fn call(app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    let key = a["key"].as_str().unwrap_or_default();
    Ok(match method {
        "ready" => {
            if smoke_test() {
                let bit = match a["label"].as_str() { Some("main") => 1, Some("limits") => 2, _ => 0 };
                let ready = READY.fetch_or(bit, Ordering::SeqCst) | bit;
                println!("PULT_UI_READY {}", a["label"].as_str().unwrap_or_default());
                if ready == 3 { app.exit(0); }
            }
            Value::Null
        }
        "notify" => {
            notify(app, a["title"].as_str().unwrap_or("Пульт"), a["body"].as_str().unwrap_or_default(), a["background"].as_bool().unwrap_or(true))?;
            Value::Null
        }
        "get" => setting(key),
        "set" => {
            write_setting(key, a["value"].clone())?;
            Value::Null
        }
        "settings" => with_settings(|s| s.clone()),
        "accounts" => json!(accounts()),
        "info" => json!({ "os": std::env::consts::OS, "home": home(), "dataDir": data_dir(), "version": env!("CARGO_PKG_VERSION") }),
        _ => return Err(format!("app.{method}: нет такого метода")),
    })
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let parent = path.parent().ok_or("Нет родительской папки")?;
    std::fs::create_dir_all(parent).map_err(|_| "Не удалось создать каталог")?;
    let temp = parent.join(format!(".pult-save-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new(); options.write(true).create_new(true);
        #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
        let mut file = options.open(&temp)?; file.write_all(bytes)?; file.sync_all()?;
        std::fs::rename(&temp, path)
    })();
    if result.is_err() { let _ = std::fs::remove_file(temp); }
    result.map_err(|_| "Не удалось атомарно сохранить файл".into())
}


pub fn http_builder() -> reqwest::ClientBuilder {
    let builder = reqwest::Client::builder();
    if crate::support::proxy_env().is_empty() { builder } else {
        builder.proxy(reqwest::Proxy::all("http://127.0.0.1:10809").expect("local proxy URL"))
    }
}


pub fn notify(app: &AppHandle, title: &str, body: &str, background: bool) -> Result<(), String> {
    if smoke_test() || setting("notifications") == false { return Ok(()); }
    if background && app.get_webview_window("main").is_some_and(|w| w.is_focused().unwrap_or(false)) { return Ok(()); }
    app.notification().builder().title(title.chars().take(100).collect::<String>()).body(body.chars().take(180).collect::<String>()).show().map_err(|_| "Не удалось показать системное уведомление".into())
}


#[derive(Default)]
pub struct ProcessGenerations(Mutex<std::collections::HashMap<String,u64>>);
impl ProcessGenerations {
    pub fn admit<T>(&self, chat: &str, generation: u64, action: impl FnOnce() -> T) -> Result<T,String> {
        let mut current=self.0.lock().unwrap();
        if current.get(chat).is_some_and(|g| *g>generation) { return Err("Запуск CLI уже отменён".into()); }
        current.insert(chat.into(),generation); Ok(action())
    }
    pub fn current<T>(&self, chat: &str, generation: u64, action: impl FnOnce() -> T) -> Result<T,String> {
        let current=self.0.lock().unwrap();
        if current.get(chat)!=Some(&generation) { return Err("Запрос относится к прежнему процессу CLI".into()); }
        Ok(action())
    }
    pub fn cancel(&self, chat: &str, generation: Option<u64>, action: impl FnOnce()) {
        let mut current=self.0.lock().unwrap();
        let next=current.get(chat).copied().unwrap_or(0).saturating_add(1).max(generation.unwrap_or(0));
        current.insert(chat.into(),next); action();
    }
}
#[cfg(test)]
mod generation_tests {
    use super::*;
    #[test]
    fn cancelled_start_cannot_register_a_process_after_stop() {
        use std::sync::{Arc,Barrier};
        let gate=Arc::new(ProcessGenerations::default());let ready=Arc::new(Barrier::new(2));let proceed=Arc::new(Barrier::new(2));
        let (worker_gate,worker_ready,worker_proceed)=(gate.clone(),ready.clone(),proceed.clone());
        let worker=std::thread::spawn(move || {
            worker_gate.admit("chat",1,||()).unwrap();worker_ready.wait();worker_proceed.wait();
            worker_gate.admit("chat",1,||panic!("cancelled process was registered"))
        });
        ready.wait();gate.cancel("chat",Some(2),||());proceed.wait();assert!(worker.join().unwrap().is_err());
        assert!(gate.admit("chat",3,||()).is_ok());assert!(gate.current("chat",1,||panic!("old request reached replacement process")).is_err());assert!(gate.admit("other",1,||()).is_ok());
    }
}
