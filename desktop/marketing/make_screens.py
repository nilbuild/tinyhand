#!/usr/bin/env python3
"""Build TinyHand feature screenshots from the app's real parts.

* pointer, ink and laser: rendered by tinyhand-core (examples/scene.rs)
* toolbar and Settings: the app's own ui/*.html, rendered by Chrome with a
  mocked Tauri bridge
* backgrounds: sample lesson slides in marketing/slides

Usage:  python3 marketing/make_screens.py <out dir>
Needs:  cargo, Google Chrome, Pillow.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent  # desktop/
REPO = ROOT.parent
UI = ROOT / "ui"
SLIDES = Path(__file__).resolve().parent / "slides"
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
W, H = 1600, 1000


def chrome(*args):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                    "--virtual-time-budget=4000", *args], check=True, capture_output=True)


def screenshot(url, out, size, scale=1, transparent=False):
    extra = ["--default-background-color=00000000"] if transparent else []
    chrome(f"--window-size={size[0]},{size[1]}", f"--force-device-scale-factor={scale}", *extra, f"--screenshot={out}", url)


def measure(url, ids, size=(W, H)):
    """Bounding boxes of elements by id, in CSS px."""
    html = Path(url[len("file://"):]).read_text()
    probe = ("<script>addEventListener('load',()=>setTimeout(()=>{const o={};for(const id of %s){const r=document.getElementById(id).getBoundingClientRect();"
             "o[id]=[r.left,r.top,r.width,r.height]}document.title=JSON.stringify(o)},300))</script>" % json.dumps(ids))
    tmp = Path(url[len("file://"):]).with_suffix(".probe.html")
    tmp.write_text(html.replace("</body>", probe + "</body>"))
    out = subprocess.run([CHROME, "--headless=new", "--allow-file-access-from-files", "--virtual-time-budget=4000",
                          f"--window-size={size[0]},{size[1]}", "--dump-dom", f"file://{tmp}"], capture_output=True, text=True).stdout
    tmp.unlink()
    raw = re.search(r"<title>(.*?)</title>", out, re.S).group(1)
    return json.loads(raw.replace("&quot;", '"'))


def cargo_example(name):
    subprocess.run(["cargo", "build", "-q", "--release", "-p", "tinyhand-core", "--example", name], cwd=ROOT, check=True)
    return ROOT / "target" / "release" / "examples" / name


def scene(binary, script, out):
    subprocess.run([str(binary)], input=script, text=True, check=True, cwd=ROOT)
    return Image.open(out).convert("RGBA")


TAURI_MOCK = """<script>
window.__TAURI__ = {core: {invoke: async (c, a) => c === 'get_state' ? structuredClone(%s) : null,
  convertFileSrc: id => 'thumbs/' + id + '.png'}, event: {listen: () => {}}};
