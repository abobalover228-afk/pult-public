use crate::util;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, path::{Path, PathBuf}, sync::{LazyLock, Mutex}, time::{Duration, Instant}};
use tauri::{AppHandle, Emitter};
use std::sync::Arc;
use tokio::io::AsyncReadExt;

static SCHEMA: LazyLock<jsonschema::Validator> = LazyLock::new(|| jsonschema::validator_for(&serde_json::from_str(include_str!("../../SDK/pult-mod.schema.json")).expect("mod schema")).expect("mod validator"));
static STORE: Mutex<()> = Mutex::new(());
struct Budget { start: Instant, calls: u32, turns: u32 }
static BUDGETS: LazyLock<Mutex<HashMap<String, Budget>>> = LazyLock::new(Default::default);
struct ModProcess { child: tokio::process::Child, log: Arc<Mutex<Vec<u8>>>, fingerprint: String, reported: bool }
static PROCESSES: LazyLock<Mutex<HashMap<String, ModProcess>>> = LazyLock::new(Default::default);
pub fn init(app: &AppHandle) {
    let app=app.clone();
    tauri::async_runtime::spawn(async move { loop {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let mut processes=PROCESSES.lock().unwrap();
        for (key,p) in processes.iter_mut() {
            let (owner,name)=key.split_once('/').unwrap();
            if active(owner,&p.fingerprint).is_err() { terminate(&mut p.child); }
            if !p.reported { if let Ok(Some(status))=p.child.try_wait() { p.reported=true; let _=app.emit("mods",json!({"id":owner,"fingerprint":p.fingerprint,"event":"process.exited","detail":{"id":name,"code":status.code().unwrap_or(-1)}})); } }
        }
    }});
}
pub fn stop_all() { for p in PROCESSES.lock().unwrap().values_mut() { terminate(&mut p.child); } }
fn terminate(child:&mut tokio::process::Child) {
    if child.try_wait().ok().flatten().is_some(){return;}
    #[cfg(windows)] if let Some(pid)=child.id(){use std::os::windows::process::CommandExt;let _=std::process::Command::new("taskkill").args(["/T","/F","/PID",&pid.to_string()]).creation_flags(0x08000000).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();}
    let _=child.start_kill();
}
fn stop_owner(owner:&str) { for (key,p) in PROCESSES.lock().unwrap().iter_mut().filter(|(k,_)|k.starts_with(&format!("{owner}/"))) { let _=key; terminate(&mut p.child); } }
fn read_manifest(path:impl AsRef<Path>)->Result<Value,String> { use std::io::Read; let mut bytes=vec![]; std::fs::File::open(path).map_err(|_|"Не удалось прочитать .pult")?.take(2_000_001).read_to_end(&mut bytes).map_err(|_|"Ошибка чтения .pult")?; decode(&bytes) }

