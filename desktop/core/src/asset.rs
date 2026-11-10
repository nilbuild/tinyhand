//! Hand images: decoding, measuring where the hand, wrist and rod are, and
//! preparing display-sized copies. Port of `HandAsset` in `PointerStyle.swift`.

use tiny_skia::{IntSize, Pixmap};

/// Straight (non-premultiplied) RGBA8 image.
#[derive(Clone)]
pub struct Rgba {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

impl Rgba {
    pub fn alpha(&self, x: u32, y: u32) -> u8 {
        self.data[((y * self.width + x) * 4 + 3) as usize]
    }
}

/// A hand-on-a-stick image plus where its parts are, as fractions of the
/// image size (y measured from the top).
pub struct HandAsset {
    pub image: Rgba,
    /// width / height
    pub aspect: f32,
    pub hand_top: f32,
    /// Fingertip row.
    pub tip: f32,
    pub wrist: f32,
    /// Where the rod ends (the handle starts).
    pub rod_end: f32,
    pub tip_x: f32,
    pub rod_x: f32,
    pub hand_min_x: f32,
    pub hand_max_x: f32,
    /// Horizontal extent of anything visible below the wrist (rod + handle).
    pub rod_min_x: f32,
    pub rod_max_x: f32,
}

#[derive(Debug)]
pub struct AssetError(pub String);

impl std::fmt::Display for AssetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for AssetError {}

pub fn decode_png(bytes: &[u8]) -> Result<Rgba, AssetError> {
    let mut decoder = png::Decoder::new(bytes);
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().map_err(|e| AssetError(format!("not a PNG: {e}")))?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).map_err(|e| AssetError(format!("bad PNG: {e}")))?;
    let (w, h) = (info.width, info.height);
    let src = &buf[..info.buffer_size()];
    let px = (w * h) as usize;
    let mut data = Vec::with_capacity(px * 4);
    match info.color_type {
        png::ColorType::Rgba => data.extend_from_slice(src),
        png::ColorType::Rgb => {
            for c in src.chunks_exact(3) {
                data.extend_from_slice(&[c[0], c[1], c[2], 255]);
            }
        }
        png::ColorType::GrayscaleAlpha => {
            for c in src.chunks_exact(2) {
                data.extend_from_slice(&[c[0], c[0], c[0], c[1]]);
            }
        }
        png::ColorType::Grayscale => {
            for &g in src {
                data.extend_from_slice(&[g, g, g, 255]);
            }
        }
        png::ColorType::Indexed => return Err(AssetError("unexpected indexed PNG".into())),
    }
    Ok(Rgba { width: w, height: h, data })
}

pub fn encode_png(img: &Rgba) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, img.width, img.height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        if let Ok(mut w) = enc.write_header() {
            let _ = w.write_image_data(&img.data);
        }
    }
    out
}

impl HandAsset {
    pub fn from_png(bytes: &[u8]) -> Result<HandAsset, AssetError> {
        let image = decode_png(bytes)?;
        HandAsset::measure(image).ok_or_else(|| AssetError("couldn't find a hand on a stick in that image".into()))
    }

