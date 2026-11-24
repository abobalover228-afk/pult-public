use crate::{codex, util};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{Arc, LazyLock, Mutex};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Notify;

struct Session {
    generation: u64,
    input: tokio::sync::Mutex<tokio::process::ChildStdin>,
    stop: Notify,
}
static GENERATIONS: LazyLock<util::ProcessGenerations> = LazyLock::new(Default::default);
static SESSIONS: LazyLock<Mutex<HashMap<String, Arc<Session>>>> = LazyLock::new(Default::default);
pub fn init(_app: &AppHandle) {}
fn session(chat: &str) -> Result<Arc<Session>, String> {
    SESSIONS.lock().unwrap().get(chat).cloned().ok_or_else(|| "Claude не запущен".into())
}
async fn write(s: &Session, message: Value) -> Result<(), String> {
    s.input.lock().await.write_all(format!("{message}\n").as_bytes()).await.map_err(|e| e.to_string())
}
fn permission_mode(a: &Value) -> Result<&str, String> {
    match a["permissionMode"].as_str().unwrap_or("default") {
        "default" => Ok("default"), "plan" => Ok("plan"),
        // Автоподтверждение: правки без вопросов; полный доступ (danger-full-access + автоподтверждение) — без вопросов вообще.
        "acceptEdits" => Ok("acceptEdits"), "bypassPermissions" => Ok("bypassPermissions"),
        _ => Err("Неверный режим разрешений Claude".into()),
    }
}
async fn start(app: &AppHandle, a: &Value) -> Result<Value, String> {
    let chat = a["chat"].as_str().ok_or("Нет чата")?.to_string();
    let generation = a["gen"].as_u64().ok_or("Нет поколения процесса")?;
    let existing = GENERATIONS.admit(&chat, generation, || {
        let mut sessions=SESSIONS.lock().unwrap();
        if sessions.get(&chat).is_some_and(|s| s.generation==generation) { sessions.get(&chat).cloned() }
        else { if let Some(old)=sessions.remove(&chat) { old.stop.notify_one(); } None }
    })?;
    let s = if let Some(s) = existing { s } else {
        let bin = util::find_bin("claude").ok_or("Не установлен Claude Code CLI")?;
        let mut cmd = util::command(bin);
        cmd.kill_on_drop(true);
        cmd.args(["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", permission_mode(a)?])
            .current_dir(a["cwd"].as_str().ok_or("Не выбрана папка проекта")?)
            .env_remove("CLAUDECODE").env_remove("CLAUDE_CODE_ENTRYPOINT")
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        for (key, flag) in [("model", "--model"), ("session", "--resume"), ("rules", "--append-system-prompt"), ("effort", "--effort")] {
            if let Some(v) = a[key].as_str().filter(|s| !s.is_empty()) { cmd.args([flag, v]); }
        }
        for dir in a["extraDirs"].as_array().into_iter().flatten() {
            let dir = dir.as_str().ok_or("Неверная дополнительная папка")?;
            if !std::path::Path::new(dir).is_dir() { return Err("Дополнительная папка Claude не найдена".into()); }
            cmd.args(["--add-dir", dir]);
        }
        cmd.args(["--settings", &json!({"fastMode": a["fast"] == true}).to_string()]);
        if a["forkSession"] == true {
            if a["session"].as_str().is_none_or(str::is_empty) { return Err("Нет исходной сессии Claude".into()); }
            cmd.arg("--fork-session");
        }
        let mut child = cmd.spawn().map_err(|e| format!("Не удалось запустить Claude: {e}"))?;
        let input = child.stdin.take().ok_or("Нет stdin")?;
        let stdout = child.stdout.take().ok_or("Нет stdout")?;
        let stderr = child.stderr.take().ok_or("Нет stderr")?;
        let tail = Arc::new(Mutex::new(Vec::new()));
        codex::keep_tail(stderr, tail.clone());
        let s = Arc::new(Session { generation, input: tokio::sync::Mutex::new(input), stop: Notify::new() });
        GENERATIONS.admit(&chat, generation, || { if let Some(old)=SESSIONS.lock().unwrap().insert(chat.clone(),s.clone()) { old.stop.notify_one(); } })?;
        let (app, chat, worker, gen) = (app.clone(), chat.clone(), s.clone(), a["gen"].clone());
        tokio::spawn(async move {
            let (events_app, events_chat, events_gen) = (app.clone(), chat.clone(), gen.clone());
            let reader = tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if let Ok(event) = serde_json::from_str::<Value>(&line) {
                        let _ = events_app.emit("claude", json!({ "chat": events_chat, "gen": events_gen, "event": event }));
                    }
                }
            });
            let mut interrupted = false;
            let result = tokio::select! {
                result = child.wait() => result,
                _ = worker.stop.notified() => { interrupted = true; let _ = child.start_kill(); child.wait().await }
            };
            let _ = reader.await;
            let mut sessions = SESSIONS.lock().unwrap();
            if sessions.get(&chat).is_some_and(|current| Arc::ptr_eq(current, &worker)) {
                sessions.remove(&chat);
                let error = result.map(|s| !s.success()).unwrap_or(true);
                let _ = app.emit("claude", json!({ "chat": chat, "gen": gen, "exit": true, "interrupted": interrupted, "error": error, "reason": codex::tail_text(&tail) }));
            }
        });
        s
    };
    write(&s, json!({ "type": "user", "message": { "role": "user", "content": a["text"] } })).await?;
    Ok(Value::Null)
}
pub async fn call(app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    match method {
        "send" => start(app, &a).await,
        "localFiles" => {
            let folder = a["folder"].as_str().filter(|s| ["skills", "agents", "commands"].contains(s)).ok_or("Неизвестный раздел Claude")?;
            let cwd = a["cwd"].as_str().ok_or("Нет проекта")?;
            let mut entries = vec![];
            for base in [util::home(), std::path::PathBuf::from(cwd)] {
                for entry in std::fs::read_dir(base.join(".claude").join(folder)).into_iter().flatten().flatten().take(500) {
                    if !entry.file_name().to_string_lossy().starts_with('.') { entries.push(entry.path()); }
                }
            }
            entries.sort(); Ok(json!(entries))
        }
        "readHistory" => read_history(a["session"].as_str().unwrap_or_default(), a["path"].as_str().unwrap_or_default()),
        "respond" => {
            let chat=a["chat"].as_str().unwrap_or_default();
            let s=GENERATIONS.current(chat, a["gen"].as_u64().ok_or("Нет поколения процесса")?, || session(chat))??;
            write(&s, json!({ "type": "control_response", "response": { "subtype": "success", "request_id": a["id"], "response": a["response"] } })).await?;
            Ok(Value::Null)
        }
        "stop" => {
            let chat=a["chat"].as_str().unwrap_or_default();
            GENERATIONS.cancel(chat, a["gen"].as_u64(), || { if let Some(s)=SESSIONS.lock().unwrap().remove(chat) { s.stop.notify_one(); } });
            Ok(Value::Null)
        }
        _ => Err(format!("claude.{method}: нет такого метода")),
    }
}


