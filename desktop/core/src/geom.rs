/// Integer pixel rectangle, half-open: `x0..x1`, `y0..y1`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IRect {
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
}

impl IRect {
    pub fn new(x0: i32, y0: i32, x1: i32, y1: i32) -> Self {
        Self { x0, y0, x1, y1 }
    }

    pub fn width(&self) -> i32 {
        self.x1 - self.x0
    }

    pub fn height(&self) -> i32 {
        self.y1 - self.y0
    }

    pub fn is_empty(&self) -> bool {
        self.x1 <= self.x0 || self.y1 <= self.y0
    }

    /// Smallest integer rect covering the float box, grown by `pad`.
    pub fn around(min_x: f32, min_y: f32, max_x: f32, max_y: f32, pad: f32) -> Self {
        Self {
            x0: (min_x - pad).floor() as i32,
            y0: (min_y - pad).floor() as i32,
            x1: (max_x + pad).ceil() as i32,
            y1: (max_y + pad).ceil() as i32,
        }
    }

    pub fn union(self, other: IRect) -> IRect {
        if self.is_empty() {
            return other;
        }
        if other.is_empty() {
            return self;
        }
        IRect {
            x0: self.x0.min(other.x0),
            y0: self.y0.min(other.y0),
            x1: self.x1.max(other.x1),
            y1: self.y1.max(other.y1),
        }
    }

    pub fn intersect(self, other: IRect) -> Option<IRect> {
        let r = IRect {
            x0: self.x0.max(other.x0),
            y0: self.y0.max(other.y0),
            x1: self.x1.min(other.x1),
            y1: self.y1.min(other.y1),
        };
        (!r.is_empty()).then_some(r)
    }

    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x0 && x < self.x1 && y >= self.y0 && y < self.y1
    }
}

pub fn merge(a: Option<IRect>, b: Option<IRect>) -> Option<IRect> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.union(b)),
        (a, None) => a,
        (None, b) => b,
    }
}

/// 2D affine map: `x' = a·x + b·y + c`, `y' = d·x + e·y + f`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Affine {
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
    pub e: f32,
    pub f: f32,
}

impl Affine {
    pub const IDENTITY: Affine = Affine { a: 1.0, b: 0.0, c: 0.0, d: 0.0, e: 1.0, f: 0.0 };

    pub fn new(a: f32, b: f32, c: f32, d: f32, e: f32, f: f32) -> Self {
        Self { a, b, c, d, e, f }
    }

    pub fn translate(x: f32, y: f32) -> Self {
        Self::new(1.0, 0.0, x, 0.0, 1.0, y)
    }

    /// Apply `self` first, then `outer`.
    pub fn then(self, outer: Affine) -> Affine {
        let s = outer;
        Affine {
            a: s.a * self.a + s.b * self.d,
            b: s.a * self.b + s.b * self.e,
            c: s.a * self.c + s.b * self.f + s.c,
            d: s.d * self.a + s.e * self.d,
            e: s.d * self.b + s.e * self.e,
            f: s.d * self.c + s.e * self.f + s.f,
        }
    }

    pub fn apply(&self, x: f32, y: f32) -> (f32, f32) {
        (self.a * x + self.b * y + self.c, self.d * x + self.e * y + self.f)
    }

    pub fn to_skia(self) -> tiny_skia::Transform {
        tiny_skia::Transform::from_row(self.a, self.d, self.b, self.e, self.c, self.f)
    }
}