</script>
"""


def ui_page(work, name, state, extra=""):
    src = (UI / name).read_text()
    src = src.replace('<script src="i18n.js"></script>', TAURI_MOCK % json.dumps(state) + '<script src="i18n.js"></script>', 1)
    src = src.replace("</body>", extra + "</body>")
    page = work / ("mock_" + name)
    page.write_text(src)
    return page


def state_for(lang, style="lavender"):
    catalog = (ROOT / "core" / "src" / "catalog.rs").read_text()
    hands = re.findall(r'h\("(\w+)", "([^"]+)", (\w+)\)', catalog)
    styles = [{"id": i, "title": t, "ink": "#8754f2"} for i, t, _ in hands] + [{"id": "laser", "title": "Laser dot", "ink": "#ff291f"}]
    pinned = ["lavender", "glove", "coral", "plush", "robot", "laser"]
    return {
        "active": True,
        "prefs": {"style": style, "pinned": pinned, "pointerSize": 0.13, "showShadow": True, "fadeSeconds": 3, "handSound": True,
                  "laserSound": False, "tapSound": "thock", "interactKey": "alt", "ink": "match", "welcomed": True, "language": lang},
        "styles": styles, "defaultPinned": pinned,
        "sounds": [["thock", "Thock"], ["click", "Click"], ["pop", "Pop"], ["wood", "Wood block"], ["boop", "Boop"], ["squeak", "Squeak"]],
        "inks": [["match", "Match the pointer", None], ["red", "Red", "#ff291f"], ["orange", "Orange", "#ff8a00"], ["yellow", "Yellow", "#ffcc00"],
                 ["green", "Green", "#30c25a"], ["blue", "Blue", "#0a84ff"], ["purple", "Purple", "#8754f2"], ["white", "White", "#ffffff"],
                 ["black", "Black", "#1d1d21"]],
        "launchAtLogin": False, "version": "0.1.0", "build": "", "platformReady": True,
    }


def crop_alpha(img):
    return img.crop(img.getbbox())


def save(img, out):
    img.convert("RGB").save(out, "WEBP", quality=88, method=6)
    print("wrote", out, img.size)


def main():
    out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "screens").resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="tinyhand-screens-"))
    try:
        scene_bin = cargo_example("scene")
        thumbs_bin = cargo_example("thumbs")
        (work / "thumbs").mkdir()
        subprocess.run([str(thumbs_bin), str(work / "thumbs"), "128"], check=True, cwd=ROOT)
        for f in ("i18n.js", "icon.png"):
            shutil.copy(UI / f, work / f)

        def slide(name, scale=1):
            shot = work / f"{name}@{scale}.png"
            screenshot(f"file://{SLIDES / (name + '.html')}", shot, (W, H), scale=scale)
            return Image.open(shot).convert("RGBA")

        def overlay(script, base, scale=1):
            ov = scene(scene_bin, f"screen {W * scale} {H * scale}\n{script}\nrender {work / 'ov.png'}\n", work / "ov.png")
            img = base.copy()
            img.alpha_composite(ov)
            return img

        # 1. Point: the hand rests on the unknown in the exercise.
        r = measure(f"file://{SLIDES / 'math.html'}", ["q"])["q"]
        q = (r[0] + r[2] * 0.45, r[1] + r[3] * 0.62)
        save(overlay(f"hand lavender\nsize 0.15\nmove {q[0]:.0f} {q[1]:.0f}", slide("math")), out_dir / "point.webp")

        # 2. Tap: pressed on answer C.
        r = measure(f"file://{SLIDES / 'quiz.html'}", ["c"])["c"]
        c = (r[0] + r[2] * 0.8, r[1] + r[3] * 0.5)
        save(overlay(f"hand coral\nsize 0.15\nmove {c[0]:.0f} {c[1]:.0f}\npress", slide("quiz")), out_dir / "tap.webp")

        # 3. Draw: circle one word, underline another.
        m = measure(f"file://{SLIDES / 'english.html'}", ["elephant", "monkey"])
        e, k = m["elephant"], m["monkey"]
        loop = f"loop {e[0] + e[2] / 2:.0f} {e[1] + e[3] / 2:.0f} {e[2] / 2 + 8:.0f} {e[3] / 2 + 3:.0f}"
        y = k[1] + k[3] * 0.92
        underline = f"draw {k[0] - 4:.0f} {y:.0f} {k[0] + k[2] * 0.5:.0f} {y + 3:.0f} {k[0] + k[2] + 6:.0f} {y - 2:.0f}"
        save(overlay(f"hand plush\nink e8590c\nsize 0.15\n{loop}\n{underline}\nmove {k[0] + k[2] + 40:.0f} {y + 40:.0f}", slide("english")),
             out_dir / "draw.webp")

        # 4. Laser dot on the tallest bar. The dot is small on a real screen,
        # so render at 2x and crop around it, like zooming in.
        r = measure(f"file://{SLIDES / 'chart.html'}", ["topval"])["topval"]
        dot = (r[0] + r[2] / 2 + 34, r[1] + r[3] * 0.35)
        # size 0.20 is the largest the Settings slider allows.
        big = overlay(f"laser\nsize 0.20\nmove {dot[0] * 2:.0f} {dot[1] * 2:.0f}", slide("chart", 2), 2)
        x0 = int(min(max(dot[0] * 2 - W * 0.62, 0), W))
        y0 = int(min(max(dot[1] * 2 - H * 0.24, 0), H))
        save(big.crop((x0, y0, x0 + W, y0 + H)), out_dir / "laser.webp")

        # 5. Toolbar: the real toolbar at the bottom; the laser dot hovers the
        # robot hand, about to switch to it (a hand would cover the bar).
        tb_state = state_for("vi", "laser")
        tb_page = ui_page(work, "toolbar.html", tb_state,
                          "<script>setTimeout(()=>{const b=[...document.querySelectorAll('#styles button')][4].getBoundingClientRect();"
                          "document.title=JSON.stringify([b.left,b.top,b.width,b.height])},400)</script>")
        screenshot(f"file://{tb_page}", work / "toolbar.png", (700, 200), scale=2, transparent=True)
        dom = subprocess.run([CHROME, "--headless=new", "--allow-file-access-from-files", "--virtual-time-budget=4000",
                              "--window-size=700,200", "--dump-dom", f"file://{tb_page}"], capture_output=True, text=True).stdout
        btn = [v * 2 for v in json.loads(re.search(r"<title>(.*?)</title>", dom).group(1))]
        tb_full = Image.open(work / "toolbar.png").convert("RGBA")
        box = tb_full.getbbox()
        tb = tb_full.crop(box)
        # Everything at 2x, then crop the bottom of the screen: a close-up.
        base = slide("english", 2)
        tx, ty = (W * 2 - tb.width) // 2, H * 2 - tb.height - 56
        base.alpha_composite(tb, (tx, ty))
        bx = tx + (btn[0] - box[0]) + btn[2] * 0.5
        by = ty + (btn[1] - box[1]) + btn[3] * 0.45
        big = overlay(f"laser\nsize 0.20\nmove {bx:.0f} {by:.0f}", base, 2)
        # Close-up around the bar, 16:10, scaled to the common width.
        cw = int(tb.width * 1.3)
        ch = cw * H // W
        x0 = tx + tb.width // 2 - cw // 2
        y0 = min(ty + tb.height + 40, H * 2) - ch
        save(big.crop((x0, y0, x0 + cw, y0 + ch)).resize((W, H), Image.LANCZOS), out_dir / "toolbar.webp")

        # 6. Settings, Pointer section, in each language.
        for lang in ("vi", "en"):
            st = state_for(lang, "coral")
            page = ui_page(work, "settings.html", st,
                           "<script>setTimeout(()=>{const s=document.querySelector('section').getBoundingClientRect();"
                           "document.title=JSON.stringify([s.left,s.top,s.width,s.height])},600)</script>")
            shot = work / f"settings_{lang}.png"
            screenshot(f"file://{page}", shot, (640, 1300), scale=2)
            dom = subprocess.run([CHROME, "--headless=new", "--allow-file-access-from-files", "--virtual-time-budget=4000",
                                  "--window-size=640,1300", "--dump-dom", f"file://{page}"], capture_output=True, text=True).stdout
            s = json.loads(re.search(r"<title>(.*?)</title>", dom).group(1))
            img = Image.open(shot).convert("RGBA")
            pad = 16
            top = max(0, s[1] - pad)
            img = img.crop((0, int(top * 2), img.width, int(min(s[1] + 640, 1300) * 2)))
            save(img, out_dir / f"settings-{lang}.webp")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
