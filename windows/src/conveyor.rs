//! Конвейер: эпик живёт в своей ветке `pult/epic-…`, каждая задача — в своём worktree от неё.
//! Волна закрывается слиянием веток задач в worktree эпика и проверкой; в рабочую ветку пользователя
//! эпик вливается только по его кнопке. Планирует, раздаёт и ревьюит интерфейс (ui/conveyor.js).
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tauri::AppHandle;

fn id(a: &Value, key: &str) -> Result<String, String> {
    let v = a[key].as_str().ok_or(format!("Нет {key}"))?;
    uuid::Uuid::parse_str(v).map_err(|_| format!("Неверный {key}"))?;
    Ok(v.to_ascii_lowercase())
}
fn short(id: &str) -> &str { &id[..8] }
fn dir(epic: &str) -> PathBuf { crate::util::data_dir().join("Conveyor").join(epic) }
fn branch(epic: &str, task: Option<&str>) -> String {
    task.map_or(format!("pult/epic-{}", short(epic)), |t| format!("pult/epic-{}-{}", short(epic), short(t)))
}
/// Папка задачи или, без задачи, worktree самого эпика (туда сливаются волны).
fn folder(a: &Value) -> Result<PathBuf, String> {
    let epic = id(a, "epic")?;
    Ok(if a["task"].is_string() { dir(&epic).join(id(a, "task")?) } else { dir(&epic).join("epic") })
}

async fn git(args: &[&str], cwd: &Path) -> Result<String, String> {
    let out = tokio::time::timeout(std::time::Duration::from_secs(300), crate::util::git().args(args).current_dir(cwd).kill_on_drop(true).output())
        .await.map_err(|_| "Git не ответил за 5 минут")?.map_err(|_| "Git недоступен")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("git {}: {}", args.first().unwrap_or(&""), err.trim().chars().take(600).collect::<String>()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Корень репозитория и признак, что в нём нет незакоммиченных изменений.
async fn root(a: &Value) -> Result<PathBuf, String> {
    let cwd = PathBuf::from(a["cwd"].as_str().ok_or("Нет папки проекта")?);
    let top = git(&["rev-parse", "--show-toplevel"], &cwd).await.map_err(|_| "Папка проекта должна быть Git-репозиторием")?;
    Ok(PathBuf::from(top))
}

/// Есть ли у коммитов автор; если нет — коммитим от имени конвейера, не трогая настройки пользователя.
async fn commit_args(cwd: &Path) -> Vec<&'static str> {
    if git(&["config", "user.email"], cwd).await.map(|s| s.is_empty()).unwrap_or(true) {
        vec!["-c", "user.name=Pult Conveyor", "-c", "user.email=conveyor@pult.local"]
    } else { vec![] }
}

async fn add_worktree(root: &Path, path: &Path, branch: &str, from: &str) -> Result<(), String> {
    if path.join(".git").exists() { return Ok(()); }
    git(&["worktree", "prune"], root).await?;
    std::fs::create_dir_all(path.parent().ok_or("Нет каталога")?).map_err(|_| "Не создать каталог конвейера")?;
    let p = path.to_string_lossy().to_string();
    let exists = git(&["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")], root).await.is_ok();
    if exists { git(&["worktree", "add", &p, branch], root).await?; } else { git(&["worktree", "add", "-b", branch, &p, from], root).await?; }
    Ok(())
}

/// Изменённые файлы worktree (включая новые) без секретов.
async fn changed(cwd: &Path, base: &str) -> Result<Vec<String>, String> {
    git(&["add", "-A", "-N"], cwd).await?;
    let mut files: Vec<String> = git(&["diff", "--name-only", "--no-renames", base], cwd).await?.lines().map(str::to_string).collect();
    files.sort(); files.dedup();
    if let Some(f) = files.iter().find(|f| crate::team::secret_path(f)) { return Err(format!("В изменениях секретный или служебный файл: {f}")); }
    Ok(files)
}

fn shell(command: &str, cwd: &Path) -> tokio::process::Command {
    #[cfg(windows)]
    let mut c = { let mut c = crate::util::command("cmd"); c.raw_arg("/C").raw_arg(command); c };
    #[cfg(not(windows))]
    let mut c = { let mut c = crate::util::command("/bin/sh"); c.args(["-c", command]); c };
    // У приложений из Finder урезанный PATH: добавляем обычные места npm, cargo, brew.
    let h = crate::util::home();
    let extra = [h.join(".local/bin"), h.join(".cargo/bin"), h.join(".npm-global/bin"), "/opt/homebrew/bin".into(), "/usr/local/bin".into()];
    let path = std::env::join_paths(extra.into_iter().chain(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()))).unwrap_or_default();
    c.env("PATH", path).current_dir(cwd).kill_on_drop(true);
    c
}

