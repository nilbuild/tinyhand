//! Render a scripted moment of the overlay (hand, ink, laser) to a transparent
//! PNG, using the real engine. Used by marketing/make_screens.py.
//!
//! Script on stdin, one command per line:
//!   screen W H            monitor size (default 1600 1000)
//!   hand ID | laser       pointer style
//!   size F                hand length as a fraction of the height
//!   ink RRGGBB            ink colour (default: the style's)
//!   move X Y              move there and let the stick settle
//!   draw X Y X Y ...      press, drag through the points, release
//!   loop CX CY RX RY      press, draw a hand-drawn ellipse, release
//!   press                 hold the button down (the "tap" squash)
//!   render OUT.png        write the frame
use std::io::Read;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tinyhand_core::{catalog, Engine, HandAsset, IRect, Look, Settings};

struct Sim {
    e: Engine,
    t: Instant,
    cursor: (f32, f32),
}

impl Sim {
    fn tick(&mut self, p: (f32, f32)) {
        self.t += Duration::from_micros(8333);
        self.cursor = p;
        self.e.frame(self.t, 1.0 / 120.0, p);
    }

    fn glide(&mut self, to: (f32, f32)) {
        let from = self.cursor;
        let d = (to.0 - from.0).hypot(to.1 - from.1);
        let n = (d / 5.0).ceil().max(1.0) as usize;
        for i in 1..=n {
            let k = i as f32 / n as f32;
            self.tick((from.0 + (to.0 - from.0) * k, from.1 + (to.1 - from.1) * k));
        }
    }

    fn settle(&mut self) {
        for _ in 0..360 {
            let p = self.cursor;
            self.tick(p);
        }
    }

    fn stroke(&mut self, pts: &[(f32, f32)]) {
        let Some(&first) = pts.first() else { return };
        self.glide(first);
        self.e.mouse_down(true, first);
        for &p in &pts[1..] {
            self.glide(p);
        }
        self.e.mouse_up(self.t);
    }
}

fn main() {
    let mut script = String::new();
    std::io::stdin().read_to_string(&mut script).unwrap();
    let (mut w, mut h) = (1600u32, 1000u32);
    let mut style = "lavender".to_string();
    let mut size = 0.13f32;
    let mut ink: Option<u32> = None;
    let mut sim: Option<Sim> = None;

    for line in script.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let mut it = line.split_whitespace();
        let cmd = it.next().unwrap();
        let nums: Vec<f32> = line.split_whitespace().skip(1).filter_map(|s| s.parse().ok()).collect();
        // Settings commands must come before the first action.
        match cmd {
            "screen" => {
                (w, h) = (nums[0] as u32, nums[1] as u32);
                continue;
            }
            "hand" => {
                style = it.next().unwrap().to_string();
                continue;
            }
            "laser" => {
                style = catalog::LASER.to_string();
                continue;
            }
            "size" => {
                size = nums[0];
                continue;
            }
            "ink" => {
                ink = Some(u32::from_str_radix(it.next().unwrap(), 16).unwrap());
                continue;
            }
            _ => {}
        }
        let s = sim.get_or_insert_with(|| {
            let look = if style == catalog::LASER {
                Look::Laser
            } else {
                let path = format!("{}/../../assets/hand_{style}.png", env!("CARGO_MANIFEST_DIR"));
                Look::Hand(Arc::new(HandAsset::from_png(&std::fs::read(path).unwrap()).unwrap()))
            };
            let settings = Settings {
                size,
                fade_seconds: 0.0,
                ink: catalog::rgb(ink.unwrap_or_else(|| catalog::style_ink(&style))),
                ..Settings::default()
            };
            let mut e = Engine::new(look, settings);
            e.set_screen(w, h);
            let t = Instant::now();
            let start = (w as f32 * 0.5, h as f32 * 0.5);
            e.frame(t, 1.0, start);
            Sim { e, t, cursor: start }
        });
        match cmd {
            "move" => {
                s.glide((nums[0], nums[1]));
                s.settle();
            }
            "draw" => {
                let pts: Vec<(f32, f32)> = nums.chunks_exact(2).map(|c| (c[0], c[1])).collect();
                s.stroke(&pts);
            }
            "loop" => {
                let (cx, cy, rx, ry) = (nums[0], nums[1], nums[2], nums[3]);
                let pts: Vec<(f32, f32)> = (0..=72)
                    .map(|i| {
                        let a = i as f32 / 72.0 * std::f32::consts::TAU * 1.1 - 0.4;
                        let wob = 1.0 + 0.035 * (a * 3.0).sin();
                        (cx + rx * wob * a.cos(), cy - ry * wob * a.sin())
                    })
                    .collect();
                s.stroke(&pts);
            }
            "press" => {
                let p = s.cursor;
                s.e.mouse_down(true, p);
                for _ in 0..30 {
                    s.tick(p);
                }
            }
            "render" => {
                let out = it.next().unwrap();
                let pm = s.e.render(IRect::new(0, 0, w as i32, h as i32), s.t).unwrap();
                pm.save_png(out).unwrap();
            }
            other => panic!("unknown command {other}"),
        }
    }
}
