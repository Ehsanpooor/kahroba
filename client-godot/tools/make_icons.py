"""Make the app icons from the gem crest (logo_splendor_mark).

Run:  python tools/make_icons.py

Source: art/generated/ui3/logo_splendor_mark.png (the full-size original),
or assets/splendor/ui/logo_splendor_mark.png when that is missing.
Output: assets/icon/
  icon.png                 512  project icon (window / taskbar, boot)
  icon_192.png             192  Android launcher icon (legacy, full square)
  adaptive_fg_432.png      432  Android adaptive foreground (crest in the safe zone, transparent)
  adaptive_bg_432.png      432  Android adaptive background (plain dark)
  adaptive_mono_432.png    432  Android 13 themed (monochrome) icon
  splendor.ico             16-256 Windows exe icon
"""
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, ".."))
SOURCES = [
    os.path.normpath(os.path.join(PROJECT, "..", "art", "generated", "ui3", "logo_splendor_mark.png")),
    os.path.join(PROJECT, "assets", "splendor", "ui", "logo_splendor_mark.png"),
]
OUT = os.path.join(PROJECT, "assets", "icon")
BG = (11, 11, 10, 255)  # #0b0b0a, the boot splash colour


def crest():
    for p in SOURCES:
        if os.path.exists(p):
            im = Image.open(p).convert("RGBA")
            box = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
            return im.crop(box) if box else im
    raise SystemExit("logo_splendor_mark.png not found")


def place(canvas_px, mark, width_k, bg):
    """The crest centred on a square canvas, `width_k` of its side wide."""
    c = Image.new("RGBA", (canvas_px, canvas_px), bg)
    w = round(canvas_px * width_k)
    h = round(w * mark.height / mark.width)
    m = mark.resize((w, h), Image.LANCZOS)
    c.alpha_composite(m, ((canvas_px - w) // 2, (canvas_px - h) // 2))
    return c


def main():
    os.makedirs(OUT, exist_ok=True)
    mark = crest()
    clear = (0, 0, 0, 0)
    place(512, mark, 0.84, BG).save(os.path.join(OUT, "icon.png"), optimize=True)
    place(192, mark, 0.84, BG).save(os.path.join(OUT, "icon_192.png"), optimize=True)
    # adaptive: the launcher masks a 432 px layer to its middle ~288 px (safe zone 264)
    place(432, mark, 0.62, clear).save(os.path.join(OUT, "adaptive_fg_432.png"), optimize=True)
    Image.new("RGBA", (432, 432), BG).save(os.path.join(OUT, "adaptive_bg_432.png"), optimize=True)
    mono = place(432, mark, 0.62, clear)
    a = mono.getchannel("A")
    white = Image.new("RGBA", mono.size, (255, 255, 255, 255))
    white.putalpha(a)
    white.save(os.path.join(OUT, "adaptive_mono_432.png"), optimize=True)
    # Windows: dark square with the crest, all the usual sizes in one .ico
    big = place(256, mark, 0.9, BG)
    big.save(os.path.join(OUT, "splendor.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons written to", OUT)


if __name__ == "__main__":
    main()
