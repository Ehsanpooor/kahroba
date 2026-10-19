"""Bring the host's table design pieces (folder "new gen") into the game.

Run:  python tools/prepare_design.py

Every piece is cropped to what is visible, cleaned of near-zero alpha specks
and saved under assets/splendor/hud/ with a fixed name the game asks for.
The clock is kept whole (its ring centre is measured on the full image).
"""
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "new gen"))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets", "splendor", "hud"))

# source file -> (output name, longest side, rotate degrees, crop to visible)
PIECES = {
    "ChatGPT Image Oct 18, 2026, 09_42_43 AM.png": ("card_blue", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 09_42_46 AM.png": ("card_red", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 09_42_52 AM.png": ("card_green", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 09_43_02 AM.png": ("card_black", 256, 0, True),
    "Emerald Leather Ornate UI Banner.png": ("panel_me", 2100, 0, True),
    "Ornate Cognac Leather Card Frame.png": ("panel_seat", 1640, 90, True),
    "Ornate Brown Leather Heraldic Banner-2.png": ("banner_seat", 420, 0, True),
    "Ornate Golden Medieval Banner.png": ("banner_me", 420, 0, True),
    "Steampunk Golden Clockwork UI Frame.png": ("clock", 720, 0, False),
    # the board design (Frame 45, second round)
    "board with hole.png": ("board", 1600, 0, False),
    "Carved Stone UI Panel.png": ("slot", 512, 0, True),
    "Luxury Emerald Leather Game Tabletop.png": ("table", 2048, 0, False),
    "ChatGPT Image Oct 18, 2026, 07_44_31 PM-1.png": ("back_1", 512, 0, True),
    "ChatGPT Image Oct 18, 2026, 07_44_34 PM-2.png": ("back_2", 512, 0, True),
    "ChatGPT Image Oct 18, 2026, 07_44_38 PM-3.png": ("back_3", 512, 0, True),
    # tokens: with the gem (the 3D chips) and plain, with room for a number
    "ChatGPT Image Oct 18, 2026, 05_57_54 PM-1.png": ("tok_white", 512, 0, True),
    "ChatGPT Image Oct 18, 2026, 06_52_59 PM.png": ("tok_blue", 512, 0, True),
    "ChatGPT Image Oct 18, 2026, 06_53_07 PM.png": ("tok_red", 512, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_58_01 PM-4.png": ("tok_green", 512, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_58_03 PM-5.png": ("tok_black", 512, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_58_05 PM-6 copy.png": ("tok_gold", 512, 0, True),
    "Layer 1.png": ("num_white", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_57_57 PM-2.png": ("num_blue", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_57_59 PM-3.png": ("num_red", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_58_01 PM-4 copy 2.png": ("num_green", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_58_03 PM-5 copy 2.png": ("num_black", 256, 0, True),
    "ChatGPT Image Oct 18, 2026, 05_58_05 PM-6 copy 2.png": ("num_gold", 256, 0, True),
}


def clean_alpha(im):
    r, g, b, a = im.split()
    return Image.merge("RGBA", (r, g, b, a.point(lambda v: 0 if v <= 2 else v)))


def main():
    os.makedirs(OUT, exist_ok=True)
    for src, (name, size, rot, crop) in PIECES.items():
        path = os.path.join(SRC, src)
        if not os.path.exists(path):
            print("missing", src)
            continue
        im = clean_alpha(Image.open(path).convert("RGBA"))
        if rot:
            im = im.rotate(rot, expand=True)
        if crop:
            box = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
            im = im.crop(box)
        im.thumbnail((size, size), Image.LANCZOS)
        im.save(os.path.join(OUT, name + ".png"), optimize=True)
        print("  ", name, im.size)


if __name__ == "__main__":
    main()
