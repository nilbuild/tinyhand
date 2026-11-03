//! Stand-in for platforms without an overlay yet. Logs what it would do.

use super::{OverlayConfig, OverlayEvent};

pub struct Overlay;

impl Overlay {
    pub fn new(_on_event: impl Fn(OverlayEvent) + Send + 'static) -> Self {
        Overlay
    }

    pub fn configure(&self, _cfg: OverlayConfig) {}

    pub fn activate(&self, _toolbar: Option<isize>) {
        crate::log::write("overlay: not implemented on this platform yet");
    }

    pub fn deactivate(&self) {}

    pub fn clear_ink(&self) {}

    pub fn set_pass_windows(&self, _windows: Vec<isize>) {}
}

pub fn early_init() {}

pub fn shutdown() {}

pub fn play_sound(_wav: &'static [u8]) {}

pub fn prepare_toolbar(_window: &tauri::WebviewWindow) {}

pub fn window_handle(_window: &tauri::WebviewWindow) -> Option<isize> {
    None
}
