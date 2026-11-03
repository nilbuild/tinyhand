//! The low-level mouse hook. Equivalent of `InputTap.swift`.
//!
//! While the pointer is on, button presses are swallowed (the app underneath
//! never sees them) and reported to the overlay as taps. Moves always pass,
//! so a "drag" reaches other apps as a plain move, just like on macOS.
//! Presses pass through when the interact key is held or when they land on
//! a pass-through rect (taskbar, toolbar, settings window).
//!
//! A keyboard hook on the same thread keeps the interact key itself away
//! from apps (see `tinyhand_core::interact`), so Alt+click isn't seen as
//! Alt+click by Chrome and friends.
//!
//! Windows calls the hooks on the thread that installed them, and drops a
//! hook if a call takes longer than ~300 ms, so they live on their own thread
//! with nothing else to do.

use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::thread::JoinHandle;

use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{GetCurrentThread, GetCurrentThreadId, SetThreadPriority, THREAD_PRIORITY_TIME_CRITICAL};
use tinyhand_core::interact::{InteractFilter, KeyAction};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_EXTENDEDKEY, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GetMessageW, PeekMessageW, PostThreadMessageW, SetWindowsHookExW, UnhookWindowsHookEx, HC_ACTION, KBDLLHOOKSTRUCT,
    LLKHF_EXTENDED, MSG, MSLLHOOKSTRUCT, PM_NOREMOVE, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_APP, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEMOVE, WM_QUIT, WM_RBUTTONDOWN,
    WM_RBUTTONUP, WM_XBUTTONDOWN, WM_XBUTTONUP,
};

use super::overlay::Msg;

pub enum HookEvent {
    /// The mouse moved while the overlay was idling; wake it up.
    Moved,
    Down { left: bool },
    Up,
    InteractDown,
    InteractUp,
}

pub struct Shared {
    pub active: AtomicBool,
    /// Virtual key that lets clicks through while held; 0 = off.
    pub interact_vk: AtomicI32,
    /// Screen rects (physical pixels) where presses go through.
    pub pass: Mutex<Vec<RECT>>,
    /// Set by the overlay while it ticks slowly; the next move wakes it.
    pub idle: AtomicBool,
    /// The cursor is over one of our own windows (Settings); set by the overlay.
    pub over_window: AtomicBool,
    /// The interact key is held right now (the system never sees it).
    pub interact_held: AtomicBool,
    tx: Mutex<Sender<Msg>>,
    interacting: AtomicBool,
    passing: AtomicBool,
}

static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();

impl Shared {
    pub fn new(tx: Sender<Msg>) -> Arc<Shared> {
        Arc::new(Shared {
            active: AtomicBool::new(false),
            interact_vk: AtomicI32::new(0),
            pass: Mutex::new(Vec::new()),
            idle: AtomicBool::new(false),
            over_window: AtomicBool::new(false),
            interact_held: AtomicBool::new(false),
            tx: Mutex::new(tx),
            interacting: AtomicBool::new(false),
            passing: AtomicBool::new(false),
        })
    }

    /// A press is currently going through because of the interact key.
    pub fn interacting(&self) -> bool {
        self.interacting.load(Ordering::Relaxed)
    }

    pub fn reset(&self) {
        self.interact_held.store(false, Ordering::Relaxed);
        self.interacting.store(false, Ordering::Relaxed);
        self.passing.store(false, Ordering::Relaxed);
    }

    fn send(&self, e: HookEvent) {
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(Msg::Hook(e));
        }
    }

    /// Returns true to swallow the event.
    fn handle(&self, msg: u32, info: &MSLLHOOKSTRUCT) -> bool {
        // Injected input is handled like real input on purpose: VM mouse
        // integration and remote-desktop tools deliver clicks that way.
        if !self.active.load(Ordering::Relaxed) {
            return false;
        }
        match msg {
            WM_MOUSEMOVE => {
                if self.idle.swap(false, Ordering::Relaxed) {
                    self.send(HookEvent::Moved);
                }
                false
            }
            WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_XBUTTONDOWN => {
                if self.interact_held.load(Ordering::Relaxed) {
                    self.interacting.store(true, Ordering::Relaxed);
                    self.send(HookEvent::InteractDown);
                    return false;
                }
                let pass = self.over_window.load(Ordering::Relaxed)
                    || self.pass.lock().map(|r| r.iter().any(|r| contains(r, info.pt))).unwrap_or(false);
                if pass {
                    self.passing.store(true, Ordering::Relaxed);
                    return false;
                }
                self.send(HookEvent::Down { left: msg == WM_LBUTTONDOWN });
                true
            }
            WM_LBUTTONUP | WM_RBUTTONUP | WM_MBUTTONUP | WM_XBUTTONUP => {
                if self.interacting.swap(false, Ordering::Relaxed) {
                    self.send(HookEvent::InteractUp);
                    return false;
                }
                if self.passing.swap(false, Ordering::Relaxed) {
                    return false;
                }
                self.send(HookEvent::Up);
                true
            }
            _ => false,
        }
    }
}

/// Marks keys we inject ourselves, so the keyboard hook lets them by.
const OURS: usize = 0x7448_616E;
const REPLAY: u32 = WM_APP + 1;

struct Held {
    vk: u32,
    scan: u32,
    extended: bool,
}

thread_local! {
    // Both hooks and the replay queue live on the hook thread only.
    static FILTER: RefCell<InteractFilter> = RefCell::new(InteractFilter::default());
    static HELD: RefCell<Option<Held>> = const { RefCell::new(None) };
    static PENDING: RefCell<Vec<INPUT>> = const { RefCell::new(Vec::new()) };
    static THREAD: RefCell<u32> = const { RefCell::new(0) };
}

