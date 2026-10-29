#!/usr/bin/env python3
"""Builds the app icon and menu bar images from the SVGs in assets/icon.

    assets/AppIcon.icns          app icon (Finder, DMG, Settings, login items)
    assets/icon-1024.png         the same at 1024 px, for the README / web
    assets/menubar_{off,on}[@2x|@3x].png   template images for the menu bar

Needs rsvg-convert (brew install librsvg), Pillow, and macOS's iconutil.
"""
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "assets", "icon")
ASSETS = os.path.join(ROOT, "assets")

# Lavender, to match the default toy pointer.
TOP = (205, 186, 255)
BOTTOM = (132, 96, 232)


def svg_to_png(svg, size, out):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "-a", "-o", out, svg], check=True)
    return Image.open(out).convert("RGBA")


def rounded_mask(size, box, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def app_icon(tmp):
    s = 1024
    # macOS icon grid: an 824 px rounded square centred on a 1024 canvas.
    inset = 100
    box = (inset, inset, s - inset, s - inset)
    radius = 185

    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Soft drop shadow under the tile.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 14, box[2], box[3] + 14), radius=radius, fill=(40, 20, 90, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))

    # Vertical lavender gradient tile with a faint top highlight.
    tile = Image.new("RGBA", (s, s))
    draw = ImageDraw.Draw(tile)
    for y in range(s):
        t = min(1, max(0, (y - inset) / (s - 2 * inset)))
        draw.line([(0, y), (s, y)], fill=tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,))
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((inset - 200, inset - 520, s - inset + 200, s // 2 + 40), fill=(255, 255, 255, 38))
    tile.alpha_composite(glow.filter(ImageFilter.GaussianBlur(120)))
    tile.putalpha(rounded_mask(s, box, radius))
    canvas.alpha_composite(tile)

    # The pointing-hand cursor, with its own soft shadow, slightly up and right of centre.
    hand_size = 600
    hand = svg_to_png(os.path.join(ICON_DIR, "hand-cursor.svg"), hand_size, os.path.join(tmp, "hand.png"))
    x = (s - hand_size) // 2 + 20
    y = (s - hand_size) // 2 - 4
    hand_shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    silhouette = Image.new("RGBA", hand.size, (35, 15, 80, 120))
    silhouette.putalpha(ImageChops.multiply(hand.getchannel("A"), Image.new("L", hand.size, 120)))
    hand_shadow.alpha_composite(silhouette, (x + 18, y + 26))
    canvas.alpha_composite(hand_shadow.filter(ImageFilter.GaussianBlur(16)))
    canvas.alpha_composite(hand, (x, y))
    return canvas


def build_icns(icon, tmp):
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ASSETS, "AppIcon.icns")], check=True)


def menubar(tmp):
    # 18 pt template images: black + alpha, macOS tints them for light/dark menu bars.
    for state in ("off", "on"):
        svg = os.path.join(ICON_DIR, f"menubar-{state}.svg")
        for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
            px = 18 * scale
            img = svg_to_png(svg, px, os.path.join(tmp, f"mb-{state}{suffix}.png"))
            black = Image.new("RGBA", img.size, (0, 0, 0, 255))
            black.putalpha(img.getchannel("A"))
            black.save(os.path.join(ASSETS, f"menubar_{state}{suffix}.png"))


def main():
    tmp = tempfile.mkdtemp()
    try:
        icon = app_icon(tmp)
        icon.save(os.path.join(ASSETS, "icon-1024.png"))
        build_icns(icon, tmp)
        menubar(tmp)
    finally:
        shutil.rmtree(tmp)
    print("wrote assets/AppIcon.icns, assets/icon-1024.png, assets/menubar_*.png")


if __name__ == "__main__":
    main()
