//! Render one frame to a PNG, for eyeballing the overlay without Windows.
//! cargo run -p tinyhand-core --example render -- <hand id|laser> <out.png> [shadow 0|1]
use std::sync::Arc;
use std::time::{Duration, Instant};
use tinyhand_core::{Engine, HandAsset, IRect, Look, Settings};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let id = args.get(1).map(String::as_str).unwrap_or("lavender");
    let out = args.get(2).map(String::as_str).unwrap_or("frame.png");
    let shadow = args.get(3).map(|s| s != "0").unwrap_or(true);
    let look = if id == "laser" {
        Look::Laser
    } else {
        let path = format!("{}/../../assets/hand_{id}.png", env!("CARGO_MANIFEST_DIR"));
        Look::Hand(Arc::new(HandAsset::from_png(&std::fs::read(path).unwrap()).unwrap()))
    };
    let mut e = Engine::new(look, Settings { shadow, ..Settings::default() });
    let (w, h) = (1280, 800);
    e.set_screen(w, h);
    let t = Instant::now();
    let started = Instant::now();
    e.frame(t, 1.0, (640.0, 360.0));
    let pm = e.render(IRect::new(0, 0, w as i32, h as i32), t + Duration::from_millis(1)).unwrap();
    pm.save_png(out).unwrap();
    eprintln!("rendered in {:?}", started.elapsed());
}
