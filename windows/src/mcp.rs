use crate::util;
use serde_json::{json, Value};
use std::{process::Stdio,time::Duration};
use tauri::AppHandle;
fn name(s:&str)->bool{!s.is_empty()&&s.len()<=80&&s.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'_'||b==b'-')}
fn arguments(a:&Value)->Result<Vec<String>,String>{
    let provider=a["provider"].as_str().unwrap_or("codex");let method=a["method"].as_str().unwrap_or_default();let server=a["name"].as_str().unwrap_or_default();
    if !["codex","claude"].contains(&provider){return Err("Неизвестный провайдер MCP".into());}
    let mut args=vec!["mcp".into()];
    if method=="list"{args.push("list".into());if provider=="codex"{args.push("--json".into());}return Ok(args);}
    if !name(server){return Err("Имя MCP: буквы, цифры, _ и - (до 80)".into());}
    if method!="add"{return Err("Неизвестное действие MCP".into());}
    args.push("add".into());if provider=="claude"{args.extend(["--scope".into(),"user".into()]);}
    let native=a["native"]==true;
    if !native && a["url"].is_string(){
        let url=reqwest::Url::parse(a["url"].as_str().unwrap()).map_err(|_|"Неверный URL MCP")?;
        if !(url.scheme()=="https"||(url.scheme()=="http"&&matches!(url.host_str(),Some("localhost"|"127.0.0.1"|"[::1]"))))||!url.username().is_empty()||url.password().is_some()||url.query().is_some()||url.fragment().is_some(){return Err("Нужен HTTPS URL без ключей, query и credentials".into());}
        if provider=="claude"{args.extend(["--transport".into(),"http".into(),server.into(),url.to_string()]);}else{args.extend([server.into(),"--url".into(),url.to_string()]);}
    }else{
        args.push(server.into());args.push("--".into());
        if native{args.push(std::env::current_exe().map_err(|_|"Нет пути Пульта")?.to_string_lossy().to_string());args.push("--mcp-computer".into());}
        else{let executable=a["executable"].as_str().filter(|s|!s.is_empty()&&!s.contains(['\0','\r','\n'])).ok_or("Нужна программа MCP")?;let extra=a["arguments"].as_array().ok_or("Аргументы должны быть JSON-массивом строк")?;if extra.len()>100{return Err("Не более 100 аргументов".into());}args.push(executable.into());for arg in extra{let arg=arg.as_str().filter(|s|s.len()<=10000&&!s.contains('\0')).ok_or("Некорректный аргумент MCP")?;args.push(arg.into());}}
    }Ok(args)
}
pub async fn call(_app:&AppHandle,method:&str,mut a:Value)->Result<Value,String>{
    a["method"]=json!(method);let args=arguments(&a)?;let provider=a["provider"].as_str().unwrap_or("codex");
    let mut cmd=util::command(util::find_bin(provider).ok_or("CLI провайдера не установлен")?);cmd.args(args).stdin(Stdio::null()).kill_on_drop(true);
    if provider=="codex"{let home=a["home"].as_str().ok_or("Не выбран аккаунт Codex")?;if !util::accounts().iter().any(|account|account.home==home){return Err("Неизвестный аккаунт Codex".into());}cmd.env("CODEX_HOME",home);}
    let output=tokio::time::timeout(Duration::from_secs(30),cmd.output()).await.map_err(|_|"CLI не ответил за 30 секунд")?.map_err(|_|"Не удалось запустить CLI")?;
    if !output.status.success(){return Err("CLI отклонил настройку MCP. Проверь программу, URL и установленную версию CLI".into());}
    if method=="list"{
        let rows=if provider=="codex"{let raw:Value=serde_json::from_slice(&output.stdout).map_err(|_|"Неверный ответ Codex MCP")?;raw.as_array().into_iter().flatten().map(|r|json!({"name":r["name"],"enabled":r["enabled"]})).collect::<Vec<_>>()}else{String::from_utf8_lossy(&output.stdout).lines().filter_map(|line|line.split_once(':').map(|(s,_)|s.trim()).filter(|s|name(s)).map(|s|json!({"name":s,"enabled":true}))).collect()};return Ok(json!(rows));
    }Ok(json!({"ok":true}))
}
#[cfg(test)]mod tests{use super::*;
    #[test]fn stdio_arguments_are_separate_from_the_shell(){let args=arguments(&json!({"method":"add","name":"test","provider":"codex","executable":"C:\\Program Files\\server.exe","arguments":["a & b","--flag"]})).unwrap();assert_eq!(args,vec!["mcp","add","test","--","C:\\Program Files\\server.exe","a & b","--flag"]);}
    #[test]fn http_urls_do_not_store_tokens_in_cli_config(){for url in ["http://example.com/mcp","https://example.com/mcp?key=secret","https://secret@example.com/mcp"]{assert!(arguments(&json!({"method":"add","name":"test","url":url})).is_err());}}
}
