use serde_json::Value;
use tauri::AppHandle;

pub fn init(_app: &AppHandle) {}

pub async fn call(_app: &AppHandle, method: &str, _a: Value) -> Result<Value, String> {
    Err(format!("limits.{method}: не реализовано"))
}

/// Режимы командной строки без интерфейса; true — отработали, выходим.
pub fn cli() -> bool {
    false
}

/// Лимиты аккаунта Codex через app-server (формат как у limits.py sanitize): {available, plan, limits: [{name, windows: [{kind, used_percent, remaining_percent, minutes, resets_at}]}]}.
pub async fn read(_home: &str) -> Value {
    serde_json::json!({ "available": false })
}