fn text<'a>(v: &'a Value, key: &str) -> &'a str { v[key].as_str().unwrap_or_default() }
fn id(s: &str) -> bool { !s.is_empty() && s.len() <= 48 && s.as_bytes()[0].is_ascii_lowercase() && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') }
fn fingerprint(v: &Value) -> String {
    fn sorted(v:&Value)->Value {match v {Value::Object(o)=>{let mut keys:Vec<_>=o.keys().collect();keys.sort();Value::Object(keys.into_iter().map(|k|(k.clone(),sorted(&o[k]))).collect())},Value::Array(a)=>Value::Array(a.iter().map(sorted).collect()),_=>v.clone()}}
    format!("{:x}", Sha256::digest(sorted(v).to_string().as_bytes()))
}
fn panels(v: &Value) -> Vec<Value> {
    let mut rows = v["panels"].as_array().cloned().unwrap_or_default();
    if v["panel"].is_object() { rows.push(json!({ "id": "main", "title": v["panel"]["title"], "html": v["panel"]["html"], "placement": "sheet" })); }
    rows
}
fn blocked(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.starts_with(".env") || [".git", ".ssh", ".aws", "auth.json", "credentials", "id_rsa", "id_ed25519"].contains(&name.as_str()) || ["con", "prn", "aux", "nul", "clock$"].contains(&name.split('.').next().unwrap_or_default()) ||
    ["pem", "key", "p12"].contains(&name.rsplit('.').next().unwrap_or_default()) ||
    (name.len() >= 4 && (name.as_bytes().starts_with(b"com") || name.as_bytes().starts_with(b"lpt")) && matches!(name.as_bytes()[3], b'1'..=b'9') && (name.len() == 4 || name.as_bytes()[4] == b'.'))
}
fn parts(path: &str) -> Result<Vec<&str>, String> {
    if path.len() > 999 || path.starts_with('/') || path.contains(['\\', ':', '\0', '<', '>', '"', '|', '?', '*']) || path.chars().any(char::is_control) { return Err("Нужен относительный путь проекта".into()); }
    let rows: Vec<_> = path.split('/').filter(|p| !p.is_empty() && *p != ".").collect();
    if rows.iter().any(|p| *p == ".." || p.ends_with([' ', '.']) || blocked(p)) { return Err("Секреты, служебные файлы и выход из проекта запрещены".into()); }
    Ok(rows)
}
fn scoped(root: &Path, path: &str) -> Result<PathBuf, String> {
    let base = root.canonicalize().map_err(|_| "Папка проекта не найдена")?;
    let mut target = base.clone();
    for part in parts(path)? {
        target.push(part);
        if std::fs::symlink_metadata(&target).is_ok() { target = target.canonicalize().map_err(|_| "Недоступная ссылка")?; }
        let relative = target.strip_prefix(&base).map_err(|_| "Ссылка выходит из проекта")?;
        if relative.components().any(|c| blocked(&c.as_os_str().to_string_lossy())) { return Err("Ссылка ведёт к служебному файлу".into()); }
    }
    Ok(target)
}
fn decode(bytes: &[u8]) -> Result<Value, String> {
    if bytes.len() > 2_000_000 { return Err("Мод больше 2 МБ".into()); }
    let v: Value = serde_json::from_slice(bytes).map_err(|_| "Неверный JSON .pult")?;
    if !SCHEMA.is_valid(&v) { return Err("Manifest не соответствует SDK .pult 1/2".into()); }
    let commands = v["commands"].as_array().ok_or("Нет команд")?; let panel_rows = panels(&v);
    for (rows, key) in [(commands.as_slice(), "name"), (panel_rows.as_slice(), "id")] {
        let mut ids = std::collections::HashSet::new();
        if rows.iter().any(|r| !ids.insert(text(r, key))) { return Err("Повторяющийся ID команды или панели".into()); }
    }
    if panel_rows.len() > 12 { return Err("Не более 12 панелей".into()); }
    if v["settings"].as_object().into_iter().flatten().any(|(k,_)| k.is_empty() || k.len()>100) { return Err("Неверный ключ настройки".into()); }
    let perms = v["permissions"].as_array().ok_or("Нет списка прав")?;
    if commands.iter().any(|c| c["shell"].is_string() && !perms.contains(&json!("shell"))) || (v["background"].is_string() && !perms.contains(&json!("background"))) { return Err("Не объявлены права shell/background".into()); }
    for c in commands {
        if let Some(shortcut) = c["shortcut"].as_str() {
            let keys: Vec<_> = shortcut.split('+').collect(); let key = keys.last().unwrap_or(&"");
            let mods = &keys[..keys.len().saturating_sub(1)];
            if !(2..=5).contains(&keys.len()) || key.len() != 1 || !key.as_bytes()[0].is_ascii_alphanumeric() || mods.iter().any(|m| !["cmd", "ctrl", "alt", "shift"].contains(m)) || !mods.iter().any(|m| *m != "shift") || mods.iter().collect::<std::collections::HashSet<_>>().len() != mods.len() { return Err("Некорректный хоткей".into()); }
        }
    }
    for field in ["sidebar", "toolbar", "statusbar"] {
        let mut ids = std::collections::HashSet::new();
        for a in v[field].as_array().into_iter().flatten() {
            if !ids.insert(text(a, "id")) || (a["command"].is_string() && !commands.iter().any(|c| c["name"] == a["command"])) || (a["panel"].is_string() && !panel_rows.iter().any(|p| p["id"] == a["panel"])) { return Err("Кнопка ссылается на несуществующую команду/панель".into()); }
        }
    }
    for (path, value) in v["files"].as_object().into_iter().flatten() { if parts(path)?.is_empty() || path.len() > 200 || path.split('/').any(|p|p.is_empty()||p==".") || !value.is_string() { return Err("Неверный ресурс мода".into()); } }
    Ok(v)
}
fn directory() -> PathBuf { util::data_dir().join("mods") }
fn data(id: &str) -> PathBuf { util::data_dir().join("mod-data").join(id) }
fn state() -> Value { let v = util::setting("mods"); if v.is_object() { v } else { json!({}) } }
fn active(id_value: &str, hash: &str) -> Result<Value, String> {
    if !id(id_value) { return Err("Неверный ID мода".into()); }
    let v = read_manifest(directory().join(format!("{id_value}.pult")))?;
    if text(&v, "id") != id_value || fingerprint(&v) != hash || state()[id_value]["fingerprint"] != hash || state()[id_value]["enabled"] != true { return Err("Мод выключен или его файл изменился; требуется одобрение версии".into()); }
    Ok(v)
}
fn list() -> Value {
    let s = state(); let mut rows = vec![];
    for e in std::fs::read_dir(directory()).into_iter().flatten().flatten() {
        if e.path().extension().is_none_or(|e| e != "pult") { continue; }
        let name = e.path().file_stem().unwrap_or_default().to_string_lossy().to_string();
        match read_manifest(e.path()) {
            Ok(v) => { let hash = fingerprint(&v); let approved = s[&name]["fingerprint"] == hash && text(&v, "id") == name;
                rows.push(json!({ "manifest": v, "fingerprint": hash, "approved": approved, "enabled": approved && s[&name]["enabled"] == true })); }
            Err(error) => rows.push(json!({ "id": name, "error": error })),
        }
    }
    json!(rows)
}
fn permission(method: &str) -> Option<&str> {
    match method {
        "chats.list" | "chats.read" => Some("chats.read"),
        "chats.create" | "chats.send" | "chats.stop" | "chats.activate" | "chats.append" => Some("chats.write"),
        "files.list" | "files.read" | "git.status" | "git.diff" => Some("files.read"), "files.write" => Some("files.write"),
        "team.state" => Some("team.read"), "team.send" | "team.addTask" | "team.claim" => Some("team.write"),
        "network.fetch" => Some("network"), "process.start" | "process.read" | "process.stop" => Some("process"), "secrets.get" | "secrets.set" => Some("secrets"),
        _ => None,
    }
}
fn authorize(v: &Value, method: &str) -> Result<u32, String> { authorize_cost(v,method,u32::from(method=="chats.send")) }
fn authorize_cost(v: &Value, method: &str, cost:u32) -> Result<u32, String> {
    if let Some(p) = permission(method) { if !v["permissions"].as_array().is_some_and(|perms| perms.contains(&json!(p))) { return Err(format!("Нет права {p}")); } }
    let mut budgets = BUDGETS.lock().unwrap(); let b = budgets.entry(text(v,"id").into()).or_insert(Budget { start: Instant::now(), calls: 0, turns: 20 });
    if b.start.elapsed() >= Duration::from_secs(1) { b.start = Instant::now(); b.calls = 0; }
    if b.calls >= 80 { return Err("Не более 80 вызовов SDK в секунду".into()); } b.calls += 1;
    if b.turns<cost{return Err("Автоходы мода исчерпаны; ещё 20 выдаёт пользователь в настройках".into());}b.turns-=cost;
    Ok(b.turns)
}
fn key(p: &Value) -> Result<&str, String> { let k = text(p,"key"); if k.is_empty() || k.len() >= 100 { Err("Неверный ключ хранилища".into()) } else { Ok(k) } }
async fn sdk(a: &Value) -> Result<Value, String> {
    let v = active(text(a,"id"), text(a,"fingerprint"))?; let owner = text(&v,"id"); let method = text(a,"method"); let p = &a["params"];
    let turns = if method=="team.claim"{let ids=p["ids"].as_array().filter(|ids|!ids.is_empty()&&ids.len()<=3).ok_or("Можно взять от одной до трёх задач")?;if ids.iter().any(|id|id.as_str().is_none_or(|s|uuid::Uuid::parse_str(s).is_err()))||ids.iter().map(Value::to_string).collect::<std::collections::HashSet<_>>().len()!=ids.len(){return Err("Некорректные ID задач".into());}authorize_cost(&v,method,ids.len() as u32)?}else{authorize(&v,method)?}; let root = PathBuf::from(text(a,"root"));
    match method {
        "app.info" => Ok(json!({ "apiVersion": 2, "version": env!("CARGO_PKG_VERSION"), "modID": owner, "dataPath": data(owner), "assetsPath": data(owner).join("assets").join(fingerprint(&v)), "project": root, "remainingTurns": turns })),
        "settings.get" => { let mut settings = v["settings"].clone(); if !settings.is_object() { settings = json!({}); } for (k,val) in state()[owner]["settings"].as_object().into_iter().flatten() { if !settings[k].is_null() { settings[k] = val.clone(); } } Ok(settings) }
        "settings.set" => { let _g = STORE.lock().unwrap(); let k = key(p)?; if !v["settings"][k].is_string() || !p["value"].is_string() || text(p,"value").len() > 10000 { return Err("Неизвестная настройка мода".into()); } let mut s=state(); if !s[owner]["settings"].is_object() { s[owner]["settings"]=json!({}); } s[owner]["settings"][k]=p["value"].clone(); util::set_setting("mods",s); Ok(json!({"ok":true})) }
        "storage.get" | "storage.set" | "secrets.get" | "secrets.set" => {
            let _g=STORE.lock().unwrap(); let k=key(p)?; let secret=method.starts_with("secrets.");
            if secret && (k.len()>80 || !k.as_bytes()[0].is_ascii_alphabetic() || !k.bytes().all(|b| b.is_ascii_alphanumeric() || b==b'_' || b==b'-')) { return Err("Некорректное имя секрета".into()); }
            #[cfg(target_os = "macos")]
            let devin_keychain = if secret && owner == "devin" && k == "DEVIN_API_KEY" {
                Some(keyring::Entry::new("Пульт API", "devin").map_err(|_| "Связка ключей недоступна")?)
            } else { None };
            #[cfg(target_os = "macos")]
            if let Some(entry) = &devin_keychain {
                if method.ends_with(".get") {
                    match entry.get_password() {
                        Ok(value) => return Ok(json!(value)),
                        Err(keyring::Error::NoEntry) => {},
                        Err(_) => return Err("Не удалось прочитать ключ Devin из Связки ключей".into()),
                    }
                }
            }
            let file=data(owner).join(if secret { ".env" } else { "storage.json" });
            let mut values: Value = match std::fs::read(&file) {
                Ok(bytes) if secret => { let mut out=json!({}); for line in String::from_utf8_lossy(&bytes).lines() { if let Some((k,v))=line.split_once('=') { out[k]=serde_json::from_str(v).map_err(|_| "Повреждён .env мода")?; } } out }
                Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| "Повреждено хранилище мода")?,
                Err(e) if e.kind()==std::io::ErrorKind::NotFound => json!({}), Err(_)=>return Err("Нет доступа к хранилищу".into()),
            };
            if !values.is_object() {return Err("Некорректное хранилище мода".into());}
            if method.ends_with(".get") { return Ok(values[k].clone()); }
            if secret && (!p["value"].is_string() || text(p,"value").len()>32000) { return Err("Секрет должен быть строкой до 32 КБ".into()); }
            #[cfg(target_os = "macos")]
            if let Some(entry) = &devin_keychain {
                entry.set_password(text(p,"value")).map_err(|_| "Не удалось сохранить ключ Devin в Связку ключей")?;
                if values.as_object_mut().and_then(|v| v.remove(k)).is_none() {
                    return Ok(json!({"ok":true}));
                }
            }
            #[cfg(target_os = "macos")]
            let use_file = devin_keychain.is_none();
            #[cfg(not(target_os = "macos"))]
            let use_file = true;
            if use_file {
                if p["value"].is_null() { values.as_object_mut().ok_or("Некорректное хранилище")?.remove(k); } else { values[k]=p["value"].clone(); }
            }
            let bytes=if secret { values.as_object().ok_or("Некорректное хранилище")?.iter().map(|(k,v)| format!("{k}={v}\n")).collect::<String>().into_bytes() } else { values.to_string().into_bytes() };
            if bytes.len()>400000 { return Err("Хранилище ограничено 400 КБ".into()); } util::atomic_write(&file,&bytes)?; Ok(json!({"ok":true}))
        }
        "files.list" | "files.read" | "files.write" => {
            let path=scoped(&root,text(p,"path"))?;
            if method=="files.list" { let mut names=vec![]; for e in std::fs::read_dir(&path).map_err(|_| "Каталог недоступен")?.flatten() { let n=e.file_name().to_string_lossy().to_string(); let relative=path.join(&n).strip_prefix(root.canonicalize().map_err(|_| "Нет проекта")?).map_err(|_| "Нет доступа")?.to_string_lossy().replace('\\',"/"); if scoped(&root,&relative).is_ok() { names.push(n); } if names.len()==500 { break; } } names.sort(); return Ok(json!(names)); }
            if method=="files.write" { let value=p["text"].as_str().ok_or("Нет текста")?; if value.len()>1048576 { return Err("Файл больше 1 МБ".into()); } util::atomic_write(&path,value.as_bytes())?; return Ok(json!({"ok":true})); }
            use std::io::Read; let mut bytes=vec![]; std::fs::File::open(path).map_err(|_| "Файл недоступен")?.take(1048577).read_to_end(&mut bytes).map_err(|_| "Ошибка чтения")?;
            if bytes.len()>1048576 { return Err("Файл больше 1 МБ".into()); } Ok(json!(String::from_utf8(bytes).map_err(|_| "Файл не UTF-8")?))
        }
        "git.status" | "git.diff" => { let mut cmd=util::git(); cmd.current_dir(&root).args(if method=="git.status" { vec!["status","--short"] } else { vec!["diff","--stat"] }).kill_on_drop(true); let out=tokio::time::timeout(Duration::from_secs(15),cmd.output()).await.map_err(|_| "Git не ответил")?.map_err(|_| "Git недоступен")?; if !out.status.success() { return Err("Ошибка Git в папке проекта".into()); } Ok(json!(String::from_utf8_lossy(&out.stdout).chars().take(100000).collect::<String>())) }
        "network.fetch" => network(&v,p).await,
        "process.start" | "process.read" | "process.stop" => process(&v,p,method,&root),
        "chats.create" => {
            if let Some(cwd)=p["cwd"].as_str() { let base=root.canonicalize().map_err(|_|"Нет проекта")?;let cwd=Path::new(cwd).canonicalize().map_err(|_|"Нет папки чата")?;if !cwd.starts_with(&base)||!cwd.is_dir(){return Err("Папка чата должна находиться в текущем проекте".into());} }
            Ok(json!({"remainingTurns":turns}))
        }
        "team.state" | "team.send" | "team.addTask" | "team.claim" => Ok(json!({"remainingTurns":turns})),
        "ui.toast" | "ui.openPanel" | "ui.openTeam" | "ui.teamSettings" | "ui.openChat" | "ui.modSettings" | "log" | "chats.list" | "chats.read" | "chats.send" | "chats.stop" | "chats.activate" | "chats.append" => Ok(json!({"remainingTurns":turns})),
        _ => Err(format!("Метод SDK пока не перенесён: {method}")),
    }
}
pub async fn call(_app: &AppHandle, method: &str, a: Value) -> Result<Value, String> {
    match method {
        "list" => Ok(list()),
        "inspect" => { let v=read_manifest(text(&a,"path"))?; Ok(json!({ "fingerprint":fingerprint(&v), "manifest":v })) }
        "install" => { let _g=STORE.lock().unwrap(); let v=read_manifest(text(&a,"path"))?; let hash=fingerprint(&v); if a["approved"]!=true || a["fingerprint"]!=hash { return Err("Требуется одобрение именно этой версии мода".into()); } let owner=text(&v,"id"); let assets=data(owner).join("assets").join(&hash);std::fs::create_dir_all(&assets).map_err(|_|"Не удалось создать каталог ресурсов")?;for(path,value)in v["files"].as_object().into_iter().flatten(){util::atomic_write(&scoped(&assets,path)?,value.as_str().unwrap().as_bytes())?;}stop_owner(owner);util::atomic_write(&directory().join(format!("{owner}.pult")),v.to_string().as_bytes())?;let mut s=state();s[owner]=json!({"fingerprint":hash,"enabled":true,"settings":s[owner]["settings"]});util::set_setting("mods",s);Ok(list()) }
        "toggle" => { let _g=STORE.lock().unwrap(); let owner=text(&a,"id"); if !id(owner) { return Err("Неверный ID".into()); } let mut s=state(); if a["enabled"]==true { let v=read_manifest(directory().join(format!("{owner}.pult")))?; if s[owner]["fingerprint"]!=fingerprint(&v) { return Err("Мод изменён; переустанови и одобри версию".into()); } } if !s[owner].is_object() { return Err("Неизвестный мод".into()); } if a["enabled"]!=true { stop_owner(owner); } s[owner]["enabled"]=json!(a["enabled"]==true); util::set_setting("mods",s); Ok(list()) }
        "resetTurns" => { let owner=text(&a,"id"); if !id(owner) {return Err("Неверный ID".into());} BUDGETS.lock().unwrap().remove(owner); Ok(json!({"ok":true})) }
        "command" => { let v=active(text(&a,"id"),text(&a,"fingerprint"))?; let c=v["commands"].as_array().unwrap().iter().find(|c|c["name"]==a["name"]).ok_or("Команда не найдена")?; let turns=authorize(&v,"log")?;Ok(json!({"command":c,"remainingTurns":turns})) }
        "remove" => {let _g=STORE.lock().unwrap();let owner=text(&a,"id");if !id(owner){return Err("Неверный ID".into());}stop_owner(owner);std::fs::remove_file(directory().join(format!("{owner}.pult"))).map_err(|_|"Не удалось удалить мод")?;let mut s=state();s.as_object_mut().unwrap().remove(owner);util::set_setting("mods",s);Ok(list())}
        "sdk" => sdk(&a).await,
        _ => Err(format!("mods.{method}: нет такого метода")),
    }
}

