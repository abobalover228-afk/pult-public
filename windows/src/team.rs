use serde::{Deserialize,Serialize};
use serde_json::{json,Value};
use std::collections::{HashMap,HashSet};
use tauri::AppHandle;
#[derive(Clone,Default,Serialize,Deserialize)]
#[serde(rename_all="camelCase")]
struct Task{ id:String,title:String,detail:String,status:String,#[serde(rename="ownerID",alias="ownerId")]owner_id:Option<String>,owner_name:Option<String>,branch:Option<String>,#[serde(default)]result:String,pull_request:Option<String> }
#[derive(Clone,Default,Serialize,Deserialize)]struct Snapshot{revision:u64,tasks:Vec<Task>,repository:String}
#[derive(Clone,Default,Serialize,Deserialize)]struct Board{state:Snapshot,receipts:HashMap<String,(String,Value)>}
fn slug(s:&str)->Option<String>{let raw=if let Some(s)=s.strip_prefix("git@github.com:"){s.to_string()}else{let u=reqwest::Url::parse(s).ok()?;if u.scheme()!="https"||u.host_str()!=Some("github.com")||!u.username().is_empty()||u.password().is_some()||u.query().is_some()||u.fragment().is_some()||u.port().is_some(){return None;}u.path().trim_start_matches('/').into()};let raw=raw.strip_suffix(".git").unwrap_or(&raw);let p:Vec<_>=raw.split('/').collect();if p.len()!=2||p.iter().any(|s|s.is_empty()||*s=="."||*s==".."||!s.bytes().all(|b|b.is_ascii_alphanumeric()||b"_.-".contains(&b))){return None;}Some(raw.into())}
fn valid(t:&Task)->bool{uuid::Uuid::parse_str(&t.id).is_ok()&&!t.title.trim().is_empty()&&t.title.chars().count()<=160&&t.detail.len()<=8000&&t.result.len()<=8000}
impl Board{
fn load(path:&std::path::Path)->Result<Self,String>{
 use std::io::Read;
 let file=match std::fs::File::open(path){Ok(file)=>file,Err(e)if e.kind()==std::io::ErrorKind::NotFound=>return Ok(Self::default()),Err(_)=>return Err("Не прочитать доску комнаты".into())};
 let mut bytes=vec![];file.take(4_000_001).read_to_end(&mut bytes).map_err(|_|"Не прочитать доску")?;
 if bytes.len()>4_000_000{return Err("Доска комнаты больше 4 МБ".into());}
 let board:Self=serde_json::from_slice(&bytes).map_err(|_|"Повреждена доска комнаты; файл сохранён для восстановления")?;
 if board.state.tasks.len()>100||board.receipts.len()>2000||!board.state.tasks.iter().all(valid)||board.state.tasks.iter().map(|t|&t.id).collect::<HashSet<_>>().len()!=board.state.tasks.len(){return Err("Неверная сохранённая доска".into());}
 Ok(board)
}
fn apply(&mut self,r:&Value,sender:&str,host:&str)->Value{
 let rid=r["id"].as_str().unwrap_or_default();if uuid::Uuid::parse_str(rid).is_err(){return json!({"error":"Неверный ID запроса"});}
 if let Some((owner,reply))=self.receipts.get(rid){return if owner==sender{let mut v=reply.clone();v["snapshot"]=json!(self.state);v}else{json!({"response":rid,"error":"Чужой запрос"})};}
 let action=r["action"].as_str().unwrap_or_default();let ids:HashSet<_>=r["ids"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();let indices:Vec<_>=self.state.tasks.iter().enumerate().filter(|(_,t)|ids.contains(t.id.as_str())).map(|(i,_)|i).collect();let mut error=None;
 match action{
 "sync"=>{},
 "repository"=>{let repo=r["repository"].as_str().unwrap_or_default();if sender!=host{error=Some("Репозиторий меняет создатель");}else if self.state.tasks.iter().any(|t|t.owner_id.is_some())&&repo!=self.state.repository{error=Some("Есть назначенные задачи");}else if repo.is_empty()||slug(repo).is_some(){self.state.repository=repo.into();}else{error=Some("Нужен GitHub URL без токена");}},
 "add"=>{match serde_json::from_value::<Task>(r["task"].clone()){Ok(mut t)if valid(&t)&&self.state.tasks.len()<100&&!self.state.tasks.iter().any(|x|x.id==t.id)=>{t.status="available".into();t.owner_id=None;t.owner_name=None;t.branch=None;t.result.clear();t.pull_request=None;self.state.tasks.push(t);},_=>error=Some("Неверная задача или доска заполнена")}},
 "claim"=>{let name=r["name"].as_str().unwrap_or_default();if ids.is_empty()||ids.len()>3||indices.len()!=ids.len()||name.is_empty()||name.chars().count()>80||indices.iter().any(|i|self.state.tasks[*i].status!="available"){error=Some("Задачи уже назначены или неверный выбор");}else{for i in &indices{let t=&mut self.state.tasks[*i];t.owner_id=Some(sender.into());t.owner_name=Some(name.into());t.status="working".into();t.branch=Some(format!("pult/task-{}",t.id.to_lowercase()));}}},
 "update"=>{match serde_json::from_value::<Task>(r["task"].clone()){Ok(t)if valid(&t)=>{if let Some(old)=self.state.tasks.iter_mut().find(|old|old.id==t.id&&old.owner_id.as_deref()==Some(sender)){let pr_ok=t.pull_request.as_ref().is_none_or(|pr|slug(&self.state.repository).is_some_and(|repo|pr.strip_prefix(&format!("https://github.com/{repo}/pull/")).is_some_and(|n|!n.is_empty()&&n.bytes().all(|b|b.is_ascii_digit()))));if ["working","needsAnswer","review","failed"].contains(&t.status.as_str())&&pr_ok{old.status=t.status;old.result=t.result;old.pull_request=t.pull_request;}else{error=Some("Неверное обновление");}}else{error=Some("Обновлять может исполнитель");}},_=>error=Some("Неверная задача")}},
 "complete"=>{if indices.len()!=1{error=Some("Выбери одну задачу");}else{let t=&mut self.state.tasks[indices[0]];if t.status!="review"||(sender!=host&&t.owner_id.as_deref()!=Some(sender)){error=Some("Сначала проверь результат");}else{t.status="done".into();}}},
 "release"=>{if indices.len()!=1{error=Some("Выбери одну задачу");}else{let t=&mut self.state.tasks[indices[0]];if t.owner_id.as_deref()!=Some(sender)||t.pull_request.is_some()||!["failed","review"].contains(&t.status.as_str()){error=Some("Нельзя освободить эту задачу");}else{t.status="available".into();t.owner_id=None;t.owner_name=None;}}},
 _=>error=Some("Неизвестное действие")}
 if error.is_none()&&action!="sync"{self.state.revision+=1;}
 let reply=json!({"snapshot":self.state,"response":rid,"error":error});self.receipts.insert(rid.into(),(sender.into(),json!({"response":rid,"error":error})));if self.receipts.len()>2000{self.receipts.retain(|k,_|k==rid);}reply
}}
pub fn init(_app:&AppHandle){}
static BOARDS: std::sync::LazyLock<std::sync::Mutex<HashMap<String,Board>>>=std::sync::LazyLock::new(Default::default);
pub async fn call(_app:&AppHandle,method:&str,a:Value)->Result<Value,String>{
 if method=="board"{
 let room=a["room"].as_str().filter(|s|(20..=80).contains(&s.len())&&s.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'_'||b==b'-')).ok_or("Нет комнаты")?;
 let path=crate::util::data_dir().join("Rooms").join(format!("{room}.board.json"));
 let mut boards=BOARDS.lock().unwrap();
 if !boards.contains_key(room){boards.insert(room.into(),Board::load(&path)?);}
 let mut next=boards[room].clone();
 let reply=next.apply(&a["request"],a["sender"].as_str().ok_or("Нет отправителя")?,a["host"].as_str().ok_or("Нет хоста")?);
 crate::util::atomic_write(&path,&serde_json::to_vec(&next).map_err(|_|"Не сохранить доску")?)?;
 boards.insert(room.into(),next);return Ok(reply);
}
 if method=="outbox"{let room=a["room"].as_str().filter(|s|(20..=80).contains(&s.len())&&s.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'_'||b==b'-')).ok_or("Неверная комната")?;let file=crate::util::data_dir().join("Rooms").join(format!("{room}.outbox.json"));if a["save"]==true{let rows=a["rows"].as_array().filter(|r|r.len()<=100).ok_or("Outbox переполнен")?;let bytes=serde_json::to_vec(rows).map_err(|_|"Ошибка outbox")?;if bytes.len()>1000000{return Err("Outbox больше 1 МБ".into());}crate::util::atomic_write(&file,&bytes)?;return Ok(json!({"ok":true}));}return match std::fs::read(file){Ok(bytes)=>serde_json::from_slice(&bytes).map_err(|_|"Повреждён outbox".into()),Err(e)if e.kind()==std::io::ErrorKind::NotFound=>Ok(json!([])),Err(_)=>Err("Outbox недоступен".into())};}
 if method=="history"{
 // Переписка комнаты на диске: переживает перезапуск, до 500 сообщений.
 let room=a["room"].as_str().filter(|s|(20..=80).contains(&s.len())&&s.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'_'||b==b'-')).ok_or("Неверная комната")?;let file=crate::util::data_dir().join("Rooms").join(format!("{room}.chat.json"));
 if a["save"]==true{let rows=a["rows"].as_array().filter(|r|r.len()<=500).ok_or("Слишком длинная история")?;let bytes=serde_json::to_vec(rows).map_err(|_|"Ошибка истории")?;if bytes.len()>4_000_000{return Err("История больше 4 МБ".into());}crate::util::atomic_write(&file,&bytes)?;return Ok(json!({"ok":true}));}
 return match std::fs::read(file){Ok(bytes)=>Ok(serde_json::from_slice(&bytes).unwrap_or(json!([]))),Err(_)=>Ok(json!([]))};}
 if method=="token"{
 // Токен создания комнат: только записать или узнать, задан ли он. Сам токен в интерфейс не возвращается.
 let file=crate::util::data_dir().join("team/.env");let env=std::fs::read_to_string(&file).unwrap_or_default();
 if let Some(value)=a["value"].as_str(){let value=value.trim();if value.len()>200||!value.bytes().all(|b|b.is_ascii_graphic()){return Err("Неверный токен".into());}let text=format!("{}\nPULT_ROOM_CREATE_TOKEN={}\n",env.lines().filter(|l|!l.starts_with("PULT_ROOM_CREATE_TOKEN=")).collect::<Vec<_>>().join("\n"),value);crate::util::atomic_write(&file,text.as_bytes())?;return Ok(json!({"set":!value.is_empty()}));}
 return Ok(json!({"set":env.lines().any(|l|l.strip_prefix("PULT_ROOM_CREATE_TOKEN=").is_some_and(|v|!v.trim_matches('"').is_empty()))}));}
 if method=="health"{
 let server=a["server"].as_str().ok_or("Нет адреса")?;let mut url=reqwest::Url::parse(server.trim()).map_err(|_|"Нужен адрес вида https://твой.домен/pult-link")?;
 if !(url.scheme()=="https"||(url.scheme()=="http"&&matches!(url.host_str(),Some("localhost"|"127.0.0.1"|"[::1]"))))||!url.username().is_empty()||url.password().is_some()||url.query().is_some()||url.fragment().is_some(){return Err("Нужен HTTPS-адрес без логина и параметров".into());}
 url.set_path(&format!("{}/health",url.path().trim_end_matches('/')));
 let client=crate::util::http_builder().redirect(reqwest::redirect::Policy::none()).timeout(std::time::Duration::from_secs(10)).build().map_err(|_|"Ошибка HTTP")?;
 let response=client.get(url).send().await.map_err(|_|"Сервер не отвечает")?;let code=response.status().as_u16();
 let value:Value=response.json().await.unwrap_or(Value::Null);if code!=200||value["ok"]!=true{return Err(format!("Это не сервер комнат Пульта (ответ {code})"));}
 return Ok(json!({"relay":value["mode"]=="relay","create":value["create"].as_str().unwrap_or("token")}));}
 if method=="saved"{let file=crate::util::data_dir().join("team/.env");let env=std::fs::read_to_string(file).unwrap_or_default();let code=env.lines().find_map(|l|l.strip_prefix("PULT_TEAM_INVITATION=")).and_then(|s|serde_json::from_str::<String>(s).ok());let identity=env.lines().find_map(|l|l.strip_prefix("PULT_TEAM_IDENTITY=")).and_then(|s|serde_json::from_str::<String>(s).ok());return Ok(json!({"code":code,"identity":identity}));}
 if method=="saveInvitation"{
 let code=a["code"].as_str().filter(|s|s.len()<4000).ok_or("Неверное приглашение")?;env_set("PULT_TEAM_INVITATION",code)?;
 // ID участника хранится и у вошедшего по приглашению: иначе после перезапуска его задачи становятся чужими.
 if let Some(identity)=a["identity"].as_str(){uuid::Uuid::parse_str(identity).map_err(|_|"Неверный ID участника")?;env_set("PULT_TEAM_IDENTITY",identity)?;}
 return Ok(json!({"ok":true}));}
 if method=="create"{
 use base64::Engine;let server=a["server"].as_str().ok_or("Нет сервера")?;let mut url=reqwest::Url::parse(server).map_err(|_|"Неверный сервер")?;if !(url.scheme()=="https"||(url.scheme()=="http"&&matches!(url.host_str(),Some("localhost"|"127.0.0.1"|"[::1]"))))||!url.username().is_empty()||url.password().is_some()||url.query().is_some()||url.fragment().is_some(){return Err("Неверный сервер".into());}url.set_path(&format!("{}/v1/rooms",url.path().trim_end_matches('/')));
 let file=crate::util::data_dir().join("team/.env");let env=std::fs::read_to_string(&file).unwrap_or_default();let token=env.lines().find_map(|l|l.strip_prefix("PULT_ROOM_CREATE_TOKEN=")).unwrap_or_default().trim_matches('"');
 let client=crate::util::http_builder().redirect(reqwest::redirect::Policy::none()).timeout(std::time::Duration::from_secs(15)).build().map_err(|_|"Ошибка HTTP")?;let mut request=client.post(url).json(&json!({}));if !token.is_empty(){request=request.header("X-Pult-Create-Token",token);}let response=request.send().await.map_err(|_|"Нет связи с сервером")?;if response.status().as_u16()!=201{return Err("Создание отклонено; токен владельца нужен в Pult/team/.env".into());}let values:Value=response.json().await.map_err(|_|"Неверный ответ")?;
 let bytes=base64::engine::general_purpose::STANDARD.decode(a["key"].as_str().ok_or("Нет ключа комнаты")?).map_err(|_|"Неверный ключ")?;if bytes.len()!=32{return Err("Нужен 256-битный ключ".into());}let invitation=json!({"server":server,"room":values["room"],"access":values["access"],"key":base64::engine::general_purpose::STANDARD.encode(bytes),"coordinator":a["identity"]});let code=format!("{}/join#{}",server.trim_end_matches('/'),base64::engine::general_purpose::STANDARD.encode(invitation.to_string()));let saved=format!("{}\nPULT_TEAM_INVITATION={}\n",env.lines().filter(|l|!l.starts_with("PULT_TEAM_INVITATION=")&&!l.starts_with("PULT_TEAM_IDENTITY=")).collect::<Vec<_>>().join("\n"),serde_json::to_string(&code).unwrap());let saved=format!("{}PULT_TEAM_IDENTITY={}\n",saved,serde_json::to_string(a["identity"].as_str().ok_or("Нет identity")?).unwrap());crate::util::atomic_write(&file,saved.as_bytes())?;return Ok(json!({"code":code}));
 }
 if method=="preview"{return preview(&a).await;}
 if method=="publish"{
 let repository=slug(a["repository"].as_str().ok_or("Нет репозитория")?).ok_or("Неверный GitHub URL")?;
 let task=a["task"].as_str().ok_or("Нет задачи")?;uuid::Uuid::parse_str(task).map_err(|_|"Неверная задача")?;
 let current=preview(&a).await?;
 if a["approved"]!=true||a["fingerprint"]!=current["fingerprint"]||a["files"]!=current["files"]{return Err("Код изменился после просмотра; просмотри изменения заново".into());}
 let folder=crate::util::data_dir().join("Worktrees").join(task);let branch=format!("pult/task-{}",task.to_lowercase());
 if git(vec!["branch".into(),"--show-current".into()],&folder).await?!=branch{return Err("Ветка задачи изменилась".into());}
 let remote=git(vec!["remote".into(),"get-url".into(),"origin".into()],&folder).await?;if slug(&remote).map(|r|r.to_lowercase())!=Some(repository.to_lowercase()){return Err("Origin отличается от комнаты".into());}
 if !git(vec!["diff".into(),"--cached".into(),"--name-only".into()],&folder).await?.is_empty(){return Err("Есть staged файлы; нужна ручная проверка".into());}
 let base=git(vec!["symbolic-ref".into(),"refs/remotes/origin/HEAD".into()],&folder).await?;
 let committed=git(vec!["diff".into(),"--name-only".into(),format!("{base}...HEAD")],&folder).await?;
 if committed.lines().any(secret_path){return Err("В коммитах найдены секретные/служебные файлы; push заблокирован".into());}
 let files=current["pending"].as_array().ok_or("Нет списка файлов")?;
 if !files.is_empty(){let mut args=vec!["add".into(),"--".into()];args.extend(files.iter().filter_map(Value::as_str).map(str::to_string));git(args,&folder).await?;git(vec!["commit".into(),"-m".into(),a["title"].as_str().unwrap_or("Pult team task").chars().take(160).collect()],&folder).await?;}
 git(vec!["push".into(),"--set-upstream".into(),"origin".into(),branch.clone()],&folder).await?;
 let gh=crate::util::find_bin("gh").ok_or("Ветка отправлена. Для создания PR установи GitHub CLI и выполни gh auth login")?;
 let title=a["title"].as_str().unwrap_or("Pult team task");let body=format!("Задача Пульта: {task}\n\n{}",a["result"].as_str().unwrap_or_default());
 let body_file=folder.join(format!(".pult-pr-body-{}",uuid::Uuid::new_v4()));crate::util::atomic_write(&body_file,body.as_bytes())?;
 let result=tokio::time::timeout(std::time::Duration::from_secs(60),crate::util::command(gh).args(["pr","create","--repo",&repository,"--head",&branch,"--title",title,"--body-file",body_file.to_str().ok_or("Неверный путь")?]).current_dir(&folder).kill_on_drop(true).output()).await;
 let _=std::fs::remove_file(&body_file);
 let out=result.map_err(|_|"Ветка отправлена; GitHub CLI не ответил")?.map_err(|_|"Ветка отправлена; не удалось запустить GitHub CLI")?;
 if !out.status.success(){return Err("Ветка отправлена; PR не создан. Проверь gh auth status или существующий PR".into());}
 let url=String::from_utf8_lossy(&out.stdout).trim().to_string();if !url.starts_with(&format!("https://github.com/{repository}/pull/")){return Err("Ветка отправлена; GitHub CLI вернул неожиданный PR URL".into());}return Ok(json!({"url":url,"branch":branch}));
 }
 if method=="prepare"{
 let repo=slug(a["repository"].as_str().ok_or("Нет репозитория")?).ok_or("Неверный репозиторий")?;
 let task=a["task"].as_str().ok_or("Нет задачи")?;uuid::Uuid::parse_str(task).map_err(|_|"Неверный ID задачи")?;
 let root=crate::util::data_dir().join("Projects").join(repo.to_lowercase());let work=crate::util::data_dir().join("Worktrees").join(task);
 return prepare(&format!("https://github.com/{repo}.git"),&root,&work,task).await;
 }
 if method=="http"{
 let server=reqwest::Url::parse(a["server"].as_str().ok_or("Нет сервера")?).map_err(|_|"Неверный сервер")?;
 if !(server.scheme()=="https"||(server.scheme()=="http"&&matches!(server.host_str(),Some("127.0.0.1"|"localhost"|"[::1]"))))||!server.username().is_empty()||server.password().is_some()||server.query().is_some()||server.fragment().is_some(){return Err("Неверный сервер".into());}
 let room=a["room"].as_str().unwrap_or_default();let action=a["action"].as_str().unwrap_or_default();
 if !(20..=80).contains(&room.len())||!room.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'_'||b==b'-')||!["join","events","signal","leave","relay"].contains(&action){return Err("Неверный маршрут комнаты".into());}
 let mut url=server;url.set_path(&format!("{}/v1/rooms/{room}/{action}",url.path().trim_end_matches('/')));if action=="events"{url.query_pairs_mut().append_pair("after",&a["cursor"].as_u64().unwrap_or(0).to_string());}
 let client=crate::util::http_builder().redirect(reqwest::redirect::Policy::none()).timeout(std::time::Duration::from_secs(35)).build().map_err(|_|"Ошибка HTTP")?;
 let mut r=if action=="events"{client.get(url)}else{client.post(url).json(&a["body"])};
 r=r.bearer_auth(a["access"].as_str().ok_or("Нет доступа")?).header("X-Pult-Peer",a["identity"].as_str().ok_or("Нет идентичности")?).header("X-Pult-Peer-Key",peer_key()?);
 let mut response=r.send().await.map_err(|_|"Нет связи со службой знакомства")?;if !response.status().is_success(){return Err(format!("Служба знакомства: HTTP {}",response.status().as_u16()));}
 let mut bytes=vec![];while let Some(chunk)=response.chunk().await.map_err(|_|"Ответ оборвался")?{if bytes.len()+chunk.len()>4_000_000{return Err("Ответ слишком большой".into());}bytes.extend_from_slice(&chunk);}return serde_json::from_slice(&bytes).map_err(|_|"Неверный ответ службы".into());
 }Err(format!("team.{method}: не реализовано"))
}
fn env_get(name:&str)->Option<String>{std::fs::read_to_string(crate::util::data_dir().join("team/.env")).ok()?.lines().find_map(|l|l.strip_prefix(&format!("{name}=")).and_then(|s|serde_json::from_str::<String>(s).ok()))}
fn env_set(name:&str,value:&str)->Result<(),String>{
 let _env=crate::util::ENV.lock().unwrap();let file=crate::util::data_dir().join("team/.env");let env=std::fs::read_to_string(&file).unwrap_or_default();
 let text=format!("{}\n{name}={}\n",env.lines().filter(|l|!l.starts_with(&format!("{name}="))).collect::<Vec<_>>().join("\n"),serde_json::to_string(value).unwrap());
 crate::util::atomic_write(&file,text.as_bytes())
}
/// Секрет этого компьютера для сервера комнат: без него никто другой не займёт наш ID участника.
fn peer_key()->Result<String,String>{if let Some(key)=env_get("PULT_TEAM_PEER_KEY"){return Ok(key);}let key=format!("{}{}",uuid::Uuid::new_v4().simple(),uuid::Uuid::new_v4().simple());env_set("PULT_TEAM_PEER_KEY",&key)?;Ok(key)}
fn secret_path(path:&str)->bool{path.to_ascii_lowercase().split('/').any(|p|p.starts_with(".env")||[".git",".ssh",".aws","auth.json","credentials"].contains(&p)||p.ends_with(".key")||p.ends_with(".pem")||p.ends_with(".p12"))}
async fn preview(a:&Value)->Result<Value,String>{
 let task=a["task"].as_str().ok_or("Нет задачи")?;uuid::Uuid::parse_str(task).map_err(|_|"Неверный ID задачи")?;
 review(&crate::util::data_dir().join("Worktrees").join(task)).await
}
async fn review(folder:&std::path::Path)->Result<Value,String>{
 use sha2::{Digest,Sha256};
 let output=crate::util::git().args(["status","--porcelain=v1","-z","--untracked-files=all"]).current_dir(&folder).output().await.map_err(|_|"Git недоступен")?;
 if !output.status.success(){return Err("Нет worktree".into());}
 let mut pending=vec![];
 for row in String::from_utf8_lossy(&output.stdout).split('\0').filter(|r|!r.is_empty()){
  if row.len()<4{return Err("Неверный Git status".into());}
  if row.starts_with('R')||row.starts_with(" R"){return Err("Переименование требует ручной проверки Git".into());}
  pending.push(row[3..].to_string());
 }
 // Коммиты агента тоже уйдут в push: показываем всё от основы ветки, а не только незакоммиченное.
 let origin=git(vec!["symbolic-ref".into(),"refs/remotes/origin/HEAD".into()],&folder).await?;
 let base=git(vec!["merge-base".into(),origin,"HEAD".into()],&folder).await?;
 let committed=git(vec!["diff".into(),"--name-only".into(),"--no-renames".into(),format!("{base}..HEAD")],&folder).await?;
 let mut files:Vec<String>=pending.iter().cloned().chain(committed.lines().map(str::to_string)).collect();files.sort();files.dedup();
 if files.iter().any(|f|secret_path(f)){return Err("В изменениях найден секретный/служебный файл".into());}
 let mut hash=Sha256::new();hash.update(&output.stdout);hash.update(git(vec!["rev-parse".into(),"HEAD".into()],&folder).await?.as_bytes());
 for path in &files{let p=folder.join(path);if p.exists(){let meta=std::fs::symlink_metadata(&p).map_err(|_|"Нет файла")?;if meta.file_type().is_symlink(){return Err("Символьная ссылка требует ручной проверки".into());}if meta.len()>32*1024*1024{return Err("Файл больше 32 МБ требует ручной проверки".into());}hash.update(path.as_bytes());hash.update([0]);hash.update(std::fs::read(p).map_err(|_|"Нет доступа к файлу")?);}}
 let mut new_files=String::new();
 for path in &pending{if git(vec!["ls-files".into(),"--".into(),path.clone()],&folder).await?.is_empty(){let bytes=std::fs::read(folder.join(path)).map_err(|_|"Не прочитать новый файл")?;if let Ok(content)=std::str::from_utf8(&bytes){new_files.push_str(&format!("\nНовый файл: {path}\n{}",content.chars().take(24000).collect::<String>()));}else{new_files.push_str(&format!("\nБинарный файл: {path}, {} байт",bytes.len()));}}}
 let diff=crate::util::git().args(["diff","--no-ext-diff","--no-textconv",&base]).current_dir(&folder).output().await.map_err(|_|"Нет diff")?;
 Ok(json!({"files":files,"pending":pending,"fingerprint":format!("{:x}",hash.finalize()),"diff":format!("{}{}",String::from_utf8_lossy(&diff.stdout).chars().take(160000).collect::<String>(),new_files)}))
}
async fn git(args:Vec<String>,dir:&std::path::Path)->Result<String,String>{
 let out=tokio::time::timeout(std::time::Duration::from_secs(120),crate::util::git().args(args).current_dir(dir).kill_on_drop(true).output()).await.map_err(|_|"Git не ответил за 120 секунд")?.map_err(|_|"Git недоступен")?;
 if !out.status.success(){return Err("Ошибка Git; рабочие файлы сохранены".into());}Ok(String::from_utf8_lossy(&out.stdout).trim().into())
}
async fn prepare(remote:&str,root:&std::path::Path,work:&std::path::Path,task:&str)->Result<Value,String>{
 let branch=format!("pult/task-{}",task.to_lowercase());
 if !root.exists(){std::fs::create_dir_all(root.parent().ok_or("Нет каталога")?).map_err(|_|"Не создать каталог")?;git(vec!["clone".into(),"--".into(),remote.into(),root.to_string_lossy().into()],root.parent().unwrap()).await?;}
 let actual_remote=git(vec!["remote".into(),"get-url".into(),"origin".into()],root).await?;
 let matches=match(slug(remote),slug(&actual_remote)){(Some(a),Some(b))=>a.eq_ignore_ascii_case(&b),_=>remote==actual_remote};
 if !matches{return Err("Origin отличается от проекта комнаты".into());}
 if !work.exists(){
  git(vec!["fetch".into(),"origin".into()],root).await?;git(vec!["worktree".into(),"prune".into()],root).await?;
  std::fs::create_dir_all(work.parent().ok_or("Нет каталога")?).map_err(|_|"Не создать каталог")?;
  // Ветка могла остаться от прошлого запуска: подключаем её, а не создаём заново.
  let exists=git(vec!["rev-parse".into(),"--verify".into(),"--quiet".into(),format!("refs/heads/{branch}")],root).await.is_ok();
  let path=work.to_string_lossy().to_string();
  git(if exists{vec!["worktree".into(),"add".into(),path,branch.clone()]}else{vec!["worktree".into(),"add".into(),"-b".into(),branch.clone(),path,"FETCH_HEAD".into()]},root).await?;
 }
 if git(vec!["branch".into(),"--show-current".into()],work).await?!=branch{return Err("Ветка worktree отличается от задачи".into());}
 let common=git(vec!["rev-parse".into(),"--path-format=absolute".into(),"--git-common-dir".into()],work).await?;
 let expected=git(vec!["rev-parse".into(),"--path-format=absolute".into(),"--git-common-dir".into()],root).await?;
 if std::fs::canonicalize(common).ok()!=std::fs::canonicalize(expected).ok(){return Err("Worktree принадлежит другому проекту".into());}
 Ok(json!({"cwd":work,"branch":branch}))
}
#[cfg(test)]mod tests{use super::*;
fn task()->Value{json!({"id":uuid::Uuid::new_v4().to_string(),"title":"Task","detail":"","status":"available"})}
fn req(action:&str)->Value{json!({"id":uuid::Uuid::new_v4().to_string(),"action":action})}
#[test]fn claims_are_atomic_idempotent_and_owned(){let mut b=Board::default();let mut add=req("add");add["task"]=task();let tid=add["task"]["id"].clone();assert!(b.apply(&add,"host","host")["error"].is_null());let mut claim=req("claim");claim["ids"]=json!([tid]);claim["name"]=json!("Alice");assert!(b.apply(&claim,"alice","host")["error"].is_null());let rev=b.state.revision;assert!(b.apply(&claim,"alice","host")["error"].is_null());assert_eq!(rev,b.state.revision);claim["id"]=json!(uuid::Uuid::new_v4().to_string());assert!(b.apply(&claim,"bob","host")["error"].is_string());assert_eq!(b.state.tasks[0].owner_id.as_deref(),Some("alice"));}
#[test]fn swift_owner_id_wire_name_is_preserved(){let mut t:Task=serde_json::from_value(task()).unwrap();t.owner_id=Some("peer".into());let wire=serde_json::to_value(t).unwrap();assert_eq!(wire["ownerID"],"peer");assert!(wire.get("ownerId").is_none());}
#[test]fn board_survives_restart_and_replayed_requests_do_not_duplicate_tasks(){
 let root=std::env::temp_dir().join(format!("pult-board-{}",uuid::Uuid::new_v4()));let file=root.join("board.json");
 let mut board=Board::load(&file).unwrap();let mut add=req("add");add["task"]=task();
 assert!(board.apply(&add,"host","host")["error"].is_null());
 crate::util::atomic_write(&file,&serde_json::to_vec(&board).unwrap()).unwrap();
 let mut restored=Board::load(&file).unwrap();let revision=restored.state.revision;
 assert!(restored.apply(&add,"host","host")["error"].is_null());
 assert_eq!(restored.state.revision,revision);assert_eq!(restored.state.tasks.len(),1);
 assert!(restored.apply(&add,"other","host")["error"].is_string());
 std::fs::write(&file,b"broken JSON").unwrap();assert!(Board::load(&file).is_err());
 assert_eq!(std::fs::read(&file).unwrap(),b"broken JSON");std::fs::remove_dir_all(root).unwrap();
}
#[test]fn repository_urls_reject_tokens(){for s in ["https://token@github.com/a/b","https://github.com/a/b?token=x","https://evil.com/a/b","https://github.com/a/../b"]{assert!(slug(s).is_none(),"{s}");}assert_eq!(slug("git@github.com:a/b.git").as_deref(),Some("a/b"));}
}

