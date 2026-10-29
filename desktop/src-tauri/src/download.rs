//! Descarga de los archivos de un robot de la biblioteca (8 a la vez), con el avance en `download://progress`.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use tauri::{AppHandle, Emitter};
use tauri_plugin_http::reqwest;

#[tauri::command]
pub async fn download_files(app: AppHandle, base_url: String, files: Vec<String>, dest: String) -> Result<(), String> {
    let root = PathBuf::from(dest);
    let missing: Vec<String> = files.into_iter().filter(|f| !root.join(f).exists()).collect();
    let total = missing.len().max(1);
    let done = Arc::new(AtomicUsize::new(0));
    let client = reqwest::Client::new();
    let queue = Arc::new(std::sync::Mutex::new(missing));
    let mut workers = vec![];
    for _ in 0..8 {
        let (client, queue, root, done, app, base) = (client.clone(), queue.clone(), root.clone(), done.clone(), app.clone(), base_url.clone());
        workers.push(tauri::async_runtime::spawn(async move {
            loop {
                let next = queue.lock().unwrap().pop();
                let Some(path) = next else { break };
                let res = client.get(format!("{base}/{path}")).send().await.map_err(|_| format!("Couldn't download {path}."))?;
                if !res.status().is_success() {
                    return Err(format!("Couldn't download {path}."));
                }
                let bytes = res.bytes().await.map_err(|_| format!("Couldn't download {path}."))?;
                let dest = root.join(&path);
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                std::fs::write(&dest, &bytes).map_err(|e| e.to_string())?;
                let n = done.fetch_add(1, Ordering::SeqCst) + 1;
                let _ = app.emit("download://progress", n as f64 / total as f64);
            }
            Ok::<(), String>(())
        }));
    }
    for w in workers {
        w.await.map_err(|e| e.to_string())??;
    }
    Ok(())
}
