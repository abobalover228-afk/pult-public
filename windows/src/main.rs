// Пульт для Windows (собирается и на macOS/Linux). Один вход из интерфейса: call(module, method, args).
// Каждый модуль: `pub fn init(&AppHandle)` и `pub async fn call(&AppHandle, &str, Value) -> Result<Value, String>`.
// События в интерфейс: `app.emit("<module>", json)`. Своё состояние модуль держит в static.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod api;
mod claude;
mod codex;
mod limits;
mod mods;
mod support;
mod team;
mod telegram;
mod updater;
mod util;
mod voice;
use serde_json::Value;
use tauri::AppHandle;

#[tauri::command]
async fn call(app: AppHandle, module: String, method: String, args: Value) -> Result<Value, String> {
    match module.as_str() {
        "app" => util::call(&app, &method, args).await,
        "codex" => codex::call(&app, &method, args).await,
        "claude" => claude::call(&app, &method, args).await,
        "api" => api::call(&app, &method, args).await,
        "mods" => mods::call(&app, &method, args).await,
        "team" => team::call(&app, &method, args).await,
        "telegram" => telegram::call(&app, &method, args).await,
        "voice" => voice::call(&app, &method, args).await,
        "updater" => updater::call(&app, &method, args).await,
        "support" => support::call(&app, &method, args).await,
        "limits" => limits::call(&app, &method, args).await,
        _ => Err(format!("нет модуля {module}")),
    }
}

fn main() {
    // Режимы без окна (--statusline, --codex-auto …) обрабатывает limits::cli.
    if limits::cli() {
        return;
    }
    tauri::Builder::default()
        .setup(|app| {
            for init in [codex::init, claude::init, api::init, mods::init, team::init, telegram::init, voice::init, updater::init, support::init, limits::init] {
                init(app.handle());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![call])
        .run(tauri::generate_context!())
        .expect("pult");
}
