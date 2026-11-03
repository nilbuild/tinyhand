//! A tiny append-only log in the app's data folder, for bug reports.
//! Windows: %APPDATA%\app.tinyhand.desktop\tinyhand.log

use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

static FILE: OnceLock<Mutex<Option<std::fs::File>>> = OnceLock::new();

pub fn init(dir: PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("tinyhand.log");
    // Keep it small: start over once it passes 1 MB.
    if std::fs::metadata(&path).map(|m| m.len() > 1_000_000).unwrap_or(false) {
        let _ = std::fs::remove_file(&path);
    }
    let file = std::fs::OpenOptions::new().create(true).append(true).open(path).ok();
    let _ = FILE.set(Mutex::new(file));
}

pub fn write(msg: impl AsRef<str>) {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let line = format!("{secs:.3} {}\n", msg.as_ref());
    if cfg!(debug_assertions) {
        eprint!("{line}");
    }
    if let Some(Ok(mut guard)) = FILE.get().map(|m| m.lock()) {
        if let Some(f) = guard.as_mut() {
            let _ = f.write_all(line.as_bytes());
        }
    }
}
