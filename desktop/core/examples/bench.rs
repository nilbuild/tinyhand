//! Time a moving-cursor frame (dirty rect only), as the overlay would at 1080p and 4K.
use std::sync::Arc;
use std::time::{Duration, Instant};
use tinyhand_core::{Engine, HandAsset, Look, Settings};

fn main() {
    let path = format!("{}/../../assets/hand_lavender.png", env!("CARGO_MANIFEST_DIR"));
    let asset = Arc::new(HandAsset::from_png(&std::fs::read(path).unwrap()).unwrap());
    for (w, h) in [(1920u32, 1080u32), (3840, 2160)] {
        let shadow = std::env::var("SHADOW").map(|v| v != "0").unwrap_or(true);
        let mut e = Engine::new(Look::Hand(asset.clone()), Settings { shadow, ..Settings::default() });
        e.set_screen(w, h);
        let mut buf = vec![0u8; (w * h * 4) as usize];
        let t0 = Instant::now();
        let mut total = Duration::ZERO;
        let mut px = 0u64;
        let frames = 240;
        for i in 0..frames {
            let t = t0 + Duration::from_millis(i * 8);
            let cur = (w as f32 * 0.2 + i as f32 * 4.0, h as f32 * 0.4 + (i as f32 * 0.05).sin() * 200.0);
            let start = Instant::now();
            if let Some(d) = e.frame(t, 1.0 / 120.0, cur) {
                e.render_bgra(d, t, &mut buf, (w * 4) as usize);
                if i > 0 {
                    px += (d.width() * d.height()) as u64;
                }
            }
            if i > 0 {
                total += start.elapsed();
            }
        }
        println!("{w}x{h}: {:.2} ms/frame, {:.0} kpx dirty/frame", total.as_secs_f64() * 1000.0 / (frames - 1) as f64, px as f64 / 1000.0 / (frames - 1) as f64);
    }
}
