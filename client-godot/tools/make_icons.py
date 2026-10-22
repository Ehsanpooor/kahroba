"""Make the app icons from the SPLENDOR logo with three gems.

Run:  python tools/make_icons.py

Source: store/icon_logo_source.png (square painting, full bleed).
Output: assets/icon/
  icon.png                 512  project icon (window / taskbar, boot)
  icon_192.png             192  Android launcher icon (legacy, full square)
  adaptive_fg_432.png      432  Android adaptive foreground (the painting, sized so
                                the launcher's mask shows the whole word and the gems)
  adaptive_bg_432.png      432  Android adaptive background (the painting, darkened)
  adaptive_mono_432.png    432  Android 13 themed (monochrome) icon
  splendor.ico             16-256 Windows exe icon
"""
import os

from PIL import Image, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, ".."))
SOURCE = os.path.normpath(os.path.join(PROJECT, "..", "store", "icon_logo_source.png"))
OUT = os.path.join(PROJECT, "assets", "icon")
# The launcher shows roughly the middle 61% of an adaptive layer (a circle in
# the strictest shape), so the painting is drawn at this share of the layer:
# the wide word SPLENDOR and the three gems then stay inside every mask shape.
ADAPTIVE_K = 0.64
ADAPTIVE_DOWN = 0


def square(im, px):
    return im.resize((px, px), Image.LANCZOS)


def main():
    if not os.path.exists(SOURCE):
        raise SystemExit("store/icon_logo_source.png not found")
    os.makedirs(OUT, exist_ok=True)
    art = Image.open(SOURCE).convert("RGBA")
    side = min(art.size)
    art = art.crop(((art.width - side) // 2, (art.height - side) // 2,
                    (art.width + side) // 2, (art.height + side) // 2))
    square(art, 512).save(os.path.join(OUT, "icon.png"), optimize=True)
    square(art, 192).save(os.path.join(OUT, "icon_192.png"), optimize=True)
    # adaptive: the painting, smaller than the layer, over its own plain blue
    # backdrop (the band above the word, softened), so the edges the mask
    # reveals match and no second, blurred word shows behind
    band = art.crop((0, 0, art.width, art.height // 5))
    bg = band.resize((432, 432), Image.LANCZOS).filter(ImageFilter.GaussianBlur(6))
    bg.save(os.path.join(OUT, "adaptive_bg_432.png"), optimize=True)
    fg = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    w = round(432 * ADAPTIVE_K)
    # its top and bottom edges fade out, so no seam shows on the backdrop (the
    # sides stay sharp: the word reaches almost to them)
    soft = Image.new("L", (w, w), 255)
    edge = round(w * 0.12)
    for y in range(edge):
        a = round(255 * y / edge)
        soft.paste(a, (0, y, w, y + 1))
        soft.paste(a, (0, w - 1 - y, w, w - y))
    piece = square(art, w)
    piece.putalpha(soft)
    fg.alpha_composite(piece, ((432 - w) // 2, (432 - w) // 2))
    fg.save(os.path.join(OUT, "adaptive_fg_432.png"), optimize=True)
    # themed icon: a white silhouette of the gems' outline area (Android tints it)
    gray = square(art, w).convert("L").point(lambda v: 255 if v > 150 else 0)
    mono = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    white = Image.new("RGBA", (w, w), (255, 255, 255, 255))
    white.putalpha(gray)
    mono.alpha_composite(white, ((432 - w) // 2, (432 - w) // 2))
    mono.save(os.path.join(OUT, "adaptive_mono_432.png"), optimize=True)
    # Windows: the painting, all the usual sizes in one .ico
    square(art, 256).save(os.path.join(OUT, "splendor.ico"),
                          sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons written to", OUT)


if __name__ == "__main__":
    main()
