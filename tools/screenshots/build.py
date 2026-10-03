"""Build the README images from the captures take.sh writes.

    python3 build.py <captures dir> <assets/screenshots dir>

Each image is built only when all its captures exist, so a partial retake
rebuilds what it can. Full-screen captures (5120x2880 on a 5K display, or
whatever the main display gives) are scaled to 2560x1440; the grids put four
captures, or two, side by side at half that size. Also writes contact.jpg in
the captures dir: every image, small, for a last look before committing.
"""
import os
import sys

from PIL import Image

SHOTS, ASSETS = sys.argv[1], sys.argv[2]
W, H = 2560, 1440


def cap(name):
    return Image.open(os.path.join(SHOTS, name + ".png")).convert("RGB")


def full(name):
    return cap(name).resize((W, H), Image.LANCZOS)


def grid(names, rows=2):
    w, h = W // 2, H // 2
    out = Image.new("RGB", (W, h * rows))
    for i, n in enumerate(names):
        out.paste(cap(n).resize((w, h), Image.LANCZOS), ((i % 2) * w, (i // 2) * h))
    return out


IMAGES = {
    "tiling.jpg": (["tiling-main"], lambda: full("tiling-main")),
    "themes.jpg": (["tiling-main", "tiling-2", "tiling-3", "tiling-4"],
                   lambda: grid(["tiling-main", "tiling-2", "tiling-3", "tiling-4"])),
    "theme-picker.jpg": (["theme-picker"], lambda: full("theme-picker")),
    "learn.jpg": (["learn-menu"], lambda: full("learn-menu")),
    "plugins.jpg": (["radio-atlas", "weather"], lambda: grid(["radio-atlas", "weather"], rows=1)),
    "terminals.jpg": (["terminals"], lambda: full("terminals")),
    "wallpapers.jpg": (["hero"], lambda: full("hero")),
    "wallpapers-more.jpg": (["wall-1", "wall-2", "wall-3", "wall-4"],
                            lambda: grid(["wall-1", "wall-2", "wall-3", "wall-4"])),
    "agents.jpg": (["agents"], lambda: full("agents")),
}

built = []
for name, (needs, make) in IMAGES.items():
    if not all(os.path.exists(os.path.join(SHOTS, n + ".png")) for n in needs):
        print("[shots] skipped %s (missing captures)" % name)
        continue
    im = make()
    im.save(os.path.join(ASSETS, name), quality=85, optimize=True, progressive=True)
    built.append(name)
    print("[shots] built %s %dx%d" % (name, im.width, im.height))

if built:
    tw, th = 800, 450
    sheet = Image.new("RGB", (3 * tw, ((len(built) + 2) // 3) * th))
    for i, name in enumerate(built):
        im = Image.open(os.path.join(ASSETS, name))
        im.thumbnail((tw, th))
        sheet.paste(im, ((i % 3) * tw, (i // 3) * th))
    sheet.save(os.path.join(SHOTS, "contact.jpg"), quality=80)
    print("[shots] contact sheet: %s" % os.path.join(SHOTS, "contact.jpg"))
