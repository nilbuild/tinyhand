//! Built-in hands, tap sounds and ink colours. Mirrors `PointerStyle.swift`,
//! `TapSound.swift` and `Preferences.swift` in the macOS app.

pub const LASER: &str = "laser";
pub const PURPLE: u32 = 0x8754F2;
pub const RED: u32 = 0xFF291F;

pub struct HandStyle {
    pub id: &'static str,
    pub title: &'static str,
    pub ink: u32,
}

const fn h(id: &'static str, title: &'static str, ink: u32) -> HandStyle {
    HandStyle { id, title, ink }
}

pub const HANDS: &[HandStyle] = &[
    h("lavender", "Lavender toy", PURPLE),
    h("glove", "Cursor glove", PURPLE),
    h("coral", "Coral vinyl", RED),
    h("plush", "Plush", 0x2F86F0),
    h("robot", "Robot", 0x16A87A),
    h("pink", "Bubblegum", 0xEE4F98),
    h("blue", "Sky", 0x2F86F0),
    h("mint", "Mint", 0x16A87A),
    h("lemon", "Lemon", 0xF2B705),
    h("black", "Midnight", 0x1D1D21),
    h("chrome", "Chrome", 0x6B7380),
    h("holo", "Holo", PURPLE),
    h("fuzzy", "Fuzzy", PURPLE),
    h("wood", "Wood", 0x9A5E2C),
    h("marble", "Marble", 0x6B7380),
    h("terrazzo", "Terrazzo", 0xF0561D),
    h("glass", "Glass", 0x1597E5),
    h("jelly", "Jelly", 0xA33FE6),
    h("pastel", "Pastel", 0xEE4F98),
    h("pixel", "Pixel", 0x1D1D21),
    h("lowpoly", "Low poly", PURPLE),
    h("knit", "Knit", PURPLE),
    h("skeleton", "Skeleton", 0x9A5E2C),
    h("astro", "Astronaut", 0x2F86F0),
    h("space", "Space", RED),
    h("monster", "Monster", 0x3E9E2E),
    h("water", "Water", 0x1597E5),
    h("lava", "Lava", 0xF0561D),
    h("grass", "Grass", 0x3E9E2E),
    h("cactus", "Cactus", 0x3E9E2E),
    h("choco", "Chocolate", 0x9A5E2C),
    h("cloud", "Cloud", 0x2F86F0),
    h("mech", "Mech", 0xF0561D),
    h("neon", "Neon", 0xE0309A),
    h("leaf", "Leaf", 0x3E9E2E),
    h("cookie", "Gingerbread", 0x9A5E2C),
];

pub const DEFAULT_PINNED: &[&str] = &["lavender", "glove", "coral", "plush", "robot", LASER];
pub const MAX_PINNED: usize = 8;

pub fn hand(id: &str) -> Option<&'static HandStyle> {
    HANDS.iter().find(|s| s.id == id)
}

pub fn is_style(id: &str) -> bool {
    id == LASER || hand(id).is_some()
}

pub fn title(id: &str) -> &'static str {
    if id == LASER {
        return "Laser dot";
    }
    hand(id).map(|s| s.title).unwrap_or("Hand")
}

/// Ink colour that matches a pointer style.
pub fn style_ink(id: &str) -> u32 {
    if id == LASER {
        return RED;
    }
    hand(id).map(|s| s.ink).unwrap_or(PURPLE)
}

pub const SOUNDS: &[(&str, &str)] = &[
    ("thock", "Thock"),
    ("click", "Click"),
    ("pop", "Pop"),
    ("wood", "Wood block"),
    ("boop", "Boop"),
    ("squeak", "Squeak"),
];

pub const INKS: &[(&str, &str, Option<u32>)] = &[
    ("match", "Match the pointer", None),
    ("red", "Red", Some(RED)),
    ("orange", "Orange", Some(0xFF8A00)),
    ("yellow", "Yellow", Some(0xFFCC00)),
    ("green", "Green", Some(0x30C25A)),
    ("blue", "Blue", Some(0x0A84FF)),
    ("purple", "Purple", Some(PURPLE)),
    ("white", "White", Some(0xFFFFFF)),
    ("black", "Black", Some(0x1D1D21)),
];

pub fn ink_color(choice: &str, style: &str) -> u32 {
    INKS.iter()
        .find(|(id, _, _)| *id == choice)
        .and_then(|(_, _, c)| *c)
        .unwrap_or_else(|| style_ink(style))
}

pub fn rgb(hex: u32) -> [u8; 3] {
    [(hex >> 16) as u8, (hex >> 8) as u8, hex as u8]
}
