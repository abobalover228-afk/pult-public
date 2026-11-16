// Пульт для Windows (собирается и на macOS/Linux). Один вход из интерфейса: call(module, method, args).
// Каждый модуль: `pub fn init(&AppHandle)` и `pub async fn call(&AppHandle, &str, Value) -> Result<Value, String>`.
// События в интерфейс: `app.emit("<module>", json)`. Своё состояние модуль держит в static.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod accounts;
mod api;
mod claude;
mod codex;
mod computer;
mod limits;
mod mods;
mod mcp;
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
        "computer" => computer::call(&app, &method, args).await,
        "app" => util::call(&app, &method, args).await,
        "codex" => codex::call(&app, &method, args).await,
        "claude" => claude::call(&app, &method, args).await,
        "api" => api::call(&app, &method, args).await,
        "mcp" => mcp::call(&app, &method, args).await,
        "mods" => mods::call(&app, &method, args).await,
        "team" => team::call(&app, &method, args).await,
        "telegram" => telegram::call(&app, &method, args).await,
        "voice" => voice::call(&app, &method, args).await,
        "updater" => updater::call(&app, &method, args).await,
        "support" => support::call(&app, &method, args).await,
        "limits" => limits::call(&app, &method, args).await,
        "accounts" => accounts::call(&app, &method, args).await,
        _ => Err(format!("нет модуля {module}")),
    }
}

fn main() {
    // Режимы без окна (--statusline, --codex-auto …) обрабатывает limits::cli.
    if limits::cli() {
        return;
    }
    if computer::mcp_mode() && !cfg!(windows) {
        computer::serve_stdio();
        return;
    }
    let mut context = tauri::generate_context!();
    if computer::mcp_mode() {
        let w = &mut context.config_mut().app.windows[0];
        w.url = tauri::WebviewUrl::App("computer.html".into());
        w.title = "Пульт · Computer use".into();
        w.width = 460.0; w.height = 260.0; w.min_width = None; w.min_height = None;
        w.always_on_top = true; w.minimizable = false; w.maximizable = false;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .register_uri_scheme_protocol("pult-mod", |_ctx, request| mods::document(request.uri()))
        .setup(|app| {
            if computer::mcp_mode() { computer::start_mcp(app.handle().clone()); return Ok(()); }
            for init in [codex::init, claude::init, api::init, mods::init, team::init, telegram::init, voice::init, updater::init, support::init, limits::init] {
                init(app.handle());
            }
            if util::smoke_test() {
                let app = app.handle().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(20));
                    eprintln!("PULT_SMOKE_TIMEOUT: окна не подтвердили загрузку интерфейса");
                    app.exit(1);
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![call])
        .build(context)
        .expect("pult")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) { mods::stop_all(); computer::stop(app); }
        });
}
