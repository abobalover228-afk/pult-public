use serde_json::Value;
use tauri::AppHandle;

pub fn init(_app: &AppHandle) {}

pub async fn call(_app: &AppHandle, method: &str, _a: Value) -> Result<Value, String> {
    Err(format!("claude.{method}: не реализовано"))
}
