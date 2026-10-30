#!/usr/bin/env python3
import os
import shutil
import subprocess
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "assets", "icon")
ASSETS = os.path.join(ROOT, "assets")
ICON_DOC = os.path.join(ASSETS, "AppIcon.icon")
MIN_MACOS = "13.0"

def svg_to_png(svg, size, out):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "-a", "-o", out, svg], check=True)
    return Image.open(out).convert("RGBA")

def developer_dir():
    return subprocess.run(["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip()

def compile_car(tmp):
    out = os.path.join(tmp, "car")
    os.makedirs(out)
    subprocess.run([
        "xcrun", "actool", ICON_DOC, "--compile", out,
        "--output-partial-info-plist", os.path.join(out, "partial.plist"),
        "--app-icon", "AppIcon", "--include-all-app-icons",
        "--enable-on-demand-resources", "NO", "--development-region", "en",
        "--target-device", "mac", "--platform", "macosx",
        "--minimum-deployment-target", MIN_MACOS,
    ], check=True, stdout=subprocess.DEVNULL)
    shutil.copy(os.path.join(out, "Assets.car"), os.path.join(ASSETS, "Assets.car"))

def app_icon(tmp):
    ictool = os.path.join(developer_dir(), "..", "Applications", "Icon Composer.app", "Contents", "Executables", "ictool")
    shape = os.path.join(tmp, "shape.png")
    subprocess.run([
        ictool, ICON_DOC, "--export-image", "--output-file", shape, "--platform", "macOS",
        "--rendition", "Default", "--width", "824", "--height", "824", "--scale", "1",
    ], check=True, stdout=subprocess.DEVNULL)
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    canvas.alpha_composite(Image.open(shape).convert("RGBA"), (100, 100))
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
        compile_car(tmp)
        icon = app_icon(tmp)
        build_icns(icon, tmp)
        menubar(tmp)
    finally:
        shutil.rmtree(tmp)
    print("wrote assets/Assets.car, assets/AppIcon.icns, assets/menubar_*.png")

if __name__ == "__main__":
    main()
