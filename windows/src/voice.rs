use crate::util;
use serde_json::{json,Value};
use std::{process::Stdio,sync::{Arc,Mutex,LazyLock}};
use tauri::AppHandle;
use tokio::{io::{AsyncReadExt,AsyncWriteExt},sync::Notify};
static CURRENT:LazyLock<Mutex<Option<Arc<Notify>>>>=LazyLock::new(Default::default);
pub fn init(_app:&AppHandle){}
pub async fn call(_app:&AppHandle,method:&str,a:Value)->Result<Value,String>{
if method=="state"{return Ok(json!({"native":cfg!(any(windows,target_os="macos")),"requiresUserGesture":true}));}
if method=="stop"{if let Some(cancel)=CURRENT.lock().unwrap().take(){cancel.notify_one();}return Ok(Value::Null);}
if !["listen","speak","voices"].contains(&method){return Err("Неизвестное действие голоса".into());}
if !cfg!(any(windows,target_os="macos")){return Err("Нативная речь доступна на Windows и macOS".into());}
let language=a["language"].as_str().unwrap_or("ru-RU");if language.len()>30||!language.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-'){return Err("Неверный язык речи".into());}
let text=a["text"].as_str().unwrap_or_default();if text.len()>200000{return Err("Текст озвучки больше 200 КБ".into());}
let voice=a["voice"].as_str().unwrap_or_default();if voice.len()>512{return Err("Неверный голос".into());}
let cancel=Arc::new(Notify::new());if method!="voices"{let mut current=CURRENT.lock().unwrap();if current.is_some(){return Err("Голос уже работает; сначала останови его".into());}*current=Some(cancel.clone());}
let result=async {
 let mut cmd=engine()?;cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true);
 let mut child=cmd.spawn().map_err(|_|"Не удалось запустить речевой движок")?;
 let mut input=child.stdin.take().ok_or("Нет stdin speech engine")?;let mut stdout=child.stdout.take().ok_or("Нет stdout speech engine")?;
 let payload=json!({"action":method,"language":language,"text":text,"voice":voice}).to_string();
 let operation=async {
   input.write_all(payload.as_bytes()).await.map_err(|_|"Ошибка передачи речи")?;drop(input);
   let mut bytes=Vec::new();(&mut stdout).take(1_048_577).read_to_end(&mut bytes).await.map_err(|_|"Ошибка чтения речи")?;
   if bytes.len()>1_048_576{return Err("Ответ speech engine больше 1 МБ".into());}
   let status=child.wait().await.map_err(|_|"Ошибка speech engine")?;
   if !status.success(){return Err(if method=="voices"{"Не удалось получить список системных голосов"}else if method=="speak"{"Не удалось озвучить текст. Проверь, что выбранный голос установлен"}else if cfg!(target_os="macos"){"Микрофон или распознавание речи недоступны: разреши их Пульту в «Конфиденциальность и безопасность»"}else{"Речевой пакет языка, микрофон или голос Windows недоступен. Проверь разрешения и установленные языки"}.into());}
   parse(&bytes)
 };
 let timeout=std::time::Duration::from_secs(if method=="listen"{45}else{300});
 tokio::select! {
   result=tokio::time::timeout(timeout,operation)=>result.map_err(|_|"Речевой движок превысил время ожидания".to_string())?,
   _=cancel.notified()=>Err("Голос остановлен".into()),
 }
}.await;
let mut current=CURRENT.lock().unwrap();if current.as_ref().is_some_and(|c|Arc::ptr_eq(c,&cancel)){*current=None;}result
}

/// Windows — PowerShell-скрипт с System.Speech; macOS — помощник pult-voice из ресурсов приложения (Speech + AVFoundation).
fn engine()->Result<tokio::process::Command,String>{
 if cfg!(target_os="macos"){
  let exe=std::env::current_exe().map_err(|_|"Нет пути приложения")?;
  let helper=exe.parent().and_then(|d|d.parent()).map(|c|c.join("Resources/pult-voice")).filter(|p|p.is_file()).ok_or("Нет помощника pult-voice в сборке")?;
  return Ok(util::command(helper));
 }
 let script=util::data_dir().join("voice-engine.ps1");util::atomic_write(&script,include_bytes!("voice.ps1"))?;
 let mut cmd=util::command("powershell.exe");cmd.args(["-NoProfile","-NonInteractive","-File"]).arg(script);Ok(cmd)
}
fn parse(bytes:&[u8])->Result<Value,String>{let bytes=bytes.strip_prefix(&[0xef,0xbb,0xbf]).unwrap_or(bytes);let value:Value=serde_json::from_slice(bytes).map_err(|_|"Неверный UTF-8 JSON ответ speech engine")?;if value["ok"]==true||value["text"].is_string()||value["voices"].is_array(){Ok(value)}else{Err("Неверный протокол speech engine".into())}}
#[cfg(test)]mod tests{use super::*;#[test]fn speech_accepts_bom_and_unicode_but_not_arbitrary_json(){assert_eq!(parse("\u{feff}{\"text\":\"Привет\"}".as_bytes()).unwrap()["text"],"Привет");assert!(parse(b"{\"unexpected\":true}").is_err());assert!(parse(&[0xff]).is_err());}}
