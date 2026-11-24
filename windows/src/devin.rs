// Devin CLI как провайдер наравне с Codex и Claude: `devin acp` — Agent Client Protocol (JSON-RPC 2.0 построчно через stdio).
// Один процесс на чат. Уведомления (session/update) и запросы агента (session/request_permission) уходят в интерфейс событием "devin";
// модель чата, ход и разрешения живут в ui/chat.js — здесь только транспорт.
use crate::{codex, util};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::oneshot;

struct Client {
    child: Mutex<tokio::process::Child>,
    stdin: tokio::sync::Mutex<tokio::process::ChildStdin>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Value>>>,
    next: AtomicU64,
    tail: Arc<Mutex<Vec<u8>>>,
}
static GENERATIONS: LazyLock<util::ProcessGenerations> = LazyLock::new(Default::default);
static CLIENTS: LazyLock<Mutex<HashMap<String, Arc<Client>>>> = LazyLock::new(Default::default);
/// Кэш списка сессий для боковой панели: (момент, строки).
static LISTED: LazyLock<Mutex<Option<(std::time::Instant, Value)>>> = LazyLock::new(Default::default);


impl Client {
    async fn write(&self, v: Value) -> bool {
        let mut v = v; v["jsonrpc"] = json!("2.0");
        self.stdin.lock().await.write_all(format!("{v}\n").as_bytes()).await.is_ok()
    }
    /// Запрос к агенту. Ход (session/prompt) идёт сколько нужно, остальное — не дольше двух минут.
    async fn rpc(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        if !self.write(json!({ "id": id, "method": method, "params": params })).await {
            self.pending.lock().unwrap().remove(&id);
            return Err("Нет связи с Devin — процесс не запущен.".into());
        }
        let reply = if method == "session/prompt" { rx.await.map_err(|_| ()) } else {
            tokio::time::timeout(std::time::Duration::from_secs(120), rx).await.map_err(|_| { self.pending.lock().unwrap().remove(&id); }).and_then(|r| r.map_err(|_| ()))
        };
        let r = reply.map_err(|_| { let reason = codex::tail_text(&self.tail); format!("Devin не ответил на {method}{}", if reason.is_empty() { String::new() } else { format!(": {reason}") }) })?;
        match &r["error"] { Value::Null => Ok(r["result"].clone()), e => Err(e["message"].as_str().map(String::from).unwrap_or_else(|| e.to_string())) }
    }
}

fn spawn(app: Option<(AppHandle, String, Value)>, cwd: Option<&str>) -> Result<Arc<Client>, String> {
    let bin = util::find_bin("devin").ok_or("Не установлен Devin CLI: curl -fsSL https://cli.devin.ai/install.sh | bash")?;
    let mut cmd = util::command(bin);
    cmd.kill_on_drop(true).arg("acp").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(dir) = cwd.filter(|d| std::path::Path::new(d).is_dir()) { cmd.current_dir(dir); }
    let mut child = cmd.spawn().map_err(|e| format!("Не удалось запустить Devin: {e}"))?;
    let (stdin, stdout, stderr) = (child.stdin.take().ok_or("Нет stdin")?, child.stdout.take().ok_or("Нет stdout")?, child.stderr.take().ok_or("Нет stderr")?);
    let c = Arc::new(Client { child: Mutex::new(child), stdin: tokio::sync::Mutex::new(stdin), pending: Default::default(), next: AtomicU64::new(1), tail: Default::default() });
    codex::keep_tail(stderr, c.tail.clone());
    let reader = c.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(o) = serde_json::from_str::<Value>(&line) else { continue };
            if o["method"].is_string() {
                if let Some((app, chat, gen)) = &app { let _ = app.emit("devin", json!({ "chat": chat, "gen": gen, "method": o["method"], "params": o["params"], "id": o["id"] })); }
            } else if let Some(tx) = o["id"].as_u64().and_then(|id| reader.pending.lock().unwrap().remove(&id)) {
                let _ = tx.send(o);
            }
        }
        reader.pending.lock().unwrap().clear();
        if let Some((app, chat, gen)) = app {
            let mut all = CLIENTS.lock().unwrap();
            if all.get(&chat).is_some_and(|x| Arc::ptr_eq(x, &reader)) {
                all.remove(&chat);
                let _ = app.emit("devin", json!({ "chat": chat, "gen": gen, "exit": true, "reason": codex::tail_text(&reader.tail) }));
            }
        }
    });
    Ok(c)
}

