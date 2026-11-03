//! Windows implementation.
//!
//! * `hook`: a low-level mouse hook (`WH_MOUSE_LL`) that swallows clicks while
//!   the pointer is on. No permission prompt is needed on Windows.
//! * `overlay`: a click-through, always-on-top layered window per monitor,
//!   painted by the shared `tinyhand_core::Engine`.
//! * `cursor`: hides the system cursor by swapping every system cursor for a
//!   blank one, and restores the user's scheme afterwards (and on crash).
//! * `sound`: tap sounds via `PlaySound`.

mod cursor;
mod hook;
mod overlay;
mod sound;

pub use overlay::Overlay;
pub use sound::play as play_sound;

use windows::Win32::Foundation::HWND;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::WindowsAndMessaging::{GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW};

pub fn early_init() {
    unsafe {
        // Physical pixels everywhere, so hook, monitor and window coordinates agree.
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    // If an earlier run died with the cursor hidden, bring it back.
    cursor::restore();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        cursor::restore();
        crate::log::write(format!("panic: {info}"));
        previous(info);
    }));
}

pub fn shutdown() {
    cursor::show();
}

pub fn window_handle(window: &tauri::WebviewWindow) -> Option<isize> {
    window.hwnd().ok().map(|h| h.0 as isize)
}

/// Clicking the toolbar must not pull focus away from the app being presented.
pub fn prepare_toolbar(window: &tauri::WebviewWindow) {
    let Some(h) = window_handle(window) else { return };
    unsafe {
        let hwnd = HWND(h as _);
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | (WS_EX_NOACTIVATE.0 | WS_EX_TOOLWINDOW.0) as isize);
    }
}
