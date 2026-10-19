"""Bring the website art (art/generated/web) into the download page (deploy/web/img).

Run:  python deploy/prepare_web.py

Each painting is cropped to what is visible (transparent ones), sized for the
page and saved as WebP. Missing pieces are skipped: the page keeps whatever
image already sits in img/.
"""
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "art", "generated", "web"))
OUT = os.path.join(HERE, "web", "img")

# source -> (page name, longest side, quality, keeps transparency)
PLAN = {
    "hero_mobile.png": ("hero_mobile.webp", 1600, 78, False),
    "hero_wide.png": ("hero_wide.webp", 2400, 78, False),
    "gem_diamond.png": ("gem_white.webp", 640, 86, True),
    "gem_sapphire.png": ("gem_blue.webp", 640, 86, True),
    "gem_emerald.png": ("gem_green.webp", 640, 86, True),
    "gem_ruby.png": ("gem_red.webp", 640, 86, True),
    "gem_onyx.png": ("gem_black.webp", 640, 86, True),
    "divider.png": ("divider.webp", 1200, 88, True),
    "frame_landscape.png": ("frame.webp", 1800, 88, True),
    "leather.jpg": ("leather.webp", 1024, 80, False),
    "leather.png": ("leather.webp", 1024, 80, False),
    "seal.png": ("seal.webp", 700, 88, True),
    "portrait_merchant.png": ("portrait_merchant.webp", 1200, 82, False),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for src, (dst, side, q, alpha) in PLAN.items():
        p = os.path.join(SRC, src)
        if not os.path.exists(p):
            continue
        im = Image.open(p)
        if alpha:
            im = im.convert("RGBA")
            box = im.getchannel("A").point(lambda v: 255 if v > 10 else 0).getbbox()
            if box:
                im = im.crop(box)
        else:
            im = im.convert("RGB")
        im.thumbnail((side, side), Image.LANCZOS)
        im.save(os.path.join(OUT, dst), "WEBP", quality=q, method=6)
        print(f"  {dst:24s} {im.size}  {os.path.getsize(os.path.join(OUT, dst)) // 1024} KB")
    # the picture shared links show
    hero = os.path.join(SRC, "hero_wide.png")
    if os.path.exists(hero):
        im = Image.open(hero).convert("RGB")
        im.thumbnail((1200, 1200))
        w, h = im.size
        th = round(w / 1.91)
        im.crop((0, max((h - th) // 2, 0), w, max((h - th) // 2, 0) + min(th, h))).save(os.path.join(OUT, "og.jpg"), quality=82)


if __name__ == "__main__":
    main()
