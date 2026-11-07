//! OS-specific pieces: the click-swallowing mouse hook, the transparent
//! overlay window, hiding the system cursor, and tap sounds.
//!
//! Windows is implemented. Other platforms get a stub so the app (tray,
//! settings, toolbar) still builds and runs for UI work; the macOS product
//! remains the Swift app until its overlay is ported here.

use tinyhand_core::prefs::InteractKey;
use tinyhand_core::{Look, Settings};

#[cfg_attr(not(windows), allow(dead_code))]
pub struct OverlayConfig {
    pub look: Look,
    pub settings: Settings,
    /// `None` when muted.
    pub sound: Option<&'static [u8]>,
    pub interact: InteractKey,
}

#[cfg_attr(not(windows), allow(dead_code))]
pub enum OverlayEvent {
    /// Show or fade out the toolbar (it hides while you're away from it).
    Reveal(bool),
}

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(not(windows))]
mod other;
#[cfg(not(windows))]
pub use self::other::*;
