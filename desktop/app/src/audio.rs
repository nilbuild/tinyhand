//! Tap sounds through a long-lived output stream (cpal: WASAPI on Windows,
//! CoreAudio on macOS). Port of `TapSound.swift`.
//!
//! The taps are 50–140 ms long. Opening the audio device per sound (as
//! `PlaySound` does) loses them while a sleeping device wakes up, which is
//! worse on virtual machines. So, like the macOS app's AVAudioEngine, the
//! stream stays open (playing silence) while the pointer is on and for 30 s
//! after the last sound; taps are mixed straight into it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};

const IDLE_CLOSE: Duration = Duration::from_secs(30);

#[cfg_attr(not(windows), allow(dead_code))]
enum Cmd {
    Play(&'static [u8]),
    /// Keep the stream open (pointer on) or let it close after a while.
    Hold(bool),
}

static TX: OnceLock<Sender<Cmd>> = OnceLock::new();

fn sender() -> &'static Sender<Cmd> {
    TX.get_or_init(|| {
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("tinyhand-audio".into())
            .spawn(move || {
                let mut player = Player::default();
                loop {
                    match rx.recv_timeout(Duration::from_secs(1)) {
                        Ok(Cmd::Play(wav)) => player.play(wav),
                        Ok(Cmd::Hold(on)) => player.hold(on),
                        Err(RecvTimeoutError::Timeout) => {}
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                    player.maybe_close();
                }
            })
            .expect("audio thread");
        tx
    })
}

/// Play a WAV (PCM 16-bit), cutting off the previous tap.
pub fn play(wav: &'static [u8]) {
    let _ = sender().send(Cmd::Play(wav));
}

/// While held, the device stays awake so the first tap isn't lost.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn hold(on: bool) {
    let _ = sender().send(Cmd::Hold(on));
}

/// What the audio callback reads: the current tap and how far into it we are.
#[derive(Default)]
struct Voice {
    samples: Option<Arc<[f32]>>,
    pos: usize,
}

struct Output {
    _stream: cpal::Stream,
    voice: Arc<Mutex<Voice>>,
    rate: u32,
    broken: Arc<AtomicBool>,
}

#[derive(Default)]
struct Player {
    out: Option<Output>,
    /// Decoded + resampled sounds, keyed by WAV address and device rate.
    cache: HashMap<(usize, u32), Arc<[f32]>>,
    held: bool,
    last_use: Option<Instant>,
}

impl Player {
    fn hold(&mut self, on: bool) {
        self.held = on;
        self.last_use = Some(Instant::now());
        if on {
            self.ensure_open();
        }
    }

    fn play(&mut self, wav: &'static [u8]) {
        self.last_use = Some(Instant::now());
        if !self.ensure_open() {
            fallback(wav);
            return;
        }
        let out = self.out.as_ref().expect("open");
        let key = (wav.as_ptr() as usize, out.rate);
        let samples = match self.cache.get(&key) {
            Some(s) => s.clone(),
            None => match decode(wav, out.rate) {
                Some(s) => {
                    self.cache.insert(key, s.clone());
                    s
                }
                None => return,
            },
        };
        if let Ok(mut v) = out.voice.lock() {
            v.samples = Some(samples);
            v.pos = 0;
        }
    }

    fn maybe_close(&mut self) {
        let broken = self.out.as_ref().is_some_and(|o| o.broken.load(Ordering::Relaxed));
        let idle = !self.held && self.last_use.is_none_or(|t| t.elapsed() > IDLE_CLOSE);
        if self.out.is_some() && (broken || idle) {
            if broken {
                crate::log::write("audio stream failed; will reopen");
            }
            self.out = None;
        }
    }

    /// Open the default output if needed. Reopens after device errors
    /// (e.g. headphones unplugged).
    fn ensure_open(&mut self) -> bool {
        if self.out.as_ref().is_some_and(|o| o.broken.load(Ordering::Relaxed)) {
            self.out = None;
        }
        if self.out.is_none() {
            match open() {
                Ok(o) => self.out = Some(o),
                Err(e) => crate::log::write(format!("audio: {e}")),
            }
        }
        self.out.is_some()
    }
}

