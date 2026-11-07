//! The hand-on-a-stick pose: the stick is held from below the bottom edge of
//! the screen, off to the right, and the fingertip always lands exactly on
//! the cursor. Port of `ArmView.aim(cursor:)`.

use crate::asset::HandAsset;
use crate::geom::Affine;

const GRIP_LEAN: f32 = 0.30;
const GRIP_DEPTH: f32 = 0.12;
const GRIP_FOLLOW: f32 = 0.08;
const PRESS_DECAY: f32 = 0.18;
const LIFT: f32 = 0.06;
const MIN_ROD: f32 = 0.05;
/// The macOS app runs its physics at 120 ticks a second; scale to real time.
const TICK_HZ: f32 = 120.0;

#[derive(Default)]
pub struct Arm {
    grip_x: Option<f32>,
    grip_target: Option<f32>,
    pub press: f32,
    pub held: bool,
}

/// Where to draw the two image slices, in screen pixels (y down).
pub struct HandPose {
    /// Display-image pixels → screen, for the hand slice.
    pub hand: Affine,
    /// Display-image pixels → screen, for the (stretched) rod slice.
    pub rod: Affine,
    /// `[x0, y0, x1, y1]` of each slice in display-image pixels.
    pub hand_src: [f32; 4],
    pub rod_src: [f32; 4],
    pub shadow_offset: (f32, f32),
    pub shadow_alpha: f32,
    /// Rounded pose, to skip redraws when nothing visible changed.
    pub key: [i32; 6],
}

pub struct LaserPose {
    pub x: f32,
    pub y: f32,
    pub r: f32,
    pub press: f32,
    pub key: [i32; 6],
}

fn ease(factor: f32, dt: f32) -> f32 {
    1.0 - (1.0 - factor).powf(dt * TICK_HZ)
}

impl Arm {
    pub fn press(&mut self) {
        self.press = 1.0;
    }

    pub fn step(&mut self, dt: f32, cursor_x: f32, screen_w: f32) {
        let target = (cursor_x + GRIP_LEAN * screen_w).clamp(screen_w * 0.15, screen_w * 1.05);
        self.grip_x = Some(match self.grip_x {
            Some(g) => g + (target - g) * ease(GRIP_FOLLOW, dt),
            None => target,
        });
        self.grip_target = Some(target);
        if !self.held {
            self.press *= 1.0 - ease(PRESS_DECAY, dt);
            if self.press < 0.001 {
                self.press = 0.0;
            }
        }
    }

    pub fn reset(&mut self) {
        *self = Arm::default();
    }

    pub fn is_settling(&self) -> bool {
        if self.press > 0.002 {
            return true;
        }
        match (self.grip_x, self.grip_target) {
            (Some(g), Some(t)) => (t - g).abs() > 0.5,
            _ => false,
        }
    }

    /// `size` is the hand length as a fraction of the screen height;
    /// `disp_w`/`disp_h` are the pixel size of the display copy being drawn.
    #[allow(clippy::too_many_arguments)]
    pub fn hand_pose(
        &self,
        cursor: (f32, f32),
        screen: (f32, f32),
        a: &HandAsset,
        size: f32,
        shadow: bool,
        disp_w: f32,
        disp_h: f32,
    ) -> HandPose {
        let (w, h) = screen;
        let gx = self.grip_x.unwrap_or(cursor.0 + GRIP_LEAN * w);
        // Work in y-up coordinates like the macOS code, flip at the end.
        let gy = -GRIP_DEPTH * h;
        let (cx, cy) = (cursor.0, h - cursor.1);
        let (dx, dy) = (cx - gx, cy - gy);
        let reach = dx.hypot(dy);
        let aim = dy.atan2(dx);

        let hand_px = size * h * (1.0 - 0.06 * self.press);
        let s = hand_px / (a.wrist - a.hand_top).max(1e-3);
        let width_px = s * a.aspect;
        let hand_tip = (a.wrist - a.tip) * s;
        let tip_off_x = (a.tip_x - a.rod_x) * width_px;

        let along = (reach * reach - tip_off_x * tip_off_x).max(0.0).sqrt();
        let rod_len = (along - hand_tip).max(MIN_ROD * h);
        let tip_angle = (rod_len + hand_tip).atan2(tip_off_x);
        let rotation = aim - tip_angle;

        let kx = width_px / disp_w;
        let ky = s / disp_h;
        // The cuff's soft bottom rim sits just under the detected wrist row.
        // Draw it unstretched as part of the hand slice; the stretched rod
        // starts below it and tucks 1px under.
        let hand_bottom = a.hand_bottom() * disp_h;
        let rod_bottom = a.rod_end * disp_h;
        let rim = (hand_bottom - a.wrist * disp_h) * ky;
        let kr = (rod_len - rim + 1.0).max(1.0) / (rod_bottom - hand_bottom).max(1.0);
        let left = -a.rod_x * width_px;
        // Image pixels → stick-local (origin at the grip, +y along the stick).
        let hand_local = Affine::new(kx, 0.0, left, 0.0, -ky, rod_len + a.wrist * s);
        let rod_local = Affine::new(kx, 0.0, left, 0.0, -kr, rod_bottom * kr);
        let (sin, cos) = rotation.sin_cos();
        let world = Affine::new(cos, -sin, gx, sin, cos, gy);
        let flip = Affine::new(1.0, 0.0, 0.0, 0.0, -1.0, h);

        let lift = LIFT * h * (1.0 - 0.8 * self.press);
        let r = |v: f32, m: f32| (v * m).round() as i32;
        HandPose {
            hand: hand_local.then(world).then(flip),
            rod: rod_local.then(world).then(flip),
            // Trim slices to their content (+2px for filtering) so the
            // rasteriser doesn't walk acres of transparent pixels.
            hand_src: [
                (a.hand_min_x.min(a.rod_min_x) * disp_w - 2.0).max(0.0),
                a.hand_top * disp_h,
                (a.hand_max_x.max(a.rod_max_x) * disp_w + 2.0).min(disp_w),
                hand_bottom,
            ],
            rod_src: [(a.rod_min_x * disp_w - 2.0).max(0.0), hand_bottom, (a.rod_max_x * disp_w + 2.0).min(disp_w), rod_bottom],
            shadow_offset: (0.6 * lift, lift),
            shadow_alpha: if shadow { 0.26 + 0.02 * self.press } else { 0.0 },
            key: [r(rotation, 2000.0), r(rod_len, 4.0), r(hand_px, 4.0), r(gx, 4.0), r(lift, 4.0), r(self.press, 200.0)],
        }
    }

    pub fn laser_pose(&self, cursor: (f32, f32), screen_h: f32, size: f32) -> LaserPose {
        let r = (screen_h * 0.0038 * size / 0.13).max(4.0) * (1.0 + 0.2 * self.press);
        let k = |v: f32| (v * 4.0).round() as i32;
        LaserPose {
            x: cursor.0,
            y: cursor.1,
            r,
            press: self.press,
            key: [k(cursor.0), k(cursor.1), k(r), (self.press * 200.0).round() as i32, 0, 0],
        }
    }
}