    /// Find the fingertip, wrist and rod from the alpha channel.
    pub fn measure(image: Rgba) -> Option<HandAsset> {
        let (w, h) = (image.width as usize, image.height as usize);
        if w == 0 || h == 0 {
            return None;
        }
        let solid = |x: usize, y: usize| image.data[(y * w + x) * 4 + 3] > 128;
        let counts: Vec<usize> = (0..h).map(|y| (0..w).filter(|&x| solid(x, y)).count()).collect();
        let center = |y: usize| -> f32 {
            let lo = (0..w).find(|&x| solid(x, y));
            let hi = (0..w).rev().find(|&x| solid(x, y));
            match (lo, hi) {
                (Some(lo), Some(hi)) => (lo + hi) as f32 / 2.0 / w as f32,
                _ => 0.5,
            }
        };

        let top = counts.iter().position(|&c| c > 0)?;
        let search_end = h.min(top + (0.45 * h as f64) as usize);
        let max_w = *counts[top..search_end].iter().max()?;
        if max_w == 0 {
            return None;
        }
        let fist = (top..h).find(|&y| counts[y] as f64 > 0.6 * max_w as f64)?;
        let wrist = (fist..h).find(|&y| (counts[y] as f64) < 0.35 * max_w as f64)?;
        let rod_w = counts[(h - 1).min(wrist + h / 50)];
        let last_row = counts.iter().rposition(|&c| c > 0).unwrap_or(h - 1);
        let from = (h - 1).min(wrist + h / 33);
        let rod_end = (from..h).find(|&y| counts[y] as f64 > 1.8 * rod_w as f64).unwrap_or(last_row);

        let (mut min_x, mut max_x) = (w, 0);
        for y in top..wrist {
            for x in 0..w {
                if solid(x, y) {
                    min_x = min_x.min(x);
                    max_x = max_x.max(x);
                }
            }
        }

        // Anything visible below the wrist, at any alpha.
        let (mut rod_lo, mut rod_hi) = (w, 0);
        for y in wrist..h {
            for x in 0..w {
                if image.data[(y * w + x) * 4 + 3] > 0 {
                    rod_lo = rod_lo.min(x);
                    rod_hi = rod_hi.max(x + 1);
                }
            }
        }
        if rod_hi <= rod_lo {
            (rod_lo, rod_hi) = (0, w);
        }

        let fh = h as f32;
        Some(HandAsset {
            rod_min_x: rod_lo as f32 / w as f32,
            rod_max_x: rod_hi as f32 / w as f32,
            aspect: w as f32 / fh,
            hand_top: (top as f32 - 0.004 * fh).max(0.0) / fh,
            tip: top as f32 / fh,
            wrist: wrist as f32 / fh,
            rod_end: rod_end as f32 / fh,
            tip_x: center((h - 1).min(top + h / 200)),
            rod_x: center((wrist + rod_end) / 2),
            hand_min_x: min_x as f32 / w as f32,
            hand_max_x: max_x as f32 / w as f32,
            image,
        })
    }

    /// Fraction of the height where the hand slice ends and the stretched rod
    /// begins: just under the wrist, past the cuff's soft bottom rim.
    pub fn hand_bottom(&self) -> f32 {
        let one_px = 2.0 / self.image.height as f32;
        (self.wrist + 0.006).min(self.rod_end - one_px)
    }

    /// Square crop around the hand, scaled to `px`×`px`, as PNG bytes.
    pub fn thumbnail_png(&self, px: u32) -> Vec<u8> {
        let (w, h) = (self.image.width as f32, self.image.height as f32);
        let hand_w = (self.hand_max_x - self.hand_min_x) * w;
        let hand_h = (self.wrist - self.hand_top) * h;
        let side = hand_w.max(hand_h) * 1.06;
        let cx = (self.hand_min_x + self.hand_max_x) / 2.0 * w;
        let cy = (self.hand_top + self.wrist) / 2.0 * h;
        let x0 = (cx - side / 2.0).max(0.0) as u32;
        let y0 = (cy - side / 2.0).max(0.0) as u32;
        let x1 = ((cx + side / 2.0) as u32).min(self.image.width);
        let y1 = ((cy + side / 2.0) as u32).min(self.image.height);
        let crop = crop(&premultiply(&self.image), x0, y0, x1, y1);
        let scale = px as f32 / crop.width.max(crop.height) as f32;
        let tw = ((crop.width as f32 * scale).round() as u32).clamp(1, px);
        let th = ((crop.height as f32 * scale).round() as u32).clamp(1, px);
        let small = resize_area(&crop, tw, th);
        // Centre on a square transparent canvas.
        let mut out = Rgba { width: px, height: px, data: vec![0; (px * px * 4) as usize] };
        let (ox, oy) = ((px - tw) / 2, (px - th) / 2);
        for y in 0..th {
            let src = (y * tw * 4) as usize;
            let dst = (((oy + y) * px + ox) * 4) as usize;
            out.data[dst..dst + (tw * 4) as usize].copy_from_slice(&small.data[src..src + (tw * 4) as usize]);
        }
        encode_png(&unpremultiply(out))
    }

    /// A copy of the image `height` pixels tall plus a blurred black shadow
    /// of it, ready to draw.
    pub fn display(&self, height: u32, shadow_blur: f32) -> DisplayHand {
        let height = height.clamp(16, self.image.height);
        let width = ((self.image.width as f32 * height as f32 / self.image.height as f32).round() as u32).max(1);
        let pm = premultiply(&self.image);
        let small = if height == self.image.height { pm } else { resize_area(&pm, width, height) };
        // Blur the hand and rod shadows apart: the rod slice is stretched, and
        // any cuff shadow bleeding into it would turn into a long smear.
        let split = ((self.hand_bottom() * height as f32).round() as u32).min(height);
        let shadow_hand = shadow_of(&rows_only(&small, 0, split), shadow_blur);
        let rod = self.rod_profile(&small, split, shadow_blur);
        DisplayHand {
            height,
            pixmap: to_pixmap(small),
            shadow_hand: to_pixmap(shadow_hand),
            rod,
            blur: shadow_blur,
        }
    }

