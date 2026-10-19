"""Copy the generated Splendor art into the game, resized for phones.

Run:  python tools/prepare_splendor.py

Source: <project>/art/generated/{tokens,gems,cards,card_backs,nobles,table}
Output: client-godot/assets/splendor/... (same folders and names).
A newer "_v2" (or higher) of a file wins over the original.
Only files that are new or changed are written, so it is quick to re-run.
"""
import os
import re

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "art", "generated"))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets", "splendor"))

# folder -> longest side in px
SIZES = {"tokens": 512, "gems": 256, "cards": 768, "card_backs": 768, "nobles": 512, "table": 2400,
         "frames": 1024, "pips": 256, "areas": 2048, "ui": 512}
# keep the alpha channel for these
ALPHA = ("tokens", "gems", "frames", "pips", "areas", "ui")


def best_versions(folder):
    """{base name: path}, picking the highest _vN of each file."""
    best = {}
    d = os.path.join(SRC, folder)
    if not os.path.isdir(d):
        return best
    for f in os.listdir(d):
        m = re.match(r"^(.*?)(?:_v(\d+))?\.(png|jpg|jpeg|webp)$", f, re.I)
        if not m:
            continue
        base, ver = m.group(1), int(m.group(2) or 1)
        if base not in best or ver > best[base][0]:
            best[base] = (ver, os.path.join(d, f))
    return {k: v[1] for k, v in best.items()}


def clean_alpha(im):
    """Generated transparency leaves near-zero alpha specks; make them fully clear."""
    r, g, b, a = im.split()
    a = a.point(lambda v: 0 if v <= 2 else v)
    return Image.merge("RGBA", (r, g, b, a))


def crop_box(folder, base, im):
    """Crop to what is visible. A seat and its glowing twin share one box, so
    they line up when the glow is shown over the seat."""
    def box(img):
        return img.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox() or (0, 0, img.width, img.height)
    if folder == "areas" and base in ("seat", "seat_glow"):
        boxes = []
        for name in ("seat", "seat_glow"):
            path = best_versions("areas").get(name)
            if path:
                boxes.append(box(clean_alpha(Image.open(path).convert("RGBA"))))
        return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
    return box(im)


def main():
    n = 0
    for folder, size in SIZES.items():
        for base, path in best_versions(folder).items():
            out = os.path.join(OUT, folder, base + ".png")
            if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(path):
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            im = Image.open(path)
            im = im.convert("RGBA" if folder in ALPHA else "RGB")
            if folder in ALPHA:
                im = clean_alpha(im)
            if folder == "areas":
                im = im.crop(crop_box(folder, base, im))
            im.thumbnail((size, size), Image.LANCZOS)
            im.save(out, optimize=True)
            n += 1
            print("  ", folder + "/" + base, im.size)
    print(f"{n} file(s) updated in {OUT}")


if __name__ == "__main__":
    main()
