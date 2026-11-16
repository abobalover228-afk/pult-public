// Общее для всех модулей: пути, поиск CLI, запуск процессов без окна консоли, настройки, аккаунты.
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::AppHandle;

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
    let mut c = tokio::process::Command::new(bin.as_ref());
    #[cfg(windows)]
    c.creation_flags(0x0800_0000);
    c.kill_on_drop(true);
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

pub fn set_setting(key: &str, value: Value) {
    with_settings(|s| {
        s[key] = value;
        let _ = std::fs::write(data_dir().join("settings.json"), serde_json::to_vec_pretty(s).unwrap_or_default());
    })
}

pub async fn call(_app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    let key = a["key"].as_str().unwrap_or_default();
    Ok(match method {
        "get" => setting(key),
        "set" => {
            set_setting(key, a["value"].clone());
            Value::Null
        }
        "settings" => with_settings(|s| s.clone()),
        "accounts" => json!(accounts()),
        "info" => json!({ "os": std::env::consts::OS, "home": home(), "dataDir": data_dir(), "version": env!("CARGO_PKG_VERSION") }),
        _ => return Err(format!("app.{method}: нет такого метода")),
    })
}
