//! Finding, decoding and caching hand images.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use tinyhand_core::HandAsset;

pub struct Assets {
    dirs: Vec<PathBuf>,
    /// Decoded hands, most recent last. Each is ~6 MB, so keep only two.
    hands: Mutex<Vec<(String, Arc<HandAsset>)>>,
    thumbs: Mutex<HashMap<String, Vec<u8>>>,
}

const KEEP: usize = 2;

impl Assets {
    pub fn new(resource_dir: Option<PathBuf>) -> Self {
        let mut dirs = Vec::new();
        if let Some(r) = resource_dir {
            dirs.push(r.join("hands"));
            dirs.push(r);
        }
        // `cargo run` from the repo.
        dirs.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets"));
        Self { dirs, hands: Mutex::new(Vec::new()), thumbs: Mutex::new(HashMap::new()) }
    }

    fn read(&self, id: &str) -> Option<Vec<u8>> {
        if !tinyhand_core::catalog::hand(id).is_some() {
            return None;
        }
        let name = format!("hand_{id}.png");
        self.dirs.iter().find_map(|d| std::fs::read(d.join(&name)).ok())
    }

    pub fn hand(&self, id: &str) -> Option<Arc<HandAsset>> {
        {
            let mut hands = self.hands.lock().ok()?;
            if let Some(i) = hands.iter().position(|(k, _)| k == id) {
                let hit = hands.remove(i);
                let asset = hit.1.clone();
                hands.push(hit);
                return Some(asset);
            }
        }
        let asset = match HandAsset::from_png(&self.read(id)?) {
            Ok(a) => Arc::new(a),
            Err(e) => {
                crate::log::write(format!("hand {id}: {e}"));
                return None;
            }
        };
        let mut hands = self.hands.lock().ok()?;
        hands.push((id.to_string(), asset.clone()));
        while hands.len() > KEEP {
            hands.remove(0);
        }
        Some(asset)
    }

    /// 128×128 PNG of the hand, for the toolbar and settings.
    pub fn thumbnail(&self, id: &str) -> Option<Vec<u8>> {
        if let Some(hit) = self.thumbs.lock().ok()?.get(id) {
            return Some(hit.clone());
        }
        // Decode without touching the two-hand cache.
        let asset = HandAsset::from_png(&self.read(id)?).ok()?;
        let png = asset.thumbnail_png(128);
        self.thumbs.lock().ok()?.insert(id.to_string(), png.clone());
        Some(png)
    }
}
