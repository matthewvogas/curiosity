//! El puente con LeRobot (resources/bridge/curiosity_bridge.py), corriendo con el Python de LeRobot.
//! Solo maneja el proceso: cada línea que escribe el puente sale como evento `bridge://line`, y al
//! terminar, `bridge://exit` con el motivo. Los pedidos y respuestas los empareja la app.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};

use tauri::{AppHandle, Emitter, State};

use crate::files;

#[derive(Default)]
pub struct Bridge {
    child: Mutex<Option<Child>>,
    input: Mutex<Option<ChildStdin>>,
}

/// En Windows, sin abrir una ventana de consola para el proceso.
pub fn hide_console(cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    #[cfg(not(windows))]
    let _ = cmd;
}

/// PATH con las carpetas de Homebrew (macOS): ffmpeg y compañía.
pub fn path_env() -> String {
    let path = std::env::var("PATH").unwrap_or_default();
    if cfg!(target_os = "macos") {
        format!("/opt/homebrew/bin:/usr/local/bin:{path}")
    } else {
        path
    }
}

#[tauri::command]
pub fn bridge_running(bridge: State<Bridge>) -> bool {
    let mut child = bridge.child.lock().unwrap();
    matches!(child.as_mut().map(|c| c.try_wait()), Some(Ok(None)))
}

#[tauri::command]
pub fn bridge_start(app: AppHandle, bridge: State<Bridge>, python: String, hub_token: Option<String>) -> Result<(), String> {
    if bridge_running(bridge.clone()) {
        return Ok(());
    }
    if python.is_empty() {
        return Err("Couldn't find LeRobot on this computer. Install it and set its Python in Settings › Connected robots.".into());
    }
    if !std::path::Path::new(&python).exists() {
        return Err(format!("Can't find LeRobot's Python at {python}. Change it in Settings."));
    }
    let script = files::resources().join("bridge").join("curiosity_bridge.py");
    if !script.exists() {
        return Err("The LeRobot bridge is missing from the app.".into());
    }
    let mut cmd = Command::new(&python);
    cmd.arg("-u")
        .arg(&script)
        .current_dir(files::root())
        .env("PATH", path_env())
        .env("PYTHONUNBUFFERED", "1")
        .env("PYTHONIOENCODING", "utf-8")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(token) = hub_token.filter(|t| !t.is_empty()) {
        cmd.env("HF_TOKEN", token);
    }
    hide_console(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("Couldn't start LeRobot: {e}"))?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    *bridge.input.lock().unwrap() = child.stdin.take();
    *bridge.child.lock().unwrap() = Some(child);

    let tail = Arc::new(Mutex::new(Vec::<String>::new()));
    let err_tail = tail.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            let mut t = err_tail.lock().unwrap();
            t.push(line);
            let excess = t.len().saturating_sub(40);
            t.drain(..excess);
        }
    });
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = app.emit("bridge://line", line);
        }
        // stdout cerrado: el puente terminó.
        std::thread::sleep(std::time::Duration::from_millis(150));
        let reason = tail.lock().unwrap().iter().rev().find(|l| l.contains("Error")).cloned().unwrap_or_else(|| "The LeRobot bridge closed.".into());
        let _ = app.emit("bridge://exit", reason);
    });
    Ok(())
}

#[tauri::command]
pub fn bridge_send(bridge: State<Bridge>, line: String) -> Result<(), String> {
    let mut input = bridge.input.lock().unwrap();
    let Some(stdin) = input.as_mut() else { return Err("The LeRobot bridge isn't running.".into()) };
    stdin.write_all(line.as_bytes()).and_then(|_| stdin.write_all(b"\n")).and_then(|_| stdin.flush()).map_err(|_| "The LeRobot bridge isn't running.".to_string())
}

/// Cerrar la entrada: el puente detiene lo que esté corriendo y sale solo.
#[tauri::command]
pub fn bridge_stop(bridge: State<Bridge>) {
    bridge.input.lock().unwrap().take();
    let child = bridge.child.lock().unwrap().take();
    if let Some(mut child) = child {
        std::thread::spawn(move || {
            for _ in 0..100 {
                if matches!(child.try_wait(), Ok(Some(_))) {
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
            let _ = child.kill();
        });
    }
}
