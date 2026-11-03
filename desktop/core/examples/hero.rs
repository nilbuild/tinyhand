//! Marketing still: a hand on a stick pointing at the end of a hand-drawn
//! loop, rendered by the real engine, transparent background.
//! cargo run -p tinyhand-core --release --example hero -- <hand id> <out.png>
use std::sync::Arc;
use std::time::{Duration, Instant};
use tinyhand_core::{catalog, Engine, HandAsset, IRect, Look, Settings};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let id = args.get(1).map(String::as_str).unwrap_or("lavender");
    let out = args.get(2).map(String::as_str).unwrap_or("hero.png");
    let path = format!("{}/../../assets/hand_{id}.png", env!("CARGO_MANIFEST_DIR"));
    let asset = Arc::new(HandAsset::from_png(&std::fs::read(path).unwrap()).unwrap());
    let (w, h) = (1200u32, 800u32);
    let settings = Settings { size: 0.2, fade_seconds: 0.0, ink: catalog::rgb(catalog::style_ink(id)), ..Settings::default() };
    let mut e = Engine::new(Look::Hand(asset), settings);
    e.set_screen(w, h);
    let t0 = Instant::now();
    let (cx, cy, rx, ry) = (430.0f32, 300.0f32, 190.0f32, 95.0f32);
    let start = (cx + rx, cy - 10.0);
    e.frame(t0, 1.0, start);
    e.mouse_down(true, start);
    // A slightly wobbly loop that overshoots, like a real hand-drawn circle.
    let steps = 90;
    for i in 0..=steps {
        let a = i as f32 / steps as f32 * std::f32::consts::TAU * 1.08;
        let wob = 1.0 + 0.04 * (a * 3.0).sin();
        let p = (cx + rx * wob * a.cos(), cy - 10.0 - ry * wob * a.sin());
        e.frame(t0 + Duration::from_millis(i as u64 * 8), 1.0 / 120.0, p);
    }
    let end = t0 + Duration::from_millis(steps as u64 * 8 + 8);
    e.mouse_up(end);
    let last = (cx + rx * 1.02, cy - 10.0 - ry * 0.45);
    for i in 0..240 {
        e.frame(end + Duration::from_millis(i * 8), 1.0 / 120.0, last);
    }
    let pm = e.render(IRect::new(0, 0, w as i32, h as i32), end + Duration::from_secs(2)).unwrap();
    pm.save_png(out).unwrap();
}
