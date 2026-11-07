//! Tap sounds, embedded (they're ~10 KB each) so a tap never waits on disk.

macro_rules! wav {
    ($name:literal) => {
        include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../assets/sounds/tap_", $name, ".wav"))
    };
}

pub fn bytes(id: &str) -> &'static [u8] {
    match id {
        "click" => wav!("click"),
        "pop" => wav!("pop"),
        "wood" => wav!("wood"),
        "boop" => wav!("boop"),
        "squeak" => wav!("squeak"),
        _ => wav!("thock"),
    }
}
