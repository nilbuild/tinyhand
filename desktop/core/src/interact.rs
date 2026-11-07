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
    /// The system has this press, so it must also get the release: either we
    /// replayed it, or it went down before the hook was there.
    given: bool,
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
    /// `system_down` says the system already considers this key pressed.
    ///
    /// Never swallow the release of a key the system thinks is down: it would
    /// stay stuck, and everything typed afterwards becomes a shortcut. That is
    /// what happens when Ctrl+Alt+H turns the pointer on: Alt went down before
    /// the hook was installed and comes up after.
    pub fn key(&mut self, is_interact: bool, down: bool, system_down: bool) -> KeyAction {
        if is_interact {
            if down {
                self.held = true;
                self.given |= system_down;
                // Auto-repeat of a press the system has can go through.
                if self.given {
                    KeyAction::Pass
                } else {
                    KeyAction::Swallow
                }
            } else {
                let swallowed_press = self.held && !self.given && !system_down;
                self.held = false;
                self.given = false;
                if swallowed_press {
                    KeyAction::Swallow
                } else {
                    KeyAction::Pass
                }
            }
        } else if down && self.held && !self.given {
            self.given = true;
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
        assert_eq!(f.key(true, true, false), Swallow);
        assert!(f.held());
        assert_eq!(f.key(true, true, false), Swallow, "auto-repeat");
        assert_eq!(f.key(true, false, false), Swallow);
        assert!(!f.held());
    }

    #[test]
    fn shortcut_is_replayed_once() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(true, true, false), Swallow); // Alt down
        assert_eq!(f.key(false, true, false), Replay); // Tab down → inject Alt, Tab
        assert_eq!(f.key(false, false, false), Pass); // Tab up
        assert_eq!(f.key(false, true, false), Pass); // Tab again (Alt already given)
        assert_eq!(f.key(true, true, true), Pass); // Alt auto-repeat
        assert_eq!(f.key(true, false, true), Pass); // Alt up pairs with the replayed down
        assert!(!f.held());
        // Next hold starts clean.
        assert_eq!(f.key(true, true, false), Swallow);
    }

    #[test]
    fn other_keys_untouched_when_not_held() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(false, true, false), Pass);
        assert_eq!(f.key(false, false, false), Pass);
    }

    /// Ctrl+Alt+H turns the pointer on, so the hook starts with Alt already down.
    #[test]
    fn release_of_key_pressed_before_the_hook_passes() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(true, false, true), Pass);
        assert!(!f.held());
        // Next hold is hidden from apps as usual.
        assert_eq!(f.key(true, true, false), Swallow);
        assert_eq!(f.key(true, false, false), Swallow);
    }

    #[test]
    fn auto_repeat_of_key_pressed_before_the_hook_passes() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(true, true, true), Pass);
        assert!(f.held());
        assert_eq!(f.key(false, true, true), Pass, "the system already has the key, no replay");
        assert_eq!(f.key(true, false, true), Pass);
        assert!(!f.held());
    }

    /// Left and right Alt together: only one is replayed, neither may stick.
    #[test]
    fn both_sides_held_never_swallow_a_release_the_system_needs() {
        let mut f = InteractFilter::default();
        assert_eq!(f.key(true, true, false), Swallow); // left down
        assert_eq!(f.key(true, true, false), Swallow); // right down
        assert_eq!(f.key(false, true, false), Replay); // replays right
        assert_eq!(f.key(true, false, false), Pass); // left up
        assert_eq!(f.key(true, false, true), Pass); // right up
    }
}
