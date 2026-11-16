use crate::util;
use serde_json::{json,Value};
use sha2::{Digest,Sha256};
use std::sync::Mutex;
use tauri::AppHandle;
static CANDIDATE:Mutex<Option<(String,String,String)>>=Mutex::new(None);
pub fn init(_app:&AppHandle){}
fn verify(bytes:&[u8],hash:&str)->bool{
 if bytes.len()<64||bytes.len()>=250_000_000||!bytes.starts_with(b"MZ")||!digest(hash){return false;}
 let offset=u32::from_le_bytes(bytes[60..64].try_into().unwrap()) as usize;
 let Some(header)=offset.checked_add(24).and_then(|end|bytes.get(offset..end)) else{return false;};
 if &header[..4]!=b"PE\0\0"||u16::from_le_bytes([header[22],header[23]])&2==0{return false;}
 format!("{:x}",Sha256::digest(bytes))==hash
}

fn digest(s:&str)->bool{s.len()==64&&s.bytes().all(|b|b.is_ascii_hexdigit())}
fn allowed(url:&reqwest::Url)->bool{url.scheme()=="https"&&url.username().is_empty()&&url.password().is_none()&&url.host_str().is_some_and(|h|h=="github.com"||h=="release-assets.githubusercontent.com"||h=="objects.githubusercontent.com")}
fn client()->Result<reqwest::Client,String>{util::http_builder().user_agent("Pult-Windows").redirect(reqwest::redirect::Policy::custom(|a|if a.previous().len()<5&&allowed(a.url()){a.follow()}else{a.stop()})).timeout(std::time::Duration::from_secs(180)).build().map_err(|_|"Ошибка HTTP".into())}
pub async fn call(_app:&AppHandle,method:&str,_a:Value)->Result<Value,String>{match method{
"check"=>{let response=client()?.get("https://api.github.com/repos/abobalover228-afk/pult-public/releases/latest").send().await.map_err(|_|"GitHub недоступен")?;if !response.status().is_success(){return Err("Не удалось проверить релиз".into());}let release:Value=response.json().await.map_err(|_|"Неверный ответ GitHub")?;let tag=release["tag_name"].as_str().ok_or("Нет версии релиза")?;let candidate=release["assets"].as_array().into_iter().flatten().find_map(|a|{let name=a["name"].as_str()?;let url=a["browser_download_url"].as_str()?;let hash=a["digest"].as_str()?.strip_prefix("sha256:")?;if !name.ends_with(".exe")||!(name.to_lowercase().contains("pult")||name.to_lowercase().contains("пульт"))||!digest(hash)||!url.starts_with("https://github.com/abobalover228-afk/pult-public/releases/download/"){return None;}Some((url.to_string(),hash.to_ascii_lowercase(),tag.to_string()))});*CANDIDATE.lock().unwrap()=candidate.clone();Ok(json!({"current":env!("CARGO_PKG_VERSION"),"tag":tag,"name":release["name"],"installable":candidate.is_some(),"newer":newer(tag,env!("CARGO_PKG_VERSION")),"url":release["html_url"]}))},
"install"=>{if !cfg!(windows){return Err("Установщик доступен на Windows".into());}let(url,hash,version)=CANDIDATE.lock().unwrap().clone().ok_or("Сначала проверь релиз с SHA-256 установщика")?;let mut response=client()?.get(url).send().await.map_err(|_|"Не удалось скачать установщик")?;if !response.status().is_success(){return Err("GitHub отклонил скачивание".into());}let mut bytes=vec![];while let Some(chunk)=response.chunk().await.map_err(|_|"Скачивание оборвалось")?{if bytes.len()+chunk.len()>250_000_000{return Err("Установщик больше 250 МБ".into());}bytes.extend_from_slice(&chunk);}if !verify(&bytes,&hash){return Err("SHA-256 или формат установщика не совпадает".into());}let dir=util::data_dir().join("updates");let path=dir.join(format!("pult-{}.exe",uuid::Uuid::new_v4()));util::atomic_write(&path,&bytes)?;std::process::Command::new(path).spawn().map_err(|_|"Не удалось запустить проверенный установщик")?;Ok(json!({"launched":true,"version":version}))},_=>Err("Неизвестный метод обновления".into())}}
#[cfg(test)]mod tests{use super::*;#[test]fn release_redirects_are_restricted(){assert!(allowed(&reqwest::Url::parse("https://release-assets.githubusercontent.com/file").unwrap()));for url in ["https://github.com.evil.test/file","http://github.com/file","https://key@github.com/file"]{assert!(!allowed(&reqwest::Url::parse(url).unwrap()));}assert!(!verify(b"MZfake",&"a".repeat(64)));let mut good=vec![0;88];good[..2].copy_from_slice(b"MZ");good[60..64].copy_from_slice(&64u32.to_le_bytes());good[64..68].copy_from_slice(b"PE\0\0");good[86]=2;assert!(verify(&good,&format!("{:x}",Sha256::digest(&good))));assert!(!verify(b"not-exe",&format!("{:x}",Sha256::digest(b"not-exe"))));assert!(!digest("bad"));assert!(digest(&"a".repeat(64)));}}

fn newer(tag:&str,current:&str)->bool{fn version(s:&str)->Option<[u64;3]>{let values:Vec<_>=s.trim_start_matches('v').split('.').map(str::parse::<u64>).collect::<Result<_,_>>().ok()?;values.try_into().ok()}match(version(tag),version(current)){(Some(a),Some(b))=>a>b,_=>false}}
#[cfg(test)]mod version_tests{use super::*;#[test]fn only_strictly_newer_stable_versions_auto_install(){assert!(newer("v2.5.0","2.4.0"));assert!(!newer("2.4.0","2.4.0"));assert!(!newer("2.3.0","2.4.0"));assert!(!newer("2.5.0-beta","2.4.0"));}}
