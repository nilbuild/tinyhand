//! The "hold a key to click for real" key, without leaking it into clicks.
//!
//! macOS strips the modifier from the click (`event.flags.remove`). Windows
//! can't change modifier state from a mouse hook, so instead the keyboard
//! hook keeps the key from apps entirely while the pointer is on: Alt+click
//! then reaches Chrome as a plain click instead of "download link".
//!
//! Shortcuts still work: if another key is pressed while the interact key is
//! held (Alt+Tab, Ctrl+C), the held key is handed back to the system just
//! before it ("replay").

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum KeyAction {
    /// Let the event through.
    Pass,
    /// Drop the event.
    Swallow,
    /// Drop this key, then inject the held interact key's press followed by
    /// this key's press, so apps see the shortcut in the right order.
    Replay,
}

#[derive(Default, Debug)]
pub struct InteractFilter {
    held: bool,
    replayed: bool,
}

impl InteractFilter {
    /// The interact key is physically down.
    pub fn held(&self) -> bool {
        self.held
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Decide what to do with a key event. `is_interact` says whether this
    /// key is the interact key (either side, e.g. left or right Alt).
    pub fn key(&mut self, is_interact: bool, down: bool) -> KeyAction {
        if is_interact {
            if down {
                self.held = true;
                // Auto-repeat after a replay can go through; apps already saw the press.
                if self.replayed {
                    KeyAction::Pass
                } else {
                    KeyAction::Swallow
                }
            } else {
                let replayed = self.replayed;
                self.held = false;
                self.replayed = false;
                if replayed {
                    KeyAction::Pass
                } else {
                    KeyAction::Swallow
                }
            }
        } else if down && self.held && !self.replayed {
            self.replayed = true;
            KeyAction::Replay
        } else {
            KeyAction::Pass
        }
    }
}

#[cfg(test)]
mod tests {
    use super::KeyAction::*;
    use super::*;

    #[test]
    fn hold_alone_never_reaches_apps() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(true, true), Swallow);
        assert!(f.held());
        assert_eq!(f.key(true, true), Swallow, "auto-repeat");
        assert_eq!(f.key(true, false), Swallow);
        assert!(!f.held());
    }

    #[test]
    fn shortcut_is_replayed_once() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(true, true), Swallow); // Alt down
        assert_eq!(f.key(false, true), Replay); // Tab down → inject Alt, Tab
        assert_eq!(f.key(false, false), Pass); // Tab up
        assert_eq!(f.key(false, true), Pass); // Tab again (Alt already given)
        assert_eq!(f.key(true, true), Pass); // Alt auto-repeat
        assert_eq!(f.key(true, false), Pass); // Alt up pairs with the replayed down
        assert!(!f.held());
        // Next hold starts clean.
        assert_eq!(f.key(true, true), Swallow);
    }

    #[test]
    fn other_keys_untouched_when_not_held() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(false, true), Pass);
        assert_eq!(f.key(false, false), Pass);
    }
}
