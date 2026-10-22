"""Make the app icons from Homa's portrait with three gems.

Run:  python tools/make_icons.py

Source: store/icon_homa_source.png (square painting, full bleed).
Output: assets/icon/
  icon.png                 512  project icon (window / taskbar, boot)
  icon_192.png             192  Android launcher icon (legacy, full square)
  adaptive_fg_432.png      432  Android adaptive foreground (the painting, sized so
                                the launcher's mask shows her face and the gems)
  adaptive_bg_432.png      432  Android adaptive background (the painting, darkened)
  adaptive_mono_432.png    432  Android 13 themed (monochrome) icon
  splendor.ico             16-256 Windows exe icon
"""
import os

from PIL import Image, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, ".."))
SOURCE = os.path.normpath(os.path.join(PROJECT, "..", "store", "icon_homa_source.png"))
OUT = os.path.join(PROJECT, "assets", "icon")
# The launcher shows roughly the middle two thirds of an adaptive layer, so the
# painting is drawn at this share of the layer: her face and the three gems
# then stay inside every mask shape (circle, squircle, rounded square).
ADAPTIVE_K = 0.8
ADAPTIVE_DOWN = 10  # px: her face sits high in the painting, so it moves down a little


def square(im, px):
    return im.resize((px, px), Image.LANCZOS)


def main():
    if not os.path.exists(SOURCE):
        raise SystemExit("store/icon_homa_source.png not found")
    os.makedirs(OUT, exist_ok=True)
    art = Image.open(SOURCE).convert("RGBA")
    side = min(art.size)
    art = art.crop(((art.width - side) // 2, (art.height - side) // 2,
                    (art.width + side) // 2, (art.height + side) // 2))
    square(art, 512).save(os.path.join(OUT, "icon.png"), optimize=True)
    square(art, 192).save(os.path.join(OUT, "icon_192.png"), optimize=True)
    # adaptive: the painting, a little smaller than the layer, over a soft
    # darkened copy of itself (so any edge the mask reveals still matches)
    bg = square(art, 432).filter(ImageFilter.GaussianBlur(10))
    bg = ImageEnhance.Brightness(bg).enhance(0.55)
    bg.save(os.path.join(OUT, "adaptive_bg_432.png"), optimize=True)
    fg = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    w = round(432 * ADAPTIVE_K)
    fg.alpha_composite(square(art, w), ((432 - w) // 2, (432 - w) // 2))
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
