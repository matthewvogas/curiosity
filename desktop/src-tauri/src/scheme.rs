//! curiosity://: sirve el motor 3D y los archivos de los robots al visor de la simulación.
//!  · /app/<ruta>            → recursos incluidos (studio/, robots/, library/)
//!  · /fs/<ruta absoluta>    → archivos del disco (URDF, MJCF y mallas importados o descargados)
//! En macOS y Linux la URL es curiosity://localhost/…; en Windows, http://curiosity.localhost/….

use std::path::PathBuf;

use percent_encoding::percent_decode_str;
use tauri::http::{Request, Response};
use tauri::{UriSchemeContext, UriSchemeResponder, Wry};

use crate::files;

pub fn handle(_ctx: UriSchemeContext<'_, Wry>, request: Request<Vec<u8>>, responder: UriSchemeResponder) {
    let path = percent_decode_str(request.uri().path()).decode_utf8_lossy().into_owned();
    std::thread::spawn(move || responder.respond(serve(&path)));
}

fn serve(path: &str) -> Response<Vec<u8>> {
    let file: Option<PathBuf> = if let Some(rest) = path.strip_prefix("/app/") {
        // Nada fuera de la carpeta de recursos.
        (!rest.split('/').any(|p| p == "..")).then(|| files::resources().join(rest))
    } else if let Some(rest) = path.strip_prefix("/fs/") {
        // Windows: /fs/C:/Users/… ; macOS y Linux: /fs/Users/… (la barra inicial se quitó arriba).
        if rest.len() > 1 && rest.as_bytes()[1] == b':' { Some(PathBuf::from(rest)) } else { Some(PathBuf::from(format!("/{rest}"))) }
    } else {
        None
    };
    let builder = Response::builder().header("Access-Control-Allow-Origin", "*");
    match file.and_then(|f| std::fs::read(&f).ok().map(|data| (f, data))) {
        Some((f, data)) => builder.status(200).header("Content-Type", mime(&f)).body(data).unwrap(),
        None => builder.status(404).body(Vec::new()).unwrap(),
    }
}

fn mime(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref() {
        Some("html") => "text/html",
        Some("js" | "mjs") => "text/javascript",
        Some("json") => "application/json",
        Some("urdf" | "xml" | "dae") => "application/xml",
        Some("wasm") => "application/wasm",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("css") => "text/css",
        _ => "application/octet-stream",
    }
}