    /// The rod is the same all along its length (it gets stretched anyway),
    /// so it is drawn from one averaged cross-section: a 1-D lookup per pixel
    /// instead of sampling the image.
    fn rod_profile(&self, img: &Rgba, split: u32, blur: f32) -> RodProfile {
        let (w, h) = (img.width as usize, img.height as usize);
        let y0 = (split as usize).min(h - 1);
        let y1 = ((self.rod_end * h as f32) as usize).clamp(y0 + 1, h);
        // Average the middle half of the rod.
        let a = y0 + (y1 - y0) / 4;
        let b = (y0 + (y1 - y0) * 3 / 4).clamp(a + 1, h);
        let x0 = ((self.rod_min_x * w as f32).floor() as usize).saturating_sub(2);
        let x1 = (((self.rod_max_x * w as f32).ceil() as usize) + 2).min(w);
        let colors: Vec<[f32; 4]> = (x0..x1)
            .map(|x| {
                let mut acc = [0f32; 4];
                for y in a..b {
                    let i = (y * w + x) * 4;
                    for c in 0..4 {
                        acc[c] += img.data[i + c] as f32;
                    }
                }
                acc.map(|v| v / (b - a) as f32 / 255.0)
            })
            .collect();
        // Shadow: the cross-section's alpha, blurred, padded by the blur.
        let pad = (blur * 1.5).ceil() as usize;
        let mut alpha = vec![0f32; pad];
        alpha.extend(colors.iter().map(|c| c[3]));
        alpha.extend(std::iter::repeat(0.0).take(pad));
        let r = (blur / 2.0).round() as usize;
        if r > 0 {
            for _ in 0..3 {
                alpha = blur_1d(&alpha, r);
            }
        }
        RodProfile {
            x0: x0 as f32,
            x1: x1 as f32,
            colors,
            shadow_x0: x0 as f32 - pad as f32,
            shadow_x1: x1 as f32 + pad as f32,
            shadow: alpha,
        }
    }
}

pub struct DisplayHand {
    pub height: u32,
    /// Premultiplied RGBA.
    pub pixmap: Pixmap,
    /// Black, blurred; only alpha matters.
    pub shadow_hand: Pixmap,
    pub rod: RodProfile,
    pub blur: f32,
}

/// One averaged row across the rod and its blurred shadow, in display-image
/// pixels. Colours are premultiplied, 0..1; column `i` is centred on `x0 + i + 0.5`.
pub struct RodProfile {
    pub x0: f32,
    pub x1: f32,
    pub colors: Vec<[f32; 4]>,
    pub shadow_x0: f32,
    pub shadow_x1: f32,
    pub shadow: Vec<f32>,
}

fn blur_1d(src: &[f32], r: usize) -> Vec<f32> {
    let n = src.len();
    let norm = 1.0 / (2 * r + 1) as f32;
    (0..n)
        .map(|i| {
            let lo = i.saturating_sub(r);
            let hi = (i + r + 1).min(n);
            src[lo..hi].iter().sum::<f32>() * norm
        })
        .collect()
}

/// Copy of `img` with every row outside `y0..y1` cleared.
fn rows_only(img: &Rgba, y0: u32, y1: u32) -> Rgba {
    let mut out = img.clone();
    let row = (img.width * 4) as usize;
    for (y, chunk) in out.data.chunks_exact_mut(row).enumerate() {
        if (y as u32) < y0 || (y as u32) >= y1 {
            chunk.fill(0);
        }
    }
    out
}

fn to_pixmap(img: Rgba) -> Pixmap {
    let size = IntSize::from_wh(img.width, img.height).expect("non-empty image");
    Pixmap::from_vec(img.data, size).expect("premultiplied RGBA of the right size")
}

fn premultiply(img: &Rgba) -> Rgba {
    let mut data = img.data.clone();
    for p in data.chunks_exact_mut(4) {
        let a = p[3] as u32;
        for c in &mut p[..3] {
            *c = ((*c as u32 * a + 127) / 255) as u8;
        }
    }
    Rgba { width: img.width, height: img.height, data }
}

