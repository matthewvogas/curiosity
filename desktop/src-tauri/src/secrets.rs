//! Las API keys viven en el almacén seguro del sistema (Llavero de macOS, Administrador de credenciales de
//! Windows, Secret Service en Linux), nunca en archivos. Un servicio propio, distinto del de la versión de
//! SwiftUI: leer las claves de otra app hace que macOS pregunte y bloquee hasta que alguien responda.
//! Los comandos son async para que el almacén nunca trabe la ventana.

const SERVICE: &str = "com.rosvelt.curiosity.desktop";

fn entry(account: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(SERVICE, account).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn secret_get(account: String) -> Option<String> {
    tauri::async_runtime::spawn_blocking(move || entry(&account).ok()?.get_password().ok()).await.ok().flatten()
}

#[tauri::command]
pub async fn secret_set(account: String, value: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || entry(&account)?.set_password(&value).map_err(|e| e.to_string())).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn secret_delete(account: String) {
    let _ = tauri::async_runtime::spawn_blocking(move || {
        if let Ok(e) = entry(&account) {
            let _ = e.delete_credential();
        }
    })
    .await;
}
