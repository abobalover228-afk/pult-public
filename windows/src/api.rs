use crate::util;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::{Arc, LazyLock, Mutex}, time::Duration};
use tauri::AppHandle;
use tokio::sync::Notify;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Connection { id: String, name: String, base_url: String, model: String }
static STORE: Mutex<()> = Mutex::new(());
static REQUESTS: LazyLock<Mutex<HashMap<String, Arc<Notify>>>> = LazyLock::new(Default::default);
pub fn init(_app: &AppHandle) {}

impl Connection {
    fn endpoint(&self) -> Result<reqwest::Url, String> {
        if uuid::Uuid::parse_str(&self.id).is_err() || self.name.trim().is_empty() || self.name.len() > 120 || self.model.trim().is_empty() || self.model.len() > 200 || self.model.contains(['\r', '\n']) {
            return Err("Укажи корректные название и модель подключения".into());
        }
        let mut url = reqwest::Url::parse(self.base_url.trim()).map_err(|_| "Некорректный base URL")?;
        let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
        if !(url.scheme() == "https" || (url.scheme() == "http" && local)) || !url.username().is_empty() || url.password().is_some() || url.query().is_some() || url.fragment().is_some() || url.host_str().is_none() {
            return Err("Нужен HTTPS URL без логина, query и #. HTTP разрешён только для localhost".into());
        }
        let path = url.path().trim_end_matches('/').to_string();
        url.set_path(&if path.ends_with("/chat/completions") { path } else { format!("{path}/chat/completions") });
        Ok(url)
    }
    fn env_name(&self) -> String { format!("PULT_API_{}_B64", self.id.replace('-', "").to_uppercase()) }
}
fn connections() -> Result<Vec<Connection>, String> {
    let file = util::data_dir().join("connections.json");
    if !file.exists() { return Ok(vec![]); }
    let rows: Vec<Connection> = serde_json::from_slice(&std::fs::read(file).map_err(|_| "Не удалось прочитать подключения")?).map_err(|_| "Файл подключений повреждён; он сохранён без изменений")?;
    let mut ids = std::collections::HashSet::new();
    for c in &rows { c.endpoint()?; if !ids.insert(&c.id) { return Err("Повторяющийся ID подключения".into()); } }
    Ok(rows)
}
fn secrets() -> Result<String, String> {
    match std::fs::read_to_string(util::data_dir().join(".env")) {
        Ok(text) => Ok(text), Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(_) => Err("Нет доступа к .env приложения".into()),
    }
}
fn key(c: &Connection, env: &str) -> Result<String, String> {
    env.lines().find_map(|line| line.split_once('=').filter(|(k, _)| *k == c.env_name()).map(|(_, v)| v))
        .and_then(|v| STANDARD.decode(v).ok()).and_then(|v| String::from_utf8(v).ok()).filter(|v| !v.is_empty()).ok_or_else(|| "API-ключ отсутствует в .env приложения".into())
}
/// На Mac ключ живёт в Связке ключей, а не в .env. Старые ключи из .env читаются и переносятся при сохранении.
#[cfg(target_os = "macos")]
fn keychain(c: &Connection) -> Result<keyring::Entry, String> { keyring::Entry::new("Пульт API", &c.id).map_err(|_| "Связка ключей недоступна".into()) }
fn stored(c: &Connection, env: &str) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    if let Ok(k) = keychain(c).and_then(|e| e.get_password().map_err(|e| e.to_string())) { if !k.is_empty() { return Ok(k); } }
    key(c, env)
}
fn write_file(name: &str, bytes: &[u8], private: bool) -> Result<(), String> {
    use std::io::Write;
    let dir = util::data_dir();
    let temp = dir.join(format!(".save-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new(); options.write(true).create_new(true);
        #[cfg(unix)] {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(if private { 0o600 } else { 0o644 });
        }
        #[cfg(not(unix))] let _ = private;
        let mut file = options.open(&temp)?; file.write_all(bytes)?; file.sync_all()?;
        std::fs::rename(&temp, dir.join(name))
    })();
    if result.is_err() { let _ = std::fs::remove_file(temp); }
    result.map_err(|_| "Не удалось сохранить настройки подключения".into())
}
fn save(a: Value) -> Result<Value, String> {
    let _guard = STORE.lock().unwrap();
    let _env = util::ENV.lock().unwrap();
    let mut c: Connection = serde_json::from_value(a["connection"].clone()).map_err(|_| "Некорректное подключение")?;
    c.name = c.name.trim().into(); c.model = c.model.trim().into(); c.base_url = c.base_url.trim().into(); c.endpoint()?;
    let old_env = secrets()?;
    let new_key = a["key"].as_str().unwrap_or_default().trim();
    let active_key = if new_key.is_empty() { stored(&c, &old_env)? } else { new_key.into() };
    if active_key.len() > 16384 || !active_key.bytes().all(|b| (32..=126).contains(&b)) || active_key.is_empty() { return Err("Ключ должен быть одной строкой печатных символов".into()); }
    if [&c.name, &c.model, &c.base_url].iter().any(|v| v.contains(&active_key)) { return Err("Ключ разрешён только в поле API-ключа".into()); }
    let mut rows = connections()?; rows.retain(|r| r.id != c.id); rows.push(c.clone());
    #[allow(unused_mut)]
    let mut env: String = old_env.lines().filter(|l| !l.starts_with(&format!("{}=", c.env_name()))).map(|l| format!("{l}\n")).collect();
    #[cfg(target_os = "macos")]
    keychain(&c)?.set_password(&active_key).map_err(|_| "Не удалось сохранить ключ в Связку ключей")?;
    #[cfg(not(target_os = "macos"))]
    env.push_str(&format!("{}={}\n", c.env_name(), STANDARD.encode(&active_key)));
    write_file(".env", env.as_bytes(), true)?;
    if let Err(e) = write_file("connections.json", &serde_json::to_vec_pretty(&rows).map_err(|_| "Ошибка настроек")?, false) {
        let _ = write_file(".env", old_env.as_bytes(), true); return Err(e);
    }
    Ok(json!(rows))
}
fn http_error(code: u16) -> String {
    match code {
        300..=399 => "API перенаправляет запрос. Укажи конечный URL; ключ не пересылался".into(),
        401 | 403 => "API отклонил доступ. Проверь ключ и модель".into(),
        404 => "API endpoint или модель не найдены. Проверь base URL (обычно /v1)".into(),
        429 => "Квота, баланс или частота API исчерпаны. Остаток неизвестен".into(),
        500..=599 => "API временно недоступен".into(),
        _ => format!("API вернул HTTP {code}"),
    }
}
fn parse(v: Value, key: &str) -> Result<Value, String> {
    let choice = &v["choices"][0]; let message = &choice["message"];
    if message["tool_calls"].as_array().is_some_and(|a| !a.is_empty()) { return Err("API-модель запросила инструменты. В API-чате поддерживаются текст и изображения".into()); }
    if choice["finish_reason"] == "length" { return Err("Ответ обрезан лимитом модели. Автоматического повторного запроса не было".into()); }
    let text = message["content"].as_str().map(str::to_string).unwrap_or_else(|| message["content"].as_array().into_iter().flatten().filter_map(|b| b["text"].as_str()).collect::<Vec<_>>().join("\n"));
    if text.trim().is_empty() { return Err("API вернул пустой ответ или другой формат. Нужен Chat Completions".into()); }
    Ok(json!({ "text": text.replace(key, "[API key hidden]"), "inputTokens": v["usage"]["prompt_tokens"].as_u64(), "outputTokens": v["usage"]["completion_tokens"].as_u64() }))
}
async fn request(c: Connection, secret: String, messages: Value) -> Result<Value, String> {
    if !messages.is_array() { return Err("Нет сообщений API".into()); }
    let client = util::http_builder().redirect(reqwest::redirect::Policy::none()).timeout(Duration::from_secs(120)).build().map_err(|_| "Ошибка HTTP-клиента")?;
    let mut response = client.post(c.endpoint()?).bearer_auth(&secret).json(&json!({ "model": c.model, "messages": messages, "stream": false })).send().await.map_err(|_| "Не удалось связаться с API. Проверь сеть, сертификат и base URL")?;
    if !response.status().is_success() { return Err(http_error(response.status().as_u16())); }
    let mut bytes = vec![];
    while let Some(chunk) = response.chunk().await.map_err(|_| "Ответ API оборвался")? {
        if bytes.len() + chunk.len() > 16 * 1024 * 1024 { return Err("Ответ API больше 16 МБ".into()); }
        bytes.extend_from_slice(&chunk);
    }
    parse(serde_json::from_slice(&bytes).map_err(|_| "API вернул некорректный JSON")?, &secret)
}
pub async fn call(_app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    match method {
        "list" => { let _guard = STORE.lock().unwrap(); Ok(json!(connections()?)) }
        "save" => save(a),
        "remove" => {
            let _guard = STORE.lock().unwrap();
            let _env = util::ENV.lock().unwrap();
            let mut rows = connections()?;
            let id = a["id"].as_str().ok_or("Нет ID подключения")?;
            let c = rows.iter().find(|c| c.id == id).ok_or("Подключение не найдено")?.clone();
            let old_env = secrets()?;
            let env: String = old_env.lines().filter(|l| !l.starts_with(&format!("{}=", c.env_name()))).map(|l| format!("{l}\n")).collect();
            rows.retain(|c| c.id != id);
            #[cfg(target_os = "macos")]
            if let Ok(entry) = keychain(&c) { let _ = entry.delete_credential(); }
            write_file(".env", env.as_bytes(), true)?;
            if let Err(e) = write_file("connections.json", &serde_json::to_vec_pretty(&rows).map_err(|_| "Ошибка настроек")?, false) {
                let _ = write_file(".env", old_env.as_bytes(), true); return Err(e);
            }
            Ok(json!(rows))
        }
        "readText" => {
            use std::io::Read;
            let file = std::fs::File::open(a["path"].as_str().ok_or("Не указан путь")?).map_err(|_| "Не удалось прочитать вложение")?;
            let mut bytes = vec![]; file.take(1024 * 1024 + 1).read_to_end(&mut bytes).map_err(|_| "Ошибка чтения вложения")?;
            if bytes.len() > 1024 * 1024 { return Err("Текстовое вложение больше 1 МБ".into()); }
            let text = String::from_utf8(bytes).map_err(|_| "Вложение не является текстом UTF-8")?;
            if text.contains('\0') { return Err("Бинарное вложение не поддерживается".into()); }
            Ok(json!(text))
        }
        "send" => {
            let (c, secret) = {
                let _guard = STORE.lock().unwrap();
                let c = connections()?.into_iter().find(|c| c.id == a["connection"].as_str().unwrap_or_default()).ok_or("Подключение не найдено")?;
                let secret = stored(&c, &secrets()?)?; (c, secret)
            };
            let chat = a["chat"].as_str().ok_or("Нет чата")?.to_string();
            let cancel = Arc::new(Notify::new());
            { let mut requests = REQUESTS.lock().unwrap(); if requests.contains_key(&chat) { return Err("API уже обрабатывает запрос этого чата".into()); } requests.insert(chat.clone(), cancel.clone()); }
            let result = tokio::select! { result = request(c, secret, a["messages"].clone()) => result, _ = cancel.notified() => Err("Запрос остановлен. API мог уже начать обработку".into()) };
            REQUESTS.lock().unwrap().remove(&chat); result
        }
        "stop" => { if let Some(cancel) = REQUESTS.lock().unwrap().get(a["chat"].as_str().unwrap_or_default()) { cancel.notify_one(); } Ok(Value::Null) }
        _ => Err(format!("api.{method}: нет такого метода")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn connection(base: &str) -> Connection { Connection { id: uuid::Uuid::new_v4().to_string(), name: "Test".into(), base_url: base.into(), model: "test-model".into() } }
    #[test] fn endpoints_reject_credentials_and_remote_http() {
        for url in ["http://example.com/v1", "https://key@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/#secret", "file:///etc/passwd"] { assert!(connection(url).endpoint().is_err(), "{url}"); }
        assert_eq!(connection("http://127.0.0.1:1234/v1/").endpoint().unwrap().as_str(), "http://127.0.0.1:1234/v1/chat/completions");
        assert!(connection("http://[::1]:1234/v1").endpoint().is_ok());
    }
    #[test] fn responses_redact_keys_and_reject_tool_calls_or_truncation() {
        let v = json!({ "choices": [{ "message": { "content": "hello secret" } }], "usage": { "prompt_tokens": 12 } });
        assert_eq!(parse(v, "secret").unwrap()["text"], "hello [API key hidden]");
        assert!(parse(json!({ "choices": [{ "message": { "content": "partial" }, "finish_reason": "length" }] }), "secret").is_err());
        assert!(parse(json!({ "choices": [{ "message": { "content": "answer", "tool_calls": [{}] } }] }), "secret").is_err());
    }
    #[tokio::test] async fn successful_http_round_trip_preserves_messages_and_redacts_response() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap(); let mut data = Vec::new();
            loop {
                let mut chunk = [0; 4096]; let n = socket.read(&mut chunk).await.unwrap(); assert!(n > 0); data.extend_from_slice(&chunk[..n]);
                if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&data[..end]);
                    let size: usize = headers.lines().find_map(|l| l.to_lowercase().strip_prefix("content-length:").map(|s| s.trim().parse().unwrap())).unwrap();
                    if data.len() >= end + 4 + size {
                        let body: Value = serde_json::from_slice(&data[end+4..end+4+size]).unwrap();
                        assert_eq!(body["messages"][0]["content"], "hello"); assert_eq!(body["stream"], false); break;
                    }
                }
            }
            let body = json!({ "choices": [{ "message": { "content": "answer test-secret" } }], "usage": { "prompt_tokens": 7, "completion_tokens": 3 } }).to_string();
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        });
        let reply = request(connection(&format!("http://{address}/v1")), "test-secret".into(), json!([{ "role": "user", "content": "hello" }])).await.unwrap();
        assert_eq!(reply["text"], "answer [API key hidden]"); assert_eq!(reply["inputTokens"], 7); server.await.unwrap();
    }
    #[tokio::test] async fn redirects_do_not_resend_secrets() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap(); let mut data = vec![0; 8192];
            let n = socket.read(&mut data).await.unwrap(); let wire = String::from_utf8_lossy(&data[..n]);
            assert!(wire.contains("Bearer test-secret")); assert!(wire.starts_with("POST /v1/chat/completions"));
            socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
        });
        let error = request(connection(&format!("http://{address}/v1")), "test-secret".into(), json!([{ "role": "user", "content": "test" }])).await.unwrap_err();
        assert!(error.contains("перенаправляет")); assert!(!error.contains("test-secret")); server.await.unwrap();
    }
}