fn unpremultiply(mut img: Rgba) -> Rgba {
    for p in img.data.chunks_exact_mut(4) {
        let a = p[3] as u32;
        if a > 0 && a < 255 {
            for c in &mut p[..3] {
                *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
    img
}

fn crop(img: &Rgba, x0: u32, y0: u32, x1: u32, y1: u32) -> Rgba {
    let (w, h) = (x1.saturating_sub(x0).max(1), y1.saturating_sub(y0).max(1));
    let mut data = Vec::with_capacity((w * h * 4) as usize);
    for y in y0..y0 + h {
        let start = ((y * img.width + x0) * 4) as usize;
        data.extend_from_slice(&img.data[start..start + (w * 4) as usize]);
    }
    Rgba { width: w, height: h, data }
}

/// Area-averaging downscale (box filter), done as two separable passes.
/// Expects premultiplied pixels so transparent edges don't darken.
pub fn resize_area(img: &Rgba, nw: u32, nh: u32) -> Rgba {
    let horiz = resample_axis(&img.data, img.width as usize, img.height as usize, nw as usize, true);
    let vert = resample_axis(&horiz, nw as usize, img.height as usize, nh as usize, false);
    Rgba { width: nw, height: nh, data: vert }
}

fn resample_axis(src: &[u8], w: usize, h: usize, n: usize, horizontal: bool) -> Vec<u8> {
    let (len, lines) = if horizontal { (w, h) } else { (h, w) };
    let (out_w, out_h) = if horizontal { (n, h) } else { (w, n) };
    let mut out = vec![0u8; out_w * out_h * 4];
    let scale = len as f32 / n as f32;
    // Precompute, for each output sample, the source range and edge weights.
    let spans: Vec<(usize, usize, f32, f32)> = (0..n)
        .map(|i| {
            let s0 = i as f32 * scale;
            let s1 = ((i + 1) as f32 * scale).min(len as f32);
            let a = s0.floor() as usize;
            let b = (s1.ceil() as usize).min(len).max(a + 1);
            let first_w = 1.0 - (s0 - a as f32);
            let last_w = 1.0 - (b as f32 - s1);
            (a, b, first_w, last_w)
        })
        .collect();
    for line in 0..lines {
        for (i, &(a, b, fw, lw)) in spans.iter().enumerate() {
            let mut acc = [0f32; 4];
            let mut total = 0f32;
            for s in a..b {
                let wgt = if b - a == 1 { 1.0 } else if s == a { fw } else if s == b - 1 { lw } else { 1.0 };
                let idx = if horizontal { (line * w + s) * 4 } else { (s * w + line) * 4 };
                for c in 0..4 {
                    acc[c] += src[idx + c] as f32 * wgt;
                }
                total += wgt;
            }
            let o = if horizontal { (line * out_w + i) * 4 } else { (i * out_w + line) * 4 };
            for c in 0..4 {
                out[o + c] = (acc[c] / total.max(1e-6)).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}

/// Black image with the blurred alpha of `img` (three box-blur passes ≈ gaussian).
fn shadow_of(img: &Rgba, blur: f32) -> Rgba {
    let (w, h) = (img.width as usize, img.height as usize);
    let mut alpha: Vec<f32> = img.data.chunks_exact(4).map(|p| p[3] as f32).collect();
    let r = (blur / 2.0).round().max(0.0) as usize;
    if r > 0 {
        let mut tmp = vec![0f32; w * h];
        for _ in 0..3 {
            box_blur(&alpha, &mut tmp, w, h, r, true);
            box_blur(&tmp, &mut alpha, w, h, r, false);
        }
    }
    let mut data = vec![0u8; w * h * 4];
    for (i, a) in alpha.iter().enumerate() {
        data[i * 4 + 3] = a.round().clamp(0.0, 255.0) as u8;
    }
    Rgba { width: img.width, height: img.height, data }
}

fn box_blur(src: &[f32], dst: &mut [f32], w: usize, h: usize, r: usize, horizontal: bool) {
    let (len, lines) = if horizontal { (w, h) } else { (h, w) };
    let at = |line: usize, i: usize| if horizontal { line * w + i } else { i * w + line };
    let norm = 1.0 / (2 * r + 1) as f32;
    for line in 0..lines {
        let mut sum = 0f32;
        for i in 0..=r.min(len - 1) {
            sum += src[at(line, i)];
        }
        for i in 0..len {
            dst[at(line, i)] = sum * norm;
            if i + r + 1 < len {
                sum += src[at(line, i + r + 1)];
            }
            if i >= r {
                sum -= src[at(line, i - r)];
            }
        }
    }
}
