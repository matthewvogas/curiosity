//! Curiosity: la parte nativa. Todo lo que el sistema operativo hace distinto en macOS, Windows y Linux
//! vive aquí; la app (React) solo llama a estos comandos.
//!
//!  · files     archivos de la app (Application Support/Curiosity en macOS, %APPDATA%\Curiosity en Windows)
//!  · secrets   API keys en el Llavero de macOS / el Administrador de credenciales de Windows
//!  · bridge    el puente con LeRobot (Python), por líneas JSON
//!  · train     entrenamientos de lerobot-train que siguen aunque se cierre la app
//!  · servo     puertos USB serie y buses de servos (solo lectura)
//!  · scheme    curiosity://: sirve el motor 3D y los robots al visor
//!  · download  descargas de la biblioteca de robots

mod bridge;
mod download;
mod files;
mod python;
mod scheme;
mod secrets;
mod servo;
mod train;

use tauri::Manager;

/// Lo que la página manda a la consola, también en la terminal (para depurar).
#[tauri::command]
fn log_line(level: String, text: String) {
    eprintln!("[web {level}] {text}");
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_window_state::Builder::new().build())
        .manage(bridge::Bridge::default())
        .register_asynchronous_uri_scheme_protocol("curiosity", scheme::handle)
        .setup(|app| {
            files::init(app.handle())?;
            #[cfg(target_os = "windows")]
            if let Some(window) = app.get_webview_window("main") {
                // En Windows la barra de título la dibuja la app (botones propios).
                let _ = window.set_decorations(false);
                let _ = window.set_shadow(true);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            log_line,
            files::app_paths,
            files::fs_read_text,
            files::fs_read_base64,
            files::fs_write_text,
            files::fs_write_base64,
            files::fs_list,
            files::fs_exists,
            files::fs_remove,
            files::fs_tail,
            secrets::secret_get,
            secrets::secret_set,
            secrets::secret_delete,
            python::find_lerobot,
            bridge::bridge_start,
            bridge::bridge_send,
            bridge::bridge_stop,
            bridge::bridge_running,
            train::train_launch,
            train::proc_alive,
            train::proc_interrupt,
            train::train_any_running,
            servo::serial_ports,
            servo::servo_scan,
            download::download_files,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Curiosity");
}