async fn initialize(c: &Client) -> Result<Value, String> {
    c.rpc("initialize", json!({ "protocolVersion": 1, "clientCapabilities": {}, "clientInfo": { "name": "pult", "title": "Пульт", "version": env!("CARGO_PKG_VERSION") } })).await
}

fn stop(chat: &str) {
    if let Some(c) = CLIENTS.lock().unwrap().remove(chat) { let _ = c.child.lock().unwrap().start_kill(); }
}
fn client(chat: &str) -> Result<Arc<Client>, String> {
    CLIENTS.lock().unwrap().get(chat).cloned().ok_or_else(|| "Нет связи с Devin — процесс не запущен.".into())
}

/// Сессии Devin для боковой панели «Диалоги»: короткоживущий процесс, ответ кэшируется на 30 секунд.
async fn list() -> Result<Value, String> {
    if let Some((at, rows)) = LISTED.lock().unwrap().as_ref() { if at.elapsed().as_secs() < 30 { return Ok(rows.clone()); } }
    if util::find_bin("devin").is_none() { return Ok(json!([])); }
    let c = spawn(None, None)?;
    let result = async { initialize(&c).await?; c.rpc("session/list", json!({})).await }.await;
    let _ = c.child.lock().unwrap().start_kill();
    let rows: Vec<Value> = result?["sessions"].as_array().into_iter().flatten().filter(|s| s["_meta"]["cognition.ai/hasUserMessages"] != false).map(|s| {
        let date = s["updatedAt"].as_str().and_then(|d| chrono_like(d)).unwrap_or(0.0);
        json!({ "id": format!("devin:{}", s["sessionId"].as_str().unwrap_or_default()), "session": s["sessionId"], "title": s["title"].as_str().unwrap_or("Сессия Devin").chars().take(100).collect::<String>(), "cwd": s["cwd"], "date": date, "account": "Devin" })
    }).take(200).collect();
    let rows = json!(rows);
    *LISTED.lock().unwrap() = Some((std::time::Instant::now(), rows.clone()));
    Ok(rows)
}

/// «2026-11-22T15:37:53+00:00» → секунды Unix (без внешних зависимостей; смещение пояса учитывается).
fn chrono_like(s: &str) -> Option<f64> {
    let (date, rest) = s.split_once('T')?;
    let mut d = date.split('-').map(|x| x.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let (time, offset) = match rest.find(['+', '-', 'Z']) { Some(i) => (&rest[..i], &rest[i..]), None => (rest, "") };
    let mut t = time.split(':').map(|x| x.parse::<f64>().ok());
    let (hh, mm, ss) = (t.next()??, t.next()??, t.next().flatten().unwrap_or(0.0));
    let shift = if offset.len() >= 6 { let sign = if offset.starts_with('-') { -1.0 } else { 1.0 }; sign * (offset[1..3].parse::<f64>().ok()? * 3600.0 + offset[4..6].parse::<f64>().ok()? * 60.0) } else { 0.0 };
    // Дни от эпохи по алгоритму Говарда Хиннанта.
    let (y, m) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = y.div_euclid(400); let yoe = y - era * 400; let doy = (153 * m + 2) / 5 + day - 1; let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some((era * 146097 + doe - 719468) as f64 * 86400.0 + hh * 3600.0 + mm * 60.0 + ss - shift)
}

static PLAN: LazyLock<Mutex<Option<(std::time::Instant, String)>>> = LazyLock::new(Default::default);

/// Тариф из `devin auth status` (строка «Tier:»), кэш на час.
async fn plan() -> String {
    if let Some((at, plan)) = PLAN.lock().unwrap().as_ref() { if at.elapsed().as_secs() < 3600 { return plan.clone(); } }
    let Some(bin) = util::find_bin("devin") else { return String::new() };
    let out = tokio::time::timeout(std::time::Duration::from_secs(15), util::command(bin).args(["auth", "status"]).kill_on_drop(true).output()).await;
    let text = out.ok().and_then(Result::ok).map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
    let plan = text.lines().find_map(|l| l.trim().strip_prefix("Tier:")).map(|t| t.trim().to_string()).unwrap_or_default();
    *PLAN.lock().unwrap() = Some((std::time::Instant::now(), plan.clone()));
    plan
}

/// Расход Devin за сегодня (локальная полночь): сессии, кредиты и ACU из ~/.local/share/devin/cli/sessions.db, только чтение.
/// Процентов лимита Devin CLI не отдаёт — показываем фактический расход.
async fn usage() -> Result<Value, String> {
    let db = util::home().join(".local/share/devin/cli/sessions.db");
    let sqlite = util::find_bin("sqlite3").or_else(|| Some("/usr/bin/sqlite3".into()).filter(|p: &std::path::PathBuf| p.is_file()));
    let mut today = json!({ "sessions": 0, "credits": 0, "acu": 0 });
    if let (true, Some(sqlite)) = (db.is_file(), sqlite) {
        let query = "select count(*) sessions, coalesce(sum(json_extract(metadata,'$.total_credit_cost')),0) credits, coalesce(sum(json_extract(metadata,'$.total_acu_cost')),0) acu from sessions where hidden = 0 and last_activity_at >= cast(strftime('%s','now','localtime','start of day','utc') as integer)";
        let out = tokio::time::timeout(std::time::Duration::from_secs(10), util::command(sqlite).args(["-readonly", "-json"]).arg(format!("file:{}?mode=ro", db.display())).arg(query).kill_on_drop(true).output()).await;
        if let Some(row) = out.ok().and_then(Result::ok).filter(|o| o.status.success()).and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok()).and_then(|v| v.get(0).cloned()) { today = row; }
    }
    Ok(json!({ "plan": plan().await, "today": today }))
}

