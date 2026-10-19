"""Bring the generated UI art (art/generated/ui3) into the game.

Run:  python tools/prepare_ui.py

Each piece is cropped to what is visible (the generator leaves wide
transparent margins and near-zero alpha specks), cleaned, and saved to
assets/splendor/ui/<name>.png at most MAX px on its long side. Backgrounds
are kept whole. Only new or changed files are written.
"""
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "art", "generated", "ui3"))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets", "splendor", "ui"))
MAX = 1024
WHOLE = ("menu_bg", "screen_bg")  # no cropping, kept large
BIG = {"menu_bg": 2400, "screen_bg": 2400, "dialog_header": 1600, "dialog_footer": 1600, "logo_emblem": 1200,
       "logo_splendor": 1800, "logo_splendor_mark": 1024}


def main():
    os.makedirs(OUT, exist_ok=True)
    n = 0
    for f in sorted(os.listdir(SRC)):
        if not f.lower().endswith(".png"):
            continue
        base = os.path.splitext(f)[0]
        name = base[:-3] if base[-3:-1] == "_v" else base
        src = os.path.join(SRC, f)
        out = os.path.join(OUT, name + ".png")
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            continue
        im = Image.open(src)
        if name in WHOLE:
            im = im.convert("RGB")
        else:
            im = im.convert("RGBA")
            r, g, b, a = im.split()
            a = a.point(lambda v: 0 if v <= 8 else v)
            im = Image.merge("RGBA", (r, g, b, a))
            box = a.point(lambda v: 255 if v > 8 else 0).getbbox()
            if box:
                im = im.crop(box)
        lim = BIG.get(name, MAX)
        im.thumbnail((lim, lim), Image.LANCZOS)
        im.save(out, optimize=True)
        n += 1
        print("  ", name, im.size)
    print(f"{n} file(s) updated in {OUT}")
    avatars()


def avatars():
    """The 30 player avatars -> assets/portraits/A-xx.png (512 px, opaque)."""
    src = os.path.normpath(os.path.join(SRC, "..", "avatars"))
    out_dir = os.path.normpath(os.path.join(OUT, "..", "..", "portraits"))
    if not os.path.isdir(src):
        return
    n = 0
    for f in sorted(os.listdir(src)):
        if not f.lower().endswith(".png"):
            continue
        base = os.path.splitext(f)[0]
        name = base[:-3] if base[-3:-1] == "_v" else base
        out = os.path.join(out_dir, name + ".png")
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(os.path.join(src, f)):
            continue
        im = Image.open(os.path.join(src, f)).convert("RGB")
        im.thumbnail((512, 512), Image.LANCZOS)
        im.save(out, optimize=True)
        n += 1
    print(f"{n} avatar(s) updated in {out_dir}")


if __name__ == "__main__":
    main()
