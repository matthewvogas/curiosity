//! Entrenamientos con `lerobot-train`: lanzarlos en segundo plano (siguen aunque se cierre la app),
//! saber si siguen vivos y detenerlos. El avance lo lee la app del registro.

use std::fs::OpenOptions;
use std::io::Write;
use std::process::Command;
#[cfg(windows)]
use std::process::Stdio;

use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, RefreshKind, System};

#[cfg(windows)]
use crate::bridge::hide_console;
use crate::bridge::path_env;
use crate::files;

#[tauri::command]
pub fn train_launch(python: String, args: Vec<String>, log: String, hub_token: Option<String>) -> Result<u32, String> {
    let header = format!("$ lerobot-train {}\n", args.join(" "));
    let mut file = OpenOptions::new().create(true).write(true).truncate(true).open(&log).map_err(|e| e.to_string())?;
    file.write_all(header.as_bytes()).map_err(|e| e.to_string())?;
    let token = hub_token.filter(|t| !t.is_empty());

    #[cfg(unix)]
    {
        let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
        let mut parts = vec![quote(&python), "-m".into(), "lerobot.scripts.lerobot_train".into()];
        parts.extend(args.iter().map(|a| quote(a)));
        // macOS: caffeinate mantiene la Mac despierta mientras entrena.
        let awake = if cfg!(target_os = "macos") { "caffeinate -i -w $pid >/dev/null 2>&1 & " } else { "" };
        let script = format!("{} >> {} 2>&1 & pid=$!; {awake}echo $pid", parts.join(" "), quote(&log));
        let mut cmd = Command::new("/bin/sh");
        cmd.arg("-c").arg(script).current_dir(files::root()).env("PATH", path_env());
        if let Some(t) = &token {
            cmd.env("HF_TOKEN", t);
        }
        let out = cmd.output().map_err(|e| e.to_string())?;
        String::from_utf8_lossy(&out.stdout).trim().parse::<u32>().map_err(|_| "Couldn't start the training.".into())
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        drop(file);
        let out = OpenOptions::new().append(true).open(&log).map_err(|e| e.to_string())?;
        let err = out.try_clone().map_err(|e| e.to_string())?;
        let mut cmd = Command::new(&python);
        cmd.arg("-m").arg("lerobot.scripts.lerobot_train").args(&args).current_dir(files::root()).env("PYTHONIOENCODING", "utf-8").stdin(Stdio::null()).stdout(out).stderr(err);
        if let Some(t) = &token {
            cmd.env("HF_TOKEN", t);
        }
        // Sin consola y en su propio grupo: no muere al cerrar la app.
        cmd.creation_flags(0x0000_0008 | 0x0000_0200 | 0x0800_0000);
        let child = cmd.spawn().map_err(|e| format!("Couldn't start the training: {e}"))?;
        Ok(child.id())
    }
}

fn system() -> System {
    System::new_with_specifics(RefreshKind::nothing().with_processes(ProcessRefreshKind::nothing().with_cmd(sysinfo::UpdateKind::Always)))
}

#[tauri::command]
pub fn proc_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let mut sys = System::new();
    sys.refresh_processes(ProcessesToUpdate::Some(&[Pid::from_u32(pid)]), true);
    sys.process(Pid::from_u32(pid)).is_some_and(|p| !matches!(p.status(), sysinfo::ProcessStatus::Zombie | sysinfo::ProcessStatus::Dead))
}

/// Como Ctrl+C: lo guardado en los checkpoints se conserva.
#[tauri::command]
pub fn proc_interrupt(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(pid as i32, libc::SIGINT);
    }
    #[cfg(windows)]
    {
        let mut cmd = Command::new("taskkill");
        cmd.args(["/PID", &pid.to_string(), "/T", "/F"]).stdout(Stdio::null()).stderr(Stdio::null());
        hide_console(&mut cmd);
        let _ = cmd.status();
    }
}

/// Otro entrenamiento de LeRobot corriendo en esta computadora (de la app o de la terminal).
#[tauri::command]
pub fn train_any_running() -> bool {
    let sys = system();
    sys.processes().values().any(|p| {
        p.cmd().iter().any(|a| {
            let a = a.to_string_lossy();
            a.contains("lerobot_train") || a.contains("lerobot-train")
        })
    })
}