pub fn history() -> Vec<Value> {
    use std::io::{BufRead, BufReader, Read};
    let root = util::home().join(".claude/projects");
    let mut rows = vec![];
    for dir in std::fs::read_dir(root).into_iter().flatten().flatten() {
        for entry in std::fs::read_dir(dir.path()).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|e| e != "jsonl") { continue; }
            let session = path.file_stem().unwrap_or_default().to_string_lossy().to_string();
            if uuid::Uuid::parse_str(&session).is_err() { continue; }
            let Ok(file) = std::fs::File::open(&path) else { continue };
            let (mut cwd, mut title) = (String::new(), String::new());
            for line in BufReader::new(file.take(2_000_000)).lines().take(60).map_while(Result::ok) {
                if line.len() > 1_000_000 { continue; }
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                if let Some(value) = v["cwd"].as_str() { cwd = value.into(); }
                if title.is_empty() && v["type"] == "user" {
                    title = v["message"]["content"].as_str().map(String::from).unwrap_or_else(|| v["message"]["content"].as_array().into_iter().flatten().filter_map(|b| b["text"].as_str()).collect::<Vec<_>>().join(" "));
                }
                if !cwd.is_empty() && !title.is_empty() { break; }
            }
            if cwd.is_empty() || title.is_empty() { continue; }
            let date = entry.metadata().ok().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs_f64()).unwrap_or(0.0);
            rows.push(json!({"id":format!("claude:{session}"),"session":session,"title":title.chars().take(100).collect::<String>(),"cwd":cwd,"date":date,"account":"Claude Code","path":path}));
        }
    }
    rows.sort_by(|a,b| b["date"].as_f64().unwrap_or(0.0).total_cmp(&a["date"].as_f64().unwrap_or(0.0)));
    rows.truncate(200); rows
}


