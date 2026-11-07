//! Hiding the cursor for every app.
//!
//! Windows has no "hide the cursor everywhere" call (`ShowCursor` only affects
//! our own thread), so we replace each system cursor with a blank one and put
//! the user's scheme back with `SPI_SETCURSORS`. The swap only lasts for the
//! session, and we restore on exit, on panic and on the next launch.

use std::sync::atomic::{AtomicBool, Ordering};

use windows::Win32::UI::WindowsAndMessaging::{
    CreateCursor, SetSystemCursor, SystemParametersInfoW, SPI_SETCURSORS, SYSTEM_CURSOR_ID, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
};

static HIDDEN: AtomicBool = AtomicBool::new(false);

/// OCR_NORMAL, IBEAM, WAIT, CROSS, UP, SIZENWSE, SIZENESW, SIZEWE, SIZENS,
/// SIZEALL, NO, HAND, APPSTARTING, HELP, PIN, PERSON.
const IDS: [u32; 16] = [
    32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650, 32651, 32671, 32672,
];

pub fn hide() {
    if HIDDEN.swap(true, Ordering::SeqCst) {
        return;
    }
    // AND mask all ones + XOR mask all zeros = fully transparent.
    let and = [0xFFu8; 32 * 32 / 8];
    let xor = [0u8; 32 * 32 / 8];
    for id in IDS {
        unsafe {
            // SetSystemCursor takes ownership, so each id needs its own copy.
            if let Ok(blank) = CreateCursor(None, 0, 0, 32, 32, and.as_ptr().cast(), xor.as_ptr().cast()) {
                let _ = SetSystemCursor(blank, SYSTEM_CURSOR_ID(id));
            }
        }
    }
}

pub fn show() {
    if HIDDEN.swap(false, Ordering::SeqCst) {
        restore();
    }
}

/// Reload the user's cursor scheme.
pub fn restore() {
    unsafe {
        let _ = SystemParametersInfoW(SPI_SETCURSORS, 0, None, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0));
    }
}