#[cfg(test)]mod tests{
    use super::*;
    #[test]fn original_examples_pass_the_shared_sdk_schema(){for bytes in [include_bytes!("../../Examples/starter.pult").as_slice(),include_bytes!("../../Examples/sdk-playground.pult").as_slice(),include_bytes!("../../Examples/native-team.pult").as_slice()]{decode(bytes).unwrap();}}
    #[test]fn manifests_reject_privilege_and_path_tricks(){let base=decode(include_bytes!("../../Examples/starter.pult")).unwrap();let mut v=base.clone();v["commands"][0]["prompt"]=Value::Null;v["commands"][0]["shell"]=json!("echo hi");assert!(decode(v.to_string().as_bytes()).is_err());let mut v=base;v["format"]=json!(2);v["files"]=json!({"../escape":"x"});assert!(decode(v.to_string().as_bytes()).is_err());}
    #[test]fn windows_paths_and_secrets_are_blocked_on_every_host(){for path in ["../x","C:/secret","file:stream",".ENV/token",".GiT/config","CON.txt","nul","COM1.txt","foo.key","trailing. "]{assert!(parts(path).is_err(),"{path}");}assert!(parts("src/привет.rs").is_ok());}
    #[test]fn missing_sdk_permissions_are_rejected(){let v=json!({"id":"no-rights","permissions":[]});assert!(authorize(&v,"files.read").is_err());assert!(authorize(&v,"secrets.get").is_err());}
    #[test]fn network_domain_rules_reject_credentials_and_redirect_targets(){
        let v=json!({"networkDomains":["*.example.com","localhost"]});
        for url in ["https://a.example.com/api","http://localhost:1234/test"]{assert!(network_allowed(&v,&reqwest::Url::parse(url).unwrap()));}
        for url in ["https://example.com/","https://a.example.com.evil.test/","https://secret@a.example.com/","http://a.example.com/","https://unlisted.test/"]{assert!(!network_allowed(&v,&reqwest::Url::parse(url).unwrap()),"{url}");}
    }
    #[test]fn model_turn_budgets_charge_per_claim_and_cannot_reset_through_sdk(){
        let v=json!({"id":"budget-test","permissions":["chats.write","team.write"]});
        BUDGETS.lock().unwrap().remove("budget-test");
        assert_eq!(authorize_cost(&v,"team.claim",3).unwrap(),17);
        for _ in 0..17{authorize(&v,"chats.send").unwrap();}
        assert!(authorize(&v,"chats.send").is_err());
        BUDGETS.lock().unwrap().remove("budget-test");
    }
    #[tokio::test]async fn own_processes_have_bounded_readable_output(){
        let v=json!({"id":"process-test","permissions":["process"]});
        let p=json!({"id":"listing","executable":std::env::current_exe().unwrap(),"arguments":["--list"]});
        assert_eq!(process(&v,&p,"process.start",&std::env::temp_dir()).unwrap()["running"],true);
        let mut result=Value::Null;
        for _ in 0..50{tokio::time::sleep(Duration::from_millis(10)).await;result=process(&v,&p,"process.read",&std::env::temp_dir()).unwrap();if result["running"]==false&&!text(&result,"text").is_empty(){break;}}
        assert_eq!(result["running"],false);assert!(text(&result,"text").contains("mods::tests"));assert!(text(&result,"text").len()<=100000);
        PROCESSES.lock().unwrap().remove("process-test/listing");
    }
    #[cfg(unix)]#[test]fn symlinks_cannot_escape_or_alias_secrets(){let root=std::env::temp_dir().join(format!("pult-mod-test-{}",uuid::Uuid::new_v4()));std::fs::create_dir_all(&root).unwrap();std::fs::write(root.join(".env"),"secret").unwrap();std::os::unix::fs::symlink(root.join(".env"),root.join("alias")).unwrap();std::os::unix::fs::symlink(root.parent().unwrap(),root.join("outside")).unwrap();assert!(scoped(&root,"alias").is_err());assert!(scoped(&root,"outside/file").is_err());assert!(scoped(&root,"new/file.txt").unwrap().starts_with(root.canonicalize().unwrap()));std::fs::remove_dir_all(root).unwrap();}
}