#[cfg(test)]mod git_tests{
 use super::*;
 #[tokio::test]async fn local_prepare_creates_isolated_worktree_and_refuses_foreign_origin(){
 let dir=std::env::temp_dir().join(format!("pult-team-git-{}",uuid::Uuid::new_v4()));std::fs::create_dir_all(&dir).unwrap();
 let source=dir.join("source");std::fs::create_dir(&source).unwrap();
 for args in [vec!["init"],vec!["config","user.name","Test"],vec!["config","user.email","test@example.test"]]{git(args.into_iter().map(str::to_string).collect(),&source).await.unwrap();}
 std::fs::write(source.join("hello.txt"),"original").unwrap();git(vec!["add".into(),"hello.txt".into()],&source).await.unwrap();git(vec!["commit".into(),"-m".into(),"initial".into()],&source).await.unwrap();
 let bare=dir.join("remote.git");git(vec!["clone".into(),"--bare".into(),source.to_string_lossy().into(),bare.to_string_lossy().into()],&dir).await.unwrap();
 let root=dir.join("project");let work=dir.join("work");let task=uuid::Uuid::new_v4().to_string();let remote=bare.to_str().unwrap();
 prepare(remote,&root,&work,&task).await.unwrap();std::fs::write(work.join("hello.txt"),"changed").unwrap();assert_eq!(std::fs::read_to_string(root.join("hello.txt")).unwrap(),"original");
 prepare(remote,&root,&work,&task).await.unwrap();assert!(prepare("wrong-origin",&root,&work,&task).await.is_err());
 for args in [vec!["config","user.name","Test"],vec!["config","user.email","test@example.test"],vec!["commit","-am","agent"]]{git(args.into_iter().map(str::to_string).collect(),&work).await.unwrap();}
 let seen=review(&work).await.unwrap();assert_eq!(seen["files"],json!(["hello.txt"]));assert_eq!(seen["pending"],json!([]));assert!(seen["diff"].as_str().unwrap().contains("+changed"));
 std::fs::remove_dir_all(&work).unwrap();prepare(remote,&root,&work,&task).await.unwrap();assert_eq!(std::fs::read_to_string(work.join("hello.txt")).unwrap(),"changed");
 std::fs::remove_dir_all(dir).unwrap();
 }
}