pub async fn call(app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    let chat = a["chat"].as_str().unwrap_or_default().to_string();
    let generation = || a["gen"].as_u64().ok_or("Нет поколения процесса");
    match method {
        "available" => Ok(json!(util::find_bin("devin").is_some())),
        "list" => list().await,
        "usage" => usage().await,
        "connect" => {
            let gen = generation()?;
            GENERATIONS.admit(&chat, gen, || stop(&chat))?;
            let c = spawn(Some((app.clone(), chat.clone(), a["gen"].clone())), a["cwd"].as_str())?;
            GENERATIONS.admit(&chat, gen, || { CLIENTS.lock().unwrap().insert(chat.clone(), c.clone()); })?;
            if let Err(e) = initialize(&c).await { stop(&chat); return Err(e); }
            Ok(Value::Null)
        }
        "rpc" => {
            let c = GENERATIONS.current(&chat, generation()?, || client(&chat))??;
            if a["method"] == "session/prompt" || a["method"] == "session/new" || a["method"] == "session/load" { *LISTED.lock().unwrap() = None; }
            c.rpc(a["method"].as_str().ok_or("Нет метода")?, a["params"].clone()).await
        }
        // Уведомление без ответа, например session/cancel.
        "notify" => {
            let c = GENERATIONS.current(&chat, generation()?, || client(&chat))??;
            if !c.write(json!({ "method": a["method"], "params": a["params"] })).await { return Err("Devin отключился".into()); }
            Ok(Value::Null)
        }
        "respond" => {
            let c = GENERATIONS.current(&chat, generation()?, || client(&chat))??;
            let mut reply = json!({ "id": a["id"] });
            if a["error"].is_null() { reply["result"] = a["result"].clone(); } else { reply["error"] = json!({ "code": -32000, "message": a["error"] }); }
            if !c.write(reply).await { return Err("Devin отключился до ответа".into()); }
            Ok(Value::Null)
        }
        "stop" => { GENERATIONS.cancel(&chat, a["gen"].as_u64(), || stop(&chat)); Ok(Value::Null) }
        _ => Err(format!("devin.{method}: нет такого метода")),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses_devin_timestamps_with_offsets() {
        assert_eq!(super::chrono_like("1970-01-01T00:00:00+00:00"), Some(0.0));
        assert_eq!(super::chrono_like("2026-11-22T15:37:53+00:00"), Some(1795361873.0));
        assert_eq!(super::chrono_like("2026-11-22T18:37:53+03:00"), Some(1795361873.0));
        assert_eq!(super::chrono_like("мусор"), None);
    }

    /// Настоящий Devin CLI: `cargo test -- --ignored real_devin`.
    #[tokio::test]
    #[ignore]
    async fn real_devin_lists_models_and_sessions() {
        let c = super::spawn(None, None).unwrap();
        super::initialize(&c).await.unwrap();
        let session = c.rpc("session/new", serde_json::json!({ "cwd": std::env::temp_dir(), "mcpServers": [] })).await.unwrap();
        let models = session["configOptions"].as_array().unwrap().iter().find(|o| o["id"] == "model").unwrap()["options"].as_array().unwrap().len();
        assert!(models > 3, "моделей: {models}");
        let _ = c.child.lock().unwrap().start_kill();
        assert!(super::list().await.unwrap().as_array().is_some());
    }
}
