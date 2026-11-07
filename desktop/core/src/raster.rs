//! A tiny purpose-built rasteriser for the hand and rod.
//!
//! Each slice is an image rectangle under an affine map. For every screen row
//! we solve for the exact span of pixels the rotated rectangle covers and only
//! visit those, mapping each pixel centre back into the image. Cost scales
//! with the pixels actually drawn, not with the (large, mostly empty)
//! bounding box of a diagonal stick.
//!
//! Destination is premultiplied RGBA8 (tiny-skia's layout), composited
//! source-over.

use crate::asset::RodProfile;
use crate::geom::Affine;

pub struct Target<'a> {
    pub data: &'a mut [u8],
    pub width: usize,
    pub height: usize,
    /// Screen position of the buffer's top-left pixel.
    pub origin: (f32, f32),
}

/// Inverse of an affine map, or `None` if it's degenerate.
fn invert(t: Affine) -> Option<Affine> {
    let det = t.a * t.e - t.b * t.d;
    if det.abs() < 1e-12 {
        return None;
    }
    let inv = 1.0 / det;
    let (a, b, d, e) = (t.e * inv, -t.b * inv, -t.d * inv, t.a * inv);
    Some(Affine::new(a, b, -(a * t.c + b * t.f), d, e, -(d * t.c + e * t.f)))
}

/// Visit every target pixel whose centre maps (through the inverse of `t`)
/// into `src` = `[x0, y0, x1, y1]`, calling `shade(u, v, pixel)`.
fn spans(target: &mut Target, t: Affine, src: [f32; 4], mut shade: impl FnMut(f32, f32, &mut [u8])) {
    let Some(inv) = invert(t) else { return };
    let [x0, y0, x1, y1] = src;
    let (ox, oy) = target.origin;
    let width = target.width;
    for row in 0..target.height {
        let sy = oy + row as f32 + 0.5;
        // u = inv.a·sx + inv.b·sy + inv.c, v = inv.d·sx + inv.e·sy + inv.f,
        // with sx = ox + col + 0.5. Solve both ranges for col.
        let mut lo = 0f32;
        let mut hi = width as f32;
        for (k, c, min, max) in [
            (inv.a, inv.b * sy + inv.c + inv.a * (ox + 0.5), x0, x1),
            (inv.d, inv.e * sy + inv.f + inv.d * (ox + 0.5), y0, y1),
        ] {
            if k.abs() < 1e-9 {
                if c < min || c > max {
                    hi = -1.0;
                }
            } else {
                let (p, q) = ((min - c) / k, (max - c) / k);
                lo = lo.max(p.min(q));
                hi = hi.min(p.max(q));
            }
        }
        if hi < lo {
            continue;
        }
        let start = lo.ceil().max(0.0) as usize;
        let end = (hi.floor() as usize + 1).min(width);
        if start >= end {
            continue;
        }
        let sx = ox + start as f32 + 0.5;
        let mut u = inv.a * sx + inv.b * sy + inv.c;
        let mut v = inv.d * sx + inv.e * sy + inv.f;
        let line = &mut target.data[row * width * 4..(row + 1) * width * 4];
        for px in line[start * 4..end * 4].chunks_exact_mut(4) {
            shade(u, v, px);
            u += inv.a;
            v += inv.d;
        }
    }
}

#[inline(always)]
fn over(px: &mut [u8], c: [f32; 4]) {
    // c is premultiplied 0..255.
    if c[3] <= 0.0 {
        return;
    }
    let k = 1.0 - c[3] / 255.0;
    for i in 0..4 {
        px[i] = (c[i] + px[i] as f32 * k + 0.5).min(255.0) as u8;
    }
}