fn network_allowed(v:&Value,url:&reqwest::Url)->bool {
    let Some(host)=url.host_str() else{return false};
    if !(url.scheme()=="https"||(url.scheme()=="http"&&matches!(host,"localhost"|"127.0.0.1"|"[::1]")))||!url.username().is_empty()||url.password().is_some(){return false;}
    v["networkDomains"].as_array().is_none_or(|domains|domains.iter().filter_map(Value::as_str).any(|domain|{let domain=domain.to_ascii_lowercase();let host=host.to_ascii_lowercase();host==domain||(domain.starts_with("*.")&&host.ends_with(&domain[1..])&&host!=domain[2..])}))
}
async fn network(v:&Value,p:&Value)->Result<Value,String>{
    let url=reqwest::Url::parse(text(p,"url")).map_err(|_|"Неверный URL")?;if !network_allowed(v,&url){return Err("Сеть или домен запрещены manifest".into());}
    let body=text(p,"body");if body.len()>1048576{return Err("Тело запроса больше 1 МБ".into());}
    let policy=v.clone();let client=util::http_builder().timeout(Duration::from_secs(30)).redirect(reqwest::redirect::Policy::custom(move|attempt|{if attempt.previous().len()<5&&network_allowed(&policy,attempt.url()){attempt.follow()}else{attempt.stop()}})).build().map_err(|_|"Ошибка HTTP-клиента")?;
    let method=if text(p,"method").is_empty(){reqwest::Method::GET}else{reqwest::Method::from_bytes(text(p,"method").as_bytes()).map_err(|_|"Неверный HTTP-метод")?};
    let mut request=client.request(method,url);if !body.is_empty(){request=request.body(body.to_string());}
    if let Some(headers)=p["headers"].as_object(){if headers.len()>50{return Err("Слишком много заголовков".into());}for(k,value)in headers{request=request.header(k,value.as_str().ok_or("Неверный заголовок")?);}}
    let mut response=request.send().await.map_err(|_|"Не удалось выполнить сетевой запрос мода")?;let status=response.status().as_u16();let mut bytes=vec![];
    while let Some(chunk)=response.chunk().await.map_err(|_|"Ответ сети оборвался")?{if bytes.len()+chunk.len()>8*1048576{return Err("Ответ больше 8 МБ".into());}bytes.extend_from_slice(&chunk);}
    Ok(json!({"status":status,"body":String::from_utf8_lossy(&bytes)}))
}
fn process(v:&Value,p:&Value,method:&str,root:&Path)->Result<Value,String>{
    let name=text(p,"id");if !id(name){return Err("Неверное имя процесса".into());}let owner=text(v,"id");let key=format!("{owner}/{name}");let mut processes=PROCESSES.lock().unwrap();
    if method=="process.stop"{if let Some(p)=processes.get_mut(&key){terminate(&mut p.child);}return Ok(json!({"ok":true}));}
    if method=="process.read"{let p=processes.get_mut(&key).ok_or("Процесс не найден")?;let running=p.child.try_wait().map_err(|_|"Ошибка процесса")?.is_none();return Ok(json!({"running":running,"text":String::from_utf8_lossy(&p.log.lock().unwrap())}));}
    if let Some(p)=processes.get_mut(&key){if p.child.try_wait().map_err(|_|"Ошибка процесса")?.is_none(){return Ok(json!({"pid":p.child.id(),"running":true}));}}
    let mut running=0;for(key,p)in processes.iter_mut(){if key.starts_with(&format!("{owner}/"))&&p.child.try_wait().ok().flatten().is_none(){running+=1;}}if running>=8{return Err("Не более восьми процессов мода".into());}
    let executable=Path::new(text(p,"executable"));if !executable.is_absolute(){return Err("Нужен абсолютный путь программы".into());}let args=p["arguments"].as_array().ok_or("Нужны arguments[]")?;if args.len()>60{return Err("Не более 60 аргументов".into());}
    let mut cmd=util::command(executable);for arg in args{cmd.arg(arg.as_str().ok_or("Аргумент должен быть строкой")?);}if let Some(env)=p["environment"].as_object(){if env.len()>30{return Err("Не более 30 переменных окружения".into());}for(k,value)in env{if k.contains(['=','\0']){return Err("Неверная переменная окружения".into());}cmd.env(k,value.as_str().ok_or("Неверная переменная окружения")?);}}
    cmd.current_dir(root).env("PULT_MOD_DATA",data(owner)).env("PULT_MOD_ASSETS",data(owner).join("assets").join(fingerprint(v))).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).kill_on_drop(true);
    let mut child=cmd.spawn().map_err(|_|"Не удалось запустить процесс мода")?;let pid=child.id();let log=Arc::new(Mutex::new(Vec::<u8>::new()));
    let readers:Vec<Box<dyn tokio::io::AsyncRead+Unpin+Send>>=vec![Box::new(child.stdout.take().unwrap()),Box::new(child.stderr.take().unwrap())];
    for mut reader in readers{let log=log.clone();tokio::spawn(async move{let mut chunk=[0;4096];while let Ok(n)=reader.read(&mut chunk).await{if n==0{break;}let mut bytes=log.lock().unwrap();bytes.extend_from_slice(&chunk[..n]);let drop=bytes.len().saturating_sub(100000);bytes.drain(..drop);}});}
    processes.insert(key,ModProcess{child,log,fingerprint:fingerprint(v),reported:false});Ok(json!({"pid":pid,"running":true}))
}