/// Is `vk` (as the keyboard hook reports it, left/right specific) the
/// interact key `generic` (VK_MENU / VK_CONTROL / VK_SHIFT)?
fn is_interact(generic: i32, vk: u32) -> bool {
    match generic {
        0x12 => matches!(vk, 0x12 | 0xA4 | 0xA5),
        0x11 => matches!(vk, 0x11 | 0xA2 | 0xA3),
        0x10 => matches!(vk, 0x10 | 0xA0 | 0xA1),
        _ => false,
    }
}

fn key_input(vk: u32, scan: u32, extended: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk as u16),
                wScan: scan as u16,
                dwFlags: if extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) },
                time: 0,
                dwExtraInfo: OURS,
            },
        },
    }
}

impl Shared {
    /// Returns true to swallow the key event.
    fn key(&self, msg: u32, info: &KBDLLHOOKSTRUCT) -> bool {
        if info.dwExtraInfo == OURS {
            return false;
        }
        let generic = self.interact_vk.load(Ordering::Relaxed);
        if !self.active.load(Ordering::Relaxed) || generic == 0 {
            FILTER.with(|f| f.borrow_mut().reset());
            self.interact_held.store(false, Ordering::Relaxed);
            return false;
        }
        let down = matches!(msg, WM_KEYDOWN | WM_SYSKEYDOWN);
        if !down && !matches!(msg, WM_KEYUP | WM_SYSKEYUP) {
            return false;
        }
        let target = is_interact(generic, info.vkCode);
        let extended = info.flags.0 & LLKHF_EXTENDED.0 != 0;
        if target && down {
            HELD.with(|h| *h.borrow_mut() = Some(Held { vk: info.vkCode, scan: info.scanCode, extended }));
        }
        let action = FILTER.with(|f| {
            let mut f = f.borrow_mut();
            let a = f.key(target, down);
            self.interact_held.store(f.held(), Ordering::Relaxed);
            a
        });
        match action {
            KeyAction::Pass => false,
            KeyAction::Swallow => true,
            KeyAction::Replay => {
                // Injecting from inside the hook would land after this key,
                // so queue it and send right after the hook returns.
                PENDING.with(|p| {
                    let mut p = p.borrow_mut();
                    if let Some(h) = HELD.with(|h| h.borrow().as_ref().map(|h| key_input(h.vk, h.scan, h.extended))) {
                        p.push(h);
                    }
                    p.push(key_input(info.vkCode, info.scanCode, extended));
                });
                let tid = THREAD.with(|t| *t.borrow());
                unsafe {
                    let _ = PostThreadMessageW(tid, REPLAY, WPARAM(0), LPARAM(0));
                }
                true
            }
        }
    }
}

fn flush_replay() {
    let inputs = PENDING.with(|p| std::mem::take(&mut *p.borrow_mut()));
    if !inputs.is_empty() {
        unsafe {
            SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
        }
    }
}

unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        if let Some(shared) = SHARED.get() {
            let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            if shared.key(wparam.0 as u32, info) {
                return LRESULT(1);
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

pub fn contains(r: &RECT, p: POINT) -> bool {
    p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        if let Some(shared) = SHARED.get() {
            let info = &*(lparam.0 as *const MSLLHOOKSTRUCT);
            if shared.handle(wparam.0 as u32, info) {
                return LRESULT(1);
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

/// An installed hook; dropping it removes the hook and stops its thread.
pub struct Hook {
    thread_id: u32,
    join: Option<JoinHandle<()>>,
}

impl Hook {
    pub fn install(shared: &Arc<Shared>) -> Option<Hook> {
        let _ = SHARED.set(shared.clone());
        let (ready_tx, ready_rx) = mpsc::channel();
        let join = std::thread::Builder::new()
            .name("tinyhand-hook".into())
            .spawn(move || unsafe {
                let mut msg = MSG::default();
                // Make sure this thread has a message queue before anyone posts to it.
                let _ = PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE);
                let module = GetModuleHandleW(None).ok().map(|m| HINSTANCE(m.0));
                let hook = match SetWindowsHookExW(WH_MOUSE_LL, Some(hook_proc), module, 0) {
                    Ok(h) => h,
                    Err(e) => {
                        crate::log::write(format!("SetWindowsHookExW failed: {e}"));
                        let _ = ready_tx.send(None);
                        return;
                    }
                };
                let keyboard = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), module, 0) {
                    Ok(h) => Some(h),
                    Err(e) => {
                        // Clicks still work; the interact key just leaks into apps.
                        crate::log::write(format!("keyboard hook failed: {e}"));
                        None
                    }
                };
                THREAD.with(|t| *t.borrow_mut() = GetCurrentThreadId());
                FILTER.with(|f| f.borrow_mut().reset());
                let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
                let _ = ready_tx.send(Some(GetCurrentThreadId()));
                while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
                    if msg.message == REPLAY {
                        flush_replay();
                    }
                }
                if let Some(k) = keyboard {
                    let _ = UnhookWindowsHookEx(k);
                }
                let _ = UnhookWindowsHookEx(hook);
            })
            .ok()?;
        match ready_rx.recv() {
            Ok(Some(thread_id)) => Some(Hook { thread_id, join: Some(join) }),
            _ => {
                let _ = join.join();
                None
            }
        }
    }
}

impl Drop for Hook {
    fn drop(&mut self) {
        unsafe {
            let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
        }
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}
