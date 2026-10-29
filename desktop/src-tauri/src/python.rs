//! Dónde está instalado LeRobot. Busca en los lugares de costumbre (un .venv dentro de una carpeta
//! «lerobot», o un entorno de conda llamado «lerobot») y acepta el Python que tiene `lerobot-record` al lado.

use std::fs;
use std::path::{Path, PathBuf};

const SKIPPED: [&str; 9] = ["Library", "Applications", "Pictures", "Music", "Movies", "node_modules", "Desktop", "Documents", "Downloads"];

/// bin/ en macOS y Linux; Scripts\ con .exe en Windows.
fn tools(env: &Path) -> (PathBuf, PathBuf) {
    if cfg!(windows) {
        (env.join("Scripts").join("lerobot-record.exe"), env.join("Scripts").join("python.exe"))
    } else {
        (env.join("bin").join("lerobot-record"), env.join("bin").join("python"))
    }
}

/// Recorre carpetas: corre aparte para no trabar la ventana.
#[tauri::command]
pub async fn find_lerobot() -> Option<String> {
    tauri::async_runtime::spawn_blocking(search).await.ok().flatten()
}

fn search() -> Option<String> {
    let home = dirs::home_dir()?;
    let mut envs: Vec<PathBuf> = vec![];
    // Una carpeta «lerobot» hasta tres niveles dentro de la carpeta personal, con su .venv o venv.
    let mut roots = vec![home.clone()];
    for depth in 0..3 {
        let mut next = vec![];
        for dir in &roots {
            let Ok(read) = fs::read_dir(dir) else { continue };
            for e in read.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') || !e.path().is_dir() {
                    continue;
                }
                if name.eq_ignore_ascii_case("lerobot") {
                    envs.push(e.path().join(".venv"));
                    envs.push(e.path().join("venv"));
                }
                if depth < 2 && !SKIPPED.contains(&name.as_str()) {
                    next.push(e.path());
                }
            }
        }
        roots = next;
    }
    // Entornos de conda / miniforge.
    for base in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "opt/miniconda3", "opt/anaconda3"] {
        envs.push(home.join(base).join("envs").join("lerobot"));
    }
    envs.push(PathBuf::from("/opt/homebrew/Caskroom/miniconda/base/envs/lerobot"));
    if let Some(local) = dirs::data_local_dir() {
        envs.push(local.join("miniconda3").join("envs").join("lerobot"));
    }

    envs.iter().map(|e| tools(e)).find(|(record, python)| record.exists() && python.exists()).map(|(_, p)| p.to_string_lossy().into_owned())
}