fn transcript(reader: impl std::io::BufRead) -> Vec<Value> {
    let mut messages = Vec::new();
    for line in reader.lines().map_while(Result::ok) {
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v["isSidechain"] == true || v["isMeta"] == true { continue; }
        let kind = match v["type"].as_str() { Some("user") => "user", Some("assistant") => "agent", _ => continue };
        let content = &v["message"]["content"];
        let text = content.as_str().map(String::from).unwrap_or_else(|| content.as_array().into_iter().flatten()
            .filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect::<Vec<_>>().join("\n"));
        if text.trim().is_empty() { continue; }
        let id = v["uuid"].as_str().map(String::from).unwrap_or_else(|| format!("imported-{}", messages.len()));
        let message = json!({"id":id,"kind":kind,"text":text,"done":true});
        if let Some(existing) = messages.iter_mut().find(|m: &&mut Value| m["id"] == id) { *existing = message; }
        else { messages.push(message); }
    }
    messages
}

fn read_history(session: &str, path: &str) -> Result<Value, String> {
    use std::io::Read;
    uuid::Uuid::parse_str(session).map_err(|_| "Неверная сессия Claude")?;
    let root = util::home().join(".claude/projects").canonicalize().map_err(|e| e.to_string())?;
    let path = std::path::Path::new(path).canonicalize().map_err(|e| e.to_string())?;
    if !path.starts_with(root) || path.file_stem().and_then(|s| s.to_str()) != Some(session) || path.extension().is_none_or(|s| s != "jsonl") {
        return Err("Файл не принадлежит истории Claude".into());
    }
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() > 32_000_000 { return Err("История Claude больше 32 МБ".into()); }
    Ok(json!(transcript(std::io::BufReader::new(file.take(32_000_000)))))
}

#[cfg(test)]
mod history_tests {
    #[test]
    fn transcript_keeps_text_and_skips_internal_tool_and_sidechain_records() {
        let input = concat!(
            "{\"type\":\"user\",\"uuid\":\"u\",\"message\":{\"content\":\"Вопрос\"}}\n",
            "{\"type\":\"assistant\",\"uuid\":\"a\",\"message\":{\"content\":[{\"type\":\"thinking\",\"text\":\"private\"},{\"type\":\"text\",\"text\":\"Ответ\"}]}}\n",
            "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"internal\"}]}}\n",
            "{\"type\":\"user\",\"isSidechain\":true,\"message\":{\"content\":\"agent task\"}}\n");
        let rows = super::transcript(std::io::Cursor::new(input));
        assert_eq!(rows.len(), 2); assert_eq!(rows[0]["text"], "Вопрос"); assert_eq!(rows[1]["text"], "Ответ");
    }
}