fn open() -> Result<Output, String> {
    let host = cpal::default_host();
    let device = host.default_output_device().ok_or("no output device")?;
    let supported = device.default_output_config().map_err(|e| e.to_string())?;
    let format = supported.sample_format();
    let config: cpal::StreamConfig = supported.into();
    let voice = Arc::new(Mutex::new(Voice::default()));
    let broken = Arc::new(AtomicBool::new(false));
    let stream = match format {
        cpal::SampleFormat::F32 => build::<f32>(&device, &config, &voice, &broken),
        cpal::SampleFormat::I16 => build::<i16>(&device, &config, &voice, &broken),
        cpal::SampleFormat::U16 => build::<u16>(&device, &config, &voice, &broken),
        cpal::SampleFormat::I32 => build::<i32>(&device, &config, &voice, &broken),
        other => return Err(format!("unsupported sample format {other:?}")),
    }?;
    stream.play().map_err(|e| e.to_string())?;
    crate::log::write(format!("audio open: {} Hz, {} ch, {format:?}", config.sample_rate.0, config.channels));
    Ok(Output { _stream: stream, voice, rate: config.sample_rate.0, broken })
}

fn build<T: SizedSample + FromSample<f32>>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    voice: &Arc<Mutex<Voice>>,
    broken: &Arc<AtomicBool>,
) -> Result<cpal::Stream, String> {
    let channels = config.channels as usize;
    let voice = voice.clone();
    let broken = broken.clone();
    device
        .build_output_stream(
            config,
            move |data: &mut [T], _| {
                // Never block the audio thread: if the lock is busy, play silence.
                let mut guard = voice.try_lock().ok();
                for frame in data.chunks_mut(channels) {
                    let s = match guard.as_deref_mut() {
                        Some(Voice { samples: Some(buf), pos }) if *pos < buf.len() => {
                            *pos += 1;
                            buf[*pos - 1]
                        }
                        _ => 0.0,
                    };
                    let v = T::from_sample(s);
                    for out in frame.iter_mut() {
                        *out = v;
                    }
                }
            },
            move |e| {
                crate::log::write(format!("audio stream error: {e}"));
                broken.store(true, Ordering::Relaxed);
            },
            None,
        )
        .map_err(|e| e.to_string())
}

/// PCM WAV → mono f32 at `rate` (linear resampling; fine for short clicks).
fn decode(wav: &[u8], rate: u32) -> Option<Arc<[f32]>> {
    if wav.len() < 12 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return None;
    }
    let (mut channels, mut src_rate, mut bits, mut data) = (0u16, 0u32, 0u16, None);
    let mut i = 12;
    while i + 8 <= wav.len() {
        let id = &wav[i..i + 4];
        let len = u32::from_le_bytes(wav[i + 4..i + 8].try_into().ok()?) as usize;
        let body = wav.get(i + 8..(i + 8 + len).min(wav.len()))?;
        match id {
            b"fmt " if body.len() >= 16 => {
                channels = u16::from_le_bytes([body[2], body[3]]);
                src_rate = u32::from_le_bytes(body[4..8].try_into().ok()?);
                bits = u16::from_le_bytes([body[14], body[15]]);
            }
            b"data" => data = Some(body),
            _ => {}
        }
        i += 8 + len + (len & 1);
    }
    let data = data?;
    if bits != 16 || channels == 0 || src_rate == 0 {
        return None;
    }
    let ch = channels as usize;
    let mono: Vec<f32> = data
        .chunks_exact(2 * ch)
        .map(|f| f.chunks_exact(2).map(|s| i16::from_le_bytes([s[0], s[1]]) as f32 / 32768.0).sum::<f32>() / ch as f32)
        .collect();
    if src_rate == rate || mono.is_empty() {
        return Some(mono.into());
    }
    let step = src_rate as f64 / rate as f64;
    let n = ((mono.len() as f64) / step) as usize;
    let out: Vec<f32> = (0..n)
        .map(|k| {
            let x = k as f64 * step;
            let j = x as usize;
            let t = (x - j as f64) as f32;
            let a = mono[j];
            let b = *mono.get(j + 1).unwrap_or(&a);
            a + (b - a) * t
        })
        .collect();
    Some(out.into())
}

/// If no stream can be opened at all, fall back to the OS one-shot player.
fn fallback(wav: &'static [u8]) {
    crate::platform::play_sound(wav);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Needs a real output device (plays silence briefly). `cargo test -- --ignored`
    #[test]
    #[ignore]
    fn opens_default_output() {
        let out = open().expect("open output");
        assert!(out.rate >= 8000);
        std::thread::sleep(Duration::from_millis(300));
        assert!(!out.broken.load(Ordering::Relaxed));
    }

    #[test]
    fn decodes_and_resamples_taps() {
        let wav = crate::sounds::bytes("thock");
        let same = decode(wav, 44_100).unwrap();
        assert!(same.len() > 4000, "{}", same.len());
        assert!(same.iter().any(|s| s.abs() > 0.05));
        let up = decode(wav, 48_000).unwrap();
        let ratio = up.len() as f64 / same.len() as f64;
        assert!((ratio - 48_000.0 / 44_100.0).abs() < 0.01, "{ratio}");
    }
}