/// Bilinear sample of a premultiplied RGBA8 image at image coords (u, v),
/// transparent outside.
#[inline(always)]
fn bilinear(img: &[u8], w: usize, h: usize, u: f32, v: f32) -> [f32; 4] {
    let fx = u - 0.5;
    let fy = v - 0.5;
    let x0 = fx.floor();
    let y0 = fy.floor();
    let tx = fx - x0;
    let ty = fy - y0;
    let (x0, y0) = (x0 as isize, y0 as isize);
    let fetch = |x: isize, y: isize| -> [f32; 4] {
        if x < 0 || y < 0 || x >= w as isize || y >= h as isize {
            return [0.0; 4];
        }
        let i = (y as usize * w + x as usize) * 4;
        [img[i] as f32, img[i + 1] as f32, img[i + 2] as f32, img[i + 3] as f32]
    };
    let (a, b, c, d) = (fetch(x0, y0), fetch(x0 + 1, y0), fetch(x0, y0 + 1), fetch(x0 + 1, y0 + 1));
    let mut out = [0f32; 4];
    for i in 0..4 {
        let top = a[i] + (b[i] - a[i]) * tx;
        let bot = c[i] + (d[i] - c[i]) * tx;
        out[i] = top + (bot - top) * ty;
    }
    out
}

/// Draw an image slice. `opacity` scales the whole thing.
pub fn image(target: &mut Target, img: &tiny_skia::Pixmap, t: Affine, src: [f32; 4], opacity: f32) {
    let (w, h) = (img.width() as usize, img.height() as usize);
    let data = img.data();
    spans(target, t, src, |u, v, px| {
        let mut c = bilinear(data, w, h, u, v);
        if opacity < 1.0 {
            c = c.map(|x| x * opacity);
        }
        over(px, c);
    });
}

/// Draw a black shadow from an image's alpha.
pub fn shadow_image(target: &mut Target, img: &tiny_skia::Pixmap, t: Affine, src: [f32; 4], opacity: f32) {
    let (w, h) = (img.width() as usize, img.height() as usize);
    let data = img.data();
    spans(target, t, src, |u, v, px| {
        let a = bilinear(data, w, h, u, v)[3] * opacity;
        over(px, [0.0, 0.0, 0.0, a]);
    });
}

#[inline(always)]
fn lerp_column<T: Copy>(cols: &[T], x0: f32, u: f32, zero: T, mix: impl Fn(T, T, f32) -> T) -> T {
    let f = u - x0 - 0.5;
    let i = f.floor();
    let t = f - i;
    let i = i as isize;
    let at = |k: isize| if k < 0 || k >= cols.len() as isize { zero } else { cols[k as usize] };
    mix(at(i), at(i + 1), t)
}

/// Draw the rod: its averaged cross-section extruded along the slice.
pub fn rod(target: &mut Target, p: &RodProfile, t: Affine, src: [f32; 4]) {
    spans(target, t, src, |u, _v, px| {
        let c = lerp_column(&p.colors, p.x0, u, [0.0; 4], |a, b, t| {
            [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t]
        });
        over(px, c.map(|x| x * 255.0));
    });
}

pub fn rod_shadow(target: &mut Target, p: &RodProfile, t: Affine, src: [f32; 4], opacity: f32) {
    spans(target, t, src, |u, _v, px| {
        let a = lerp_column(&p.shadow, p.shadow_x0, u, 0.0, |a, b, t| a + (b - a) * t);
        over(px, [0.0, 0.0, 0.0, a * 255.0 * opacity]);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inverse_round_trips() {
        let t = Affine::new(0.8, -0.6, 100.0, 0.6, 0.8, -40.0);
        let inv = invert(t).unwrap();
        let (x, y) = t.apply(12.0, 34.0);
        let (u, v) = inv.apply(x, y);
        assert!((u - 12.0).abs() < 1e-3 && (v - 34.0).abs() < 1e-3);
    }

    #[test]
    fn spans_cover_exactly_the_rect() {
        // A 10×4 rect, scaled by 2 and moved to (5, 3): covers x 5..25, y 3..11.
        let mut buf = vec![0u8; 40 * 20 * 4];
        let mut tgt = Target { data: &mut buf, width: 40, height: 20, origin: (0.0, 0.0) };
        let t = Affine::new(2.0, 0.0, 5.0, 0.0, 2.0, 3.0);
        let mut n = 0;
        spans(&mut tgt, t, [0.0, 0.0, 10.0, 4.0], |_, _, px| {
            px[3] = 255;
            n += 1;
        });
        assert_eq!(n, 20 * 8);
        assert_eq!(buf[((3 * 40) + 5) * 4 + 3], 255);
        assert_eq!(buf[((2 * 40) + 5) * 4 + 3], 0);
        assert_eq!(buf[((3 * 40) + 25) * 4 + 3], 0);
    }
}
