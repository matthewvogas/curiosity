//! Archivos de la app. La carpeta es la misma que usaba la versión de macOS
//! (~/Library/Application Support/Curiosity), así que robots, chats y tareas se conservan.

use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde::Serialize;
use tauri::{AppHandle, Manager};

static RESOURCES: OnceLock<PathBuf> = OnceLock::new();

pub fn root() -> PathBuf {
    let dir = dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("Curiosity");
    let _ = fs::create_dir_all(&dir);
    dir
}

/// Carpeta de recursos incluidos (motor 3D, robots, biblioteca, puente).
pub fn resources() -> PathBuf {
    RESOURCES.get().cloned().unwrap_or_default()
}

pub fn init(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let dir = app.path().resource_dir()?.join("resources");
    let _ = RESOURCES.set(dir);
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppPaths {
    root: String,
    resources: String,
    pictures: String,
    home: String,
    platform: &'static str,
    separator: &'static str,
    /// La ventana tiene el blur del sistema detrás (macOS siempre; Windows 11 con Mica; Windows 10 y Linux no).
    translucent: bool,
}

fn translucent() -> bool {
    if cfg!(target_os = "macos") {
        return true;
    }
    if cfg!(windows) {
        // Mica existe desde Windows 11 (compilación 22000).
        let build = sysinfo::System::kernel_version().and_then(|v| v.split('.').nth(2).and_then(|b| b.parse::<u32>().ok()).or_else(|| v.parse().ok()));
        return build.is_some_and(|b| b >= 22000);
    }
    false
}

fn text(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

#[tauri::command]
pub fn app_paths() -> AppPaths {
    let home = dirs::home_dir().unwrap_or_default();
    AppPaths {
        root: text(&root()),
        resources: text(&resources()),
        pictures: text(&dirs::picture_dir().unwrap_or_else(|| home.join("Pictures"))),
        home: text(&home),
        platform: std::env::consts::OS,
        separator: std::path::MAIN_SEPARATOR_STR,
        translucent: translucent(),
    }
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[tauri::command]
pub fn fs_read_text(path: String) -> Result<Option<String>, String> {
    match fs::read_to_string(&path) {
        Ok(t) => Ok(Some(t)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(err(e)),
    }
}

#[tauri::command]
pub fn fs_read_base64(path: String) -> Result<Option<String>, String> {
    match fs::read(&path) {
        Ok(bytes) => Ok(Some(base64(&bytes))),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(err(e)),
    }
}

/// Escribe de forma atómica (archivo temporal + renombrar) y crea las carpetas que falten.
fn write_atomic(path: &str, bytes: &[u8]) -> Result<(), String> {
    let path = PathBuf::from(path);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(err)?;
    }
    let tmp = path.with_extension("curiosity-tmp");
    fs::write(&tmp, bytes).map_err(err)?;
    fs::rename(&tmp, &path).map_err(err)
}

#[tauri::command]
pub fn fs_write_text(path: String, contents: String) -> Result<(), String> {
    write_atomic(&path, contents.as_bytes())
}

#[tauri::command]
pub fn fs_write_base64(path: String, data: String) -> Result<(), String> {
    write_atomic(&path, &unbase64(&data).ok_or("Invalid image data.")?)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    name: String,
    path: String,
    is_dir: bool,
    modified: f64,
}

#[tauri::command]
pub fn fs_list(path: String) -> Vec<Entry> {
    let Ok(read) = fs::read_dir(&path) else { return vec![] };
    let mut out: Vec<Entry> = read
        .flatten()
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .map(|e| {
            let meta = e.metadata().ok();
            let modified = meta
                .as_ref()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            Entry {
                name: e.file_name().to_string_lossy().into_owned(),
                path: text(&e.path()),
                is_dir: meta.map(|m| m.is_dir()).unwrap_or(false),
                modified,
            }
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

#[tauri::command]
pub fn fs_exists(path: String) -> bool {
    Path::new(&path).exists()
}

#[tauri::command]
pub fn fs_remove(path: String) -> Result<(), String> {
    let p = Path::new(&path);
    if p.is_dir() {
        fs::remove_dir_all(p).map_err(err)
    } else if p.exists() {
        fs::remove_file(p).map_err(err)
    } else {
        Ok(())
    }
}

/// Los últimos `size` bytes de un archivo de texto (registros de entrenamiento).
#[tauri::command]
pub fn fs_tail(path: String, size: u64) -> Option<String> {
    let mut f = fs::File::open(&path).ok()?;
    let end = f.seek(SeekFrom::End(0)).ok()?;
    f.seek(SeekFrom::Start(end.saturating_sub(size))).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

// Base64 sin dependencias: solo se usa para imágenes chicas.
const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn unbase64(text: &str) -> Option<Vec<u8>> {
    let text = text.split_once(',').map(|(_, b)| b).unwrap_or(text);
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0);
    for c in text.bytes().filter(|c| !c.is_ascii_whitespace() && *c != b'=') {
        let v = B64.iter().position(|&b| b == c)? as u32;
        acc = acc << 6 | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits & 0xFF) as u8);
        }
    }
    Some(out)
}