pub fn document(uri:&tauri::http::Uri)->tauri::http::Response<Vec<u8>>{
    let result=(||->Result<(String,String),String>{
        let path:Vec<_>=uri.path().trim_matches('/').split('/').collect();if path.len()!=4{return Err("Неверный адрес мода".into());}let(owner,hash,kind,name)=(path[0],path[1],path[2],path[3]);let v=active(owner,hash)?;
        let (html,script)=match kind{
            "panel"=>{let p=panels(&v).into_iter().find(|p|p["id"]==name).ok_or("Панель не найдена")?;(text(&p,"html").to_string(),String::new())},
            "command"=>{let c=v["commands"].as_array().unwrap().iter().find(|c|c["name"]==name).ok_or("Команда не найдена")?;(String::new(),c["script"].as_str().ok_or("Не JS-команда")?.to_string())},
            "background" if name=="run"=>(String::new(),v["background"].as_str().ok_or("Нет фонового кода")?.to_string()),
            _=>return Err("Неизвестный контекст мода".into()),
        };
        let mut settings=v["settings"].clone();if !settings.is_object(){settings=json!({});}for(k,value)in state()[owner]["settings"].as_object().into_iter().flatten(){if !settings[k].is_null(){settings[k]=value.clone();}}
        let network=if v["permissions"].as_array().unwrap().contains(&json!("network")){if let Some(domains)=v["networkDomains"].as_array(){domains.iter().filter_map(Value::as_str).flat_map(|d|[format!("https://{d}:*"),format!("http://{d}:*"),format!("wss://{d}:*"),format!("ws://{d}:*")]).collect::<Vec<_>>().join(" ")}else{"https: http: wss: ws:".into()}}else{String::new()};
        let network=if network.is_empty(){"'none'"}else{&network};let policy=format!("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: {network}; connect-src {network}; font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none'");
        let script=if script.is_empty(){String::new()}else{format!("window.__pultRun=async(input)=>{{\n{script}\n}};")};
        let content=format!("<!doctype html><meta charset=\"utf-8\"><script>window.pultSettings={};{}</script><script>{}</script><style>body{{font:14px system-ui;background:#181b21;color:#eceef3;margin:16px}}button,input,textarea{{font:inherit}}</style>{html}",settings.to_string().replace('<',"\\u003c"),include_str!("../ui/mod-runtime.js"),script);
        Ok((policy,content))
    })();
    match result{Ok((policy,content))=>tauri::http::Response::builder().header("Content-Type","text/html; charset=utf-8").header("Content-Security-Policy",policy).header("Cache-Control","no-store").body(content.into_bytes()).unwrap(),Err(_)=>tauri::http::Response::builder().status(403).header("Content-Type","text/plain; charset=utf-8").header("Content-Security-Policy","default-src 'none'").body("Мод выключен, изменён или контекст недоступен".as_bytes().to_vec()).unwrap()}
}
