"""Turn the raw art in ART_SRC into game-ready textures under client-godot/assets.

Run:  python tools/prepare_assets.py            (all steps)
      python tools/prepare_assets.py --skip-ml  (resize-only; reuses existing cutouts/depth)

Needs: pillow, numpy, rembg, onnxruntime, transformers, torch  (see tools/requirements.txt)
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

ART_SRC = r"C:\projects\veynora gmae\assets"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets"))

PORTRAIT_SIZE = 512
DEPTH_SIZE = 256

# Noble objects only exist inside the board mockup for now. Boxes are in the
# mockup's own pixel space (1572 x 3604). Replace with real art when it lands.
MOCKUP = "iPhone 14 Pro – 4.png"
NOBLE_BOXES = {
    "lantern": (90, 620, 210, 805),
    "mirror": (395, 630, 545, 805),
    "scroll": (665, 635, 905, 812),
    "tome": (1020, 625, 1180, 806),
    "staff": (1370, 620, 1455, 806),
}


def out_path(*parts):
    p = os.path.join(OUT, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def fit(im, max_w=None, max_h=None):
    w, h = im.size
    s = 1.0
    if max_w:
        s = min(s, max_w / w)
    if max_h:
        s = min(s, max_h / h)
    if s < 1.0:
        im = im.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
    return im


def save(im, *parts):
    im.save(out_path(*parts), optimize=True)


def simple_assets():
    src = ART_SRC
    for c in ["black", "blue", "gold", "green", "red", "white"]:
        im = Image.open(os.path.join(src, "getons", f"{c}.png")).convert("RGBA")
        save(im.resize((256, 256), Image.LANCZOS), "coins", f"{c}.png")
    for c in ["blue", "dark", "green", "red", "white"]:
        im = Image.open(os.path.join(src, "persons", f"{c}.png")).convert("RGBA")
        save(fit(im, max_h=128), "persons", f"{c}.png")
    for n in range(1, 10):
        im = Image.open(os.path.join(src, "numbers-gold", f"{n}.png")).convert("RGBA")
        save(fit(im, max_h=128), "digits", f"{n}.png")
    for t in (1, 2, 3):
        im = Image.open(os.path.join(src, "tier-boards", f"tier-{t}.png")).convert("RGBA")
        save(fit(im, max_w=768), "frames", f"tier-{t}.png")
    singles = {
        "avatar.png": ("frames", "avatar_ring.png", 384),
        "circlew-2.png": ("frames", "pip.png", 128),
        "Layer 3.png": ("frames", "badge.png", 128),
        "devider.png": ("frames", "divider.png", 1024),
        "genotes frame.png": ("frames", "coin_tray.png", 1024),
    }
    for name, (folder, dst, w) in singles.items():
        im = Image.open(os.path.join(src, name)).convert("RGBA")
        save(fit(im, max_w=w), folder, dst)
    for name, dst in [("profile-icon.png", "profile.png"), ("setting icon.png", "settings.png")]:
        im = Image.open(os.path.join(src, "menu", name)).convert("RGBA")
        save(fit(im, max_w=160), "ui", dst)
    for i in range(1, 6):
        im = Image.open(os.path.join(src, "menu", f"Layer {i}.png")).convert("RGBA")
        save(fit(im, max_w=640), "ui", f"button_{i}.png")


def portrait_names():
    d = os.path.join(ART_SRC, "character v2")
    return sorted(f for f in os.listdir(d) if f.lower().endswith(".png"))


def clean_id(fname):
    # "H-07 .png" -> "H-07", "H-9.png" -> "H-09"
    stem = os.path.splitext(fname)[0].strip()
    prefix, num = stem.split("-")
    return f"{prefix}-{int(num):02d}" if len(num) < 3 else f"{prefix}-{num}"


def cutouts(only=None):
    from rembg import new_session, remove

    session = new_session("birefnet-portrait")
    d = os.path.join(ART_SRC, "character v2")
    for f in portrait_names():
        pid = clean_id(f)
        if only and pid not in only:
            continue
        im = Image.open(os.path.join(d, f)).convert("RGB")
        cut = remove(im, session=session)
        # tighten the alpha a touch so the old glow halo doesn't ring the edge
        a = cut.getchannel("A").filter(ImageFilter.MinFilter(3))
        cut.putalpha(a)
        save(cut.resize((PORTRAIT_SIZE, PORTRAIT_SIZE), Image.LANCZOS), "portraits", f"{pid}.png")
        print("cutout", pid)
    if not only:
        noble_cutouts()


def generated_assets():
    """Art made for the game (generated/). Overrides mockup crops where present."""
    gen = os.path.join(ART_SRC, "generated")
    if not os.path.isdir(gen):
        return
    for name in NOBLE_BOXES:
        p = os.path.join(gen, f"noble_{name}.png")
        if os.path.exists(p):
            im = Image.open(p).convert("RGBA")
            im = im.crop(im.getchannel("A").getbbox())
            save(fit(im, max_h=512), "nobles", f"{name}.png")
            print("noble (generated)", name)
    # objects that only exist as multi-view sets (made for 3D): cut the front
    # view out of its white background for the 2D uses (info dialog, fallback)
    views = os.path.join(gen, "views")
    for name in ["crown", "orb"]:
        p = os.path.join(views, f"{name}_front.png")
        if os.path.exists(p) and not os.path.exists(os.path.join(gen, f"noble_{name}.png")):
            from rembg import new_session, remove
            cut = remove(Image.open(p).convert("RGB"), session=new_session("birefnet-general"))
            cut = cut.crop(cut.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox())
            save(fit(cut, max_h=512, max_w=512), "nobles", f"{name}.png")
            print("noble (from views)", name)
    p = os.path.join(gen, "table.jpg")
    if os.path.exists(p):
        fit(Image.open(p).convert("RGB"), max_w=1080).save(out_path("table", "table.jpg"), quality=90)
    p = os.path.join(gen, "panel_frame.png")
    if os.path.exists(p):
        im = Image.open(p).convert("RGBA")
        save(fit(im.crop(im.getchannel("A").getbbox()), max_w=1600), "frames", "panel_frame.png")
    p = os.path.join(gen, "opponent_frame.png")
    if os.path.exists(p):
        im = Image.open(p).convert("RGBA")
        # trim with a threshold: the generator leaves faint alpha specks outside the frame
        box = im.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox()
        save(fit(im.crop(box), max_w=1600), "frames", "opponent_frame.png")
    p = os.path.join(gen, "tier_rail.png")
    if os.path.exists(p):
        im = Image.open(p).convert("RGBA")
        im = im.crop(im.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox())
        save(fit(im, max_w=1600), "frames", "tier_rail.png")
    p = os.path.join(gen, "loading_bg.jpg")
    if os.path.exists(p):
        fit(Image.open(p).convert("RGB"), max_w=1080).save(out_path("ui", "loading_bg.jpg"), quality=86)
    ui = {"turn_banner.png": 1200, "prestige_icon.png": 192, "jail_icon.png": 192, "sheet_frame.png": 1100,
          "seal.png": 640, "seat_frame.png": 512, "ready_button.png": 768, "ready_stamp.png": 256,
          "chooser_ring.png": 512, "results_scroll.png": 1100}
    for name, w in ui.items():
        p = os.path.join(gen, name)
        if os.path.exists(p):
            im = Image.open(p).convert("RGBA")
            box = im.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox()
            save(fit(im.crop(box), max_w=w), "ui", name)
    p = os.path.join(gen, "digit_0.png")
    if os.path.exists(p):
        im = Image.open(p).convert("RGBA")
        save(fit(im.crop(im.getchannel("A").getbbox()), max_h=128), "digits", "0.png")
    p = os.path.join(gen, "panel_frame.png")
    if os.path.exists(p):
        # a 9-slice version without the top-centre gem (the gem is drawn on its own,
        # so it never stretches), plus the gem itself
        im = Image.open(p).convert("RGBA")
        im = im.crop(im.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox())
        im = fit(im, max_w=1600)
        w, h = im.size
        gx0, gx1 = int(w * 0.43), int(w * 0.57)
        gy1 = int(h * 0.26)
        gem = im.crop((gx0, 0, gx1, gy1))
        save(gem.crop(gem.getchannel("A").getbbox()), "frames", "panel_gem.png")
        plain = im.crop((int(w * 0.2), 0, int(w * 0.2) + (gx1 - gx0), gy1))
        clean = im.copy()
        clean.paste(plain, (gx0, 0))
        save(clean, "frames", "panel_frame_9.png")
    p = os.path.join(gen, "card_back.png")
    if os.path.exists(p):
        save(fit(Image.open(p).convert("RGBA"), max_w=512), "frames", "card_back.png")


# The icon sheet from the generator: 4 columns x 5 rows, read row by row.
ICON_NAMES = ["swords", "helmet", "friends", "trophy", "scroll", "book", "gear", "menu",
              "arrow", "flag", "speaker", "music", "sun", "eye", "close", "info",
              "hourglass", "crown", "report", "door"]


def menu_assets():
    """The menus: background, logo, crest, and the generated ui/ batch when present."""
    p = os.path.join(ART_SRC, "Group 41.png")
    if os.path.exists(p):
        fit(Image.open(p).convert("RGB"), max_w=1080).save(out_path("ui", "menu_bg.jpg"), quality=86)
    for name, dst, w in [("logo name.png", "logo_word.png", 1200),
                         ("ChatGPT Image Jun 6, 2026, 02_57_43 AM (1).png", "crest.png", 600)]:
        p = os.path.join(ART_SRC, name)
        if os.path.exists(p):
            im = Image.open(p).convert("RGBA")
            save(fit(im.crop(im.getchannel("A").getbbox()), max_w=w), "ui", dst)
    gen = os.path.join(ART_SRC, "generated", "ui")
    if not os.path.isdir(gen):
        return
    sizes = {"btn_": 900, "feature_": 1400, "title_plaque": 1200, "row_plate": 1400, "medal_": 256,
             "medallion": 384, "slider_": 1000, "toggle_": 256, "chip": 400, "guide": 900,
             "speech_panel": 1200, "tap_hand": 256, "victory_banner": 1200, "defeat_banner": 1200}
    # on/off pairs share one crop, so switching state never moves the art
    pairs = {"toggle_on.png": "toggle_off.png", "toggle_off.png": "toggle_on.png",
             "chip.png": "chip_on.png", "chip_on.png": "chip.png"}

    def alpha_box(path):
        return Image.open(path).convert("RGBA").getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox()

    for f in os.listdir(gen):
        if not f.lower().endswith(".png") or f == "icons_sheet.png":
            continue
        w = next((v for k, v in sizes.items() if f.startswith(k)), 1024)
        if f == "slider_knob.png":
            w = 160
        im = Image.open(os.path.join(gen, f)).convert("RGBA")
        box = im.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox()
        if f in pairs and os.path.exists(os.path.join(gen, pairs[f])):
            o = alpha_box(os.path.join(gen, pairs[f]))
            if box and o:
                box = (min(box[0], o[0]), min(box[1], o[1]), max(box[2], o[2]), max(box[3], o[3]))
        if box:
            im = im.crop(box)
        if f == "guide.png":
            save(fit(im, max_h=w), "ui", f)
        else:
            save(fit(im, max_w=w), "ui", f)
    p = os.path.join(gen, "icons_sheet.png")
    if os.path.exists(p):
        im = Image.open(p).convert("RGBA").resize((1024, 1280), Image.LANCZOS)
        cw, ch = im.width / 4.0, im.height / 5.0
        for i, name in enumerate(ICON_NAMES):
            c, r = i % 4, i // 4
            cell = im.crop((round(c * cw), round(r * ch), round((c + 1) * cw), round((r + 1) * ch)))
            box = cell.getchannel("A").point(lambda v: 255 if v > 24 else 0).getbbox()
            if not box:
                continue
            cell = cell.crop(box)
            side = max(cell.size)
            sq = Image.new("RGBA", (side, side))
            sq.alpha_composite(cell, ((side - cell.width) // 2, (side - cell.height) // 2))
            save(sq.resize((160, 160), Image.LANCZOS), "ui", "icons", f"{name}.png")


def noble_cutouts():
    from rembg import new_session, remove

    session = new_session("birefnet-general")
    mock = Image.open(os.path.join(ART_SRC, MOCKUP)).convert("RGB")
    for name, box in NOBLE_BOXES.items():
        if os.path.exists(os.path.join(ART_SRC, "generated", f"noble_{name}.png")):
            continue
        crop = mock.crop(box)
        cut = remove(crop, session=session)
        cut = cut.resize((cut.width * 2, cut.height * 2), Image.LANCZOS)
        save(cut, "nobles", f"{name}.png")
        print("noble", name)


def portrait_meta():
    """Where each figure sits in its square, so cards can align heads to one line.
    Written as a GDScript const so it ships in exports without file IO."""
    d = os.path.join(OUT, "portraits")
    lines = []
    for f in sorted(os.listdir(d)):
        if not f.endswith(".png"):
            continue
        a = np.asarray(Image.open(os.path.join(d, f)).getchannel("A")) > 40
        ys = np.where(a.any(1))[0]
        xs = np.where(a.any(0))[0]
        n = a.shape[0]
        # horizontal centre of the upper body (top 45% of the figure) = the head/torso
        upper = a[ys[0]: ys[0] + int((ys[-1] - ys[0]) * 0.45)]
        uxs = np.where(upper.any(0))[0]
        cx = (uxs[0] + uxs[-1]) / 2 / n if len(uxs) else (xs[0] + xs[-1]) / 2 / n
        lines.append(f'\t"{os.path.splitext(f)[0]}": Vector2({ys[0] / n:.3f}, {cx:.3f}),')
    src = ("# Generated by tools/prepare_assets.py - do not edit.\n"
           "# id -> Vector2(figure top, figure centre x), as fractions of the square.\n"
           "class_name PortraitMeta\nextends RefCounted\n\nconst DATA := {\n"
           + "\n".join(lines) + "\n}\n")
    path = os.path.normpath(os.path.join(HERE, "..", "scripts", "portrait_meta.gd"))
    open(path, "w", encoding="utf-8").write(src)
    print("portrait meta ->", path)


def depth_maps():
    import torch
    from transformers import pipeline

    dev = 0 if torch.cuda.is_available() else -1
    pipe = pipeline("depth-estimation", model="depth-anything/Depth-Anything-V2-Small-hf", device=dev)
    for f in sorted(os.listdir(os.path.join(OUT, "portraits"))):
        cut = Image.open(os.path.join(OUT, "portraits", f)).convert("RGBA")
        rgb = Image.new("RGB", cut.size, (0, 0, 0))
        rgb.paste(cut, mask=cut.getchannel("A"))
        depth = pipe(rgb)["depth"].convert("L").resize(cut.size, Image.BILINEAR)
        dep = np.asarray(depth, dtype=np.float32) / 255.0
        alpha = np.asarray(cut.getchannel("A"), dtype=np.float32) / 255.0
        # normalise only over the figure so every portrait uses the full range
        m = alpha > 0.5
        if m.any():
            lo, hi = np.percentile(dep[m], 2), np.percentile(dep[m], 98)
            dep = np.clip((dep - lo) / max(hi - lo, 1e-4), 0, 1)
        dep *= alpha
        img = Image.fromarray((dep * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2))
        save(img.resize((DEPTH_SIZE, DEPTH_SIZE), Image.LANCZOS), "depth", f)
        print("depth", f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-ml", action="store_true")
    ap.add_argument("--nobles", action="store_true", help="only redo the noble cutouts")
    ap.add_argument("--depth", action="store_true", help="also build portrait depth maps (unused now)")
    ap.add_argument("--only", help="redo just these portraits, e.g. V-05,D-09")
    ap.add_argument("--menu", action="store_true", help="only redo the menu art")
    args = ap.parse_args()
    if args.menu:
        menu_assets()
        return
    if args.only:
        cutouts({x.strip().upper() for x in args.only.split(",")})
        portrait_meta()
        return
    if args.nobles:
        noble_cutouts()
        generated_assets()
        return
    simple_assets()
    if not args.skip_ml:
        cutouts()
        if args.depth:
            depth_maps()
    generated_assets()
    menu_assets()
    portrait_meta()
    print("assets ->", OUT)


if __name__ == "__main__":
    sys.exit(main())