pub async fn call(_app: &AppHandle, method: &str, a: Value) -> Result<Value, String> { run(method, a).await }

async fn run(method: &str, a: Value) -> Result<Value, String> {
    match method {
        // Ветка и worktree эпика от текущего HEAD проекта.
        "start" => {
            let root = root(&a).await?; let epic = id(&a, "epic")?;
            let base = git(&["rev-parse", "--abbrev-ref", "HEAD"], &root).await?;
            if base == "HEAD" { return Err("Проект в detached HEAD: переключись на ветку".into()); }
            let work = dir(&epic).join("epic");
            add_worktree(&root, &work, &branch(&epic, None), "HEAD").await?;
            Ok(json!({ "base": base, "branch": branch(&epic, None), "cwd": work }))
        }
        // Worktree задачи от текущего состояния эпика: вторая волна видит слитую первую.
        "task" => {
            let root = root(&a).await?; let epic = id(&a, "epic")?; let task = id(&a, "task")?;
            let work = dir(&epic).join(&task);
            add_worktree(&root, &work, &branch(&epic, Some(&task)), &branch(&epic, None)).await?;
            Ok(json!({ "branch": branch(&epic, Some(&task)), "cwd": work }))
        }
        // Что агент сделал относительно ветки эпика — для ревьюеров.
        "diff" => {
            let epic = id(&a, "epic")?; let cwd = folder(&a)?;
            let base = branch(&epic, None);
            let files = changed(&cwd, &base).await?;
            let diff = git(&["diff", "--no-ext-diff", "--no-textconv", "--stat", "--patch", &base], &cwd).await?;
            Ok(json!({ "files": files, "diff": diff.chars().take(120_000).collect::<String>(), "truncated": diff.chars().count() > 120_000 }))
        }
        "commit" => {
            let epic = id(&a, "epic")?; let cwd = folder(&a)?;
            let base = if a["task"].is_string() { branch(&epic, None) } else { "HEAD".into() };
            changed(&cwd, &base).await?;
            git(&["add", "-A"], &cwd).await?;
            if git(&["diff", "--cached", "--quiet"], &cwd).await.is_ok() { return Ok(json!({ "committed": false })); }
            let title = a["title"].as_str().unwrap_or("Задача конвейера").chars().take(120).collect::<String>();
            let mut args = commit_args(&cwd).await; args.extend(["commit", "--no-verify", "-m"]);
            let message = format!("{title}\n\nPult conveyor");
            args.push(&message);
            git(&args, &cwd).await?;
            Ok(json!({ "committed": true }))
        }
        // Слить ветку задачи в эпик. При конфликте откатываем и называем файлы.
        "merge" => {
            let epic = id(&a, "epic")?; let task = id(&a, "task")?; let cwd = dir(&epic).join("epic");
            let title = format!("Конвейер: {}", a["title"].as_str().unwrap_or("задача").chars().take(100).collect::<String>());
            let mut args = commit_args(&cwd).await; args.extend(["merge", "--no-ff", "--no-verify", "-m"]);
            let task_branch = branch(&epic, Some(&task));
            args.extend([title.as_str(), task_branch.as_str()]);
            if let Err(e) = git(&args, &cwd).await {
                let files = git(&["diff", "--name-only", "--diff-filter=U"], &cwd).await.unwrap_or_default();
                let _ = git(&["merge", "--abort"], &cwd).await;
                return Err(if files.is_empty() { e } else { format!("Конфликт слияния: {}", files.lines().collect::<Vec<_>>().join(", ")) });
            }
            Ok(json!({ "merged": true }))
        }
        // Проверка или выкладка в worktree эпика; 15 минут, хвост вывода.
        "run" => {
            let cwd = folder(&a)?; let command = a["command"].as_str().unwrap_or_default().trim();
            if command.is_empty() || command.len() > 2000 { return Err("Нужна команда до 2000 символов".into()); }
            let out = tokio::time::timeout(std::time::Duration::from_secs(900), shell(command, &cwd).output()).await
                .map_err(|_| "Команда не закончилась за 15 минут")?.map_err(|e| format!("Не удалось запустить: {e}"))?;
            let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
            let tail: String = text.chars().rev().take(20_000).collect::<Vec<_>>().into_iter().rev().collect();
            Ok(json!({ "ok": out.status.success(), "code": out.status.code(), "output": tail }))
        }
        // Приёмка: влить эпик в ветку, с которой он стартовал. Только чистое рабочее дерево и только fast-forward/merge без конфликтов.
        "finish" => {
            let root = root(&a).await?; let epic = id(&a, "epic")?;
            let base = a["base"].as_str().ok_or("Нет исходной ветки")?;
            if git(&["rev-parse", "--abbrev-ref", "HEAD"], &root).await? != base { return Err(format!("Переключи проект на ветку {base}")); }
            if !git(&["status", "--porcelain"], &root).await?.is_empty() { return Err("В проекте есть незакоммиченные изменения".into()); }
            let mut args = commit_args(&root).await; args.extend(["merge", "--no-ff", "--no-verify", "--no-edit"]);
            let b = branch(&epic, None); args.push(&b);
            if let Err(e) = git(&args, &root).await { let _ = git(&["merge", "--abort"], &root).await; return Err(e); }
            Ok(json!({ "merged": true }))
        }
        "push" => {
            let epic = id(&a, "epic")?; let cwd = dir(&epic).join("epic");
            git(&["push", "-u", "origin", &branch(&epic, None)], &cwd).await?;
            Ok(json!({ "pushed": branch(&epic, None) }))
        }
        // Убрать worktree эпика; ветки остаются в репозитории.
        "cleanup" => {
            let root = root(&a).await?; let epic = id(&a, "epic")?; let base = dir(&epic);
            if let Ok(entries) = std::fs::read_dir(&base) {
                for e in entries.flatten() { let _ = git(&["worktree", "remove", "--force", &e.path().to_string_lossy()], &root).await; }
            }
            let _ = std::fs::remove_dir_all(&base); let _ = git(&["worktree", "prune"], &root).await;
            Ok(json!({ "removed": true }))
        }
        _ => Err("Неизвестный метод конвейера".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn sh(args: &[&str], cwd: &Path) { assert!(crate::util::git().args(args).current_dir(cwd).status().await.unwrap().success(), "{args:?}"); }
    #[tokio::test]
    async fn waves_merge_into_the_epic_and_conflicts_are_named() {
        let tmp = std::env::temp_dir().join(format!("pult-conveyor-{}", uuid::Uuid::new_v4()));
        let repo = tmp.join("repo"); std::fs::create_dir_all(&repo).unwrap();
        for args in [vec!["init", "-q", "-b", "main"], vec!["config", "user.name", "T"], vec!["config", "user.email", "t@t.t"]] { sh(&args, &repo).await; }
        std::fs::write(repo.join("a.txt"), "1\n").unwrap(); sh(&["add", "."], &repo).await; sh(&["commit", "-qm", "init"], &repo).await;
        let (epic, t1, t2) = (uuid::Uuid::new_v4().to_string(), uuid::Uuid::new_v4().to_string(), uuid::Uuid::new_v4().to_string());
        let base = json!({ "cwd": repo, "epic": epic });
        let started = call_test("start", base.clone()).await.unwrap(); assert_eq!(started["base"], "main");
        let with = |task: &str| { let mut v = base.clone(); v["task"] = json!(task); v["title"] = json!("t"); v };
        for (task, text) in [(&t1, "from one\n"), (&t2, "from two\n")] {
            let w = call_test("task", with(task)).await.unwrap();
            std::fs::write(PathBuf::from(w["cwd"].as_str().unwrap()).join("a.txt"), text).unwrap();
            let d = call_test("diff", with(task)).await.unwrap(); assert_eq!(d["files"], json!(["a.txt"]));
            assert_eq!(call_test("commit", with(task)).await.unwrap()["committed"], true);
        }
        call_test("merge", with(&t1)).await.unwrap();
        let err = call_test("merge", with(&t2)).await.unwrap_err(); assert!(err.contains("Конфликт слияния: a.txt"), "{err}");
        let w = call_test("task", with(&t1)).await.unwrap(); std::fs::write(PathBuf::from(w["cwd"].as_str().unwrap()).join(".env"), "SECRET=1").unwrap();
        assert!(call_test("diff", with(&t1)).await.unwrap_err().contains(".env"));
        let ran = call_test("run", json!({ "epic": epic, "command": "cat a.txt" })).await.unwrap(); assert_eq!(ran["output"], "from one\n");
        call_test("finish", json!({ "cwd": repo, "epic": epic, "base": "main" })).await.unwrap();
        assert_eq!(std::fs::read_to_string(repo.join("a.txt")).unwrap(), "from one\n");
        call_test("cleanup", base).await.unwrap(); assert!(!dir(&epic.to_ascii_lowercase()).exists());
        let _ = std::fs::remove_dir_all(tmp);
    }
    async fn call_test(method: &str, a: Value) -> Result<Value, String> { run(method, a).await }
}
