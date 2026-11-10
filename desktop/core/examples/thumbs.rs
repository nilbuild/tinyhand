//! Write 128px thumbnails for every built-in hand (for UI mock-ups).
//! cargo run -p tinyhand-core --release --example thumbs -- <out dir> [px] [id,id,...]
fn main() {
    let mut args = std::env::args().skip(1);
    let out = args.next().expect("out dir");
    let px: u32 = args.next().and_then(|s| s.parse().ok()).unwrap_or(128);
    let only: Option<Vec<String>> = args.next().map(|s| s.split(',').map(str::to_string).collect());
    for h in tinyhand_core::catalog::HANDS {
        if only.as_ref().is_some_and(|o| !o.iter().any(|x| x == h.id)) {
            continue;
        }
        let path = format!("{}/../../assets/hand_{}.png", env!("CARGO_MANIFEST_DIR"), h.id);
        let asset = tinyhand_core::HandAsset::from_png(&std::fs::read(path).unwrap()).unwrap();
        std::fs::write(format!("{out}/{}.png", h.id), asset.thumbnail_png(px)).unwrap();
    }
}
