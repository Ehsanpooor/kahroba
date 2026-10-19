"""Make the game's images light for phones: drop unused art, downscale every
kept image to the size it is actually drawn at, and pick its import
compression.

Run (after any tools/prepare_*.py, which copy new art in at large sizes):

    python tools/optimize_assets.py            # do it
    python tools/optimize_assets.py --dry-run  # only report

then let Godot re-import:

    <godot> --headless --path . --import

What it does, in order:
1. DROP: files the game never loads (old Veynoria art, retired Splendor
   pieces) are moved to ../_asset_backup/<same relative path>, with their
   .import files. The prepare scripts may copy some of them back; this puts
   them away again.
2. SIZES: each image is shrunk (never enlarged) to fit the box of the first
   matching rule. The boxes are about 1.25x the largest size the image is drawn
   at on a 2400 x 1080 screen (the design size), see the notes per rule.
   Before a file is shrunk for the first time its original is copied to
   ../_asset_backup/originals/<same relative path>.
3. IMPORT: sets compress/mode + compress/lossy_quality in each .import file
   (Lossy WebP for paintings and plates, Lossless for small crisp or
   text-like pieces). A new image without an .import file gets the project's
   importer default (Lossy 0.88) on its first import; rerun this script
   after that import to apply its own rule.

Note: every texture goes through Tex.get_tex(), which decompresses it and
builds mipmaps at load time, so VRAM compression would gain nothing; the
import modes here only decide how the pictures are stored in the package.
"""
import argparse
import fnmatch
import os
import re
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, ".."))
ASSETS = os.path.join(PROJECT, "assets")
BACKUP = os.path.normpath(os.path.join(PROJECT, "..", "_asset_backup"))
ORIGINALS = os.path.join(BACKUP, "originals")

IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp")

# compression presets: (compress/mode, lossy_quality)  mode 0 = Lossless, 1 = Lossy (WebP)
PHOTO = (1, 0.88)     # opaque paintings: card art, avatars, nobles, backgrounds
PLATE = (1, 0.9)      # painted UI plates / frames (WebP keeps their alpha lossless)
CRISP = (0, 0.88)     # small crisp or text-like art: logo, gems, pips, icons, badges

# --------------------------------------------------------------------- drop
# Paths (globs, relative to assets/) the game never loads. Checked against the
# scripts on 2026-10-19: Hud / Card / CardView / CoinSpot / Noble (the old
# Veynoria board) are never instantiated; Portraits.available() is true, so
# old ids (H-07, M-12, ...) resolve to the A-xx avatars and their own files
# are never loaded.
DROP = [
    "models/*", "models_hq/*",          # noble.gd 3D models (Noble is never built)
    "portraits/[DEHMV]-*",               # old character portraits
    "frames/*", "nobles/*", "persons/*", "coins/*", "digits/*", "table/*",  # old board art
    "ui/icons/*",                        # old icon set (the kit's splendor/ui/icon_* cover every icon used)
    "fonts/RobotoSlab.ttf", "fonts/LICENSE-RobotoSlab.txt",  # not in fonts.gd
    # old menu kit; only crop_dialog.gd still uses ui.gd: btn_dark, btn_gold, slider_track, slider_knob
    "ui/btn_blue.png", "ui/btn_green.png", "ui/btn_red.png", "ui/button_*.png", "ui/chip*.png",
    "ui/chooser_ring.png", "ui/crest.png", "ui/*_banner.png", "ui/feature_*.png", "ui/guide.png",
    "ui/jail_icon.png", "ui/loading_bg.jpg", "ui/logo_word.png", "ui/medal_*.png", "ui/medallion.png",
    "ui/menu_bg.jpg", "ui/prestige_icon.png", "ui/profile.png", "ui/ready_*.png", "ui/results_scroll.png",
    "ui/row_plate.png", "ui/seal.png", "ui/seat_frame.png", "ui/settings.png", "ui/sheet_frame.png",
    "ui/speech_panel.png", "ui/tap_hand.png", "ui/title_plaque.png", "ui/toggle_*.png",
    # retired Splendor pieces (prepare_splendor.py still copies them)
    "splendor/areas/*",                  # nothing loads them
    "splendor/frames/*",                 # Gems.frame_tex() is never called ("gem frames are retired")
    "splendor/tokens/*",                 # chips use splendor/hud/tok_*
    "splendor/table/*",                  # Gems.table_tex() is never called; the table is hud/table.png
    "splendor/card_backs/*",             # only a fallback when hud/back_N.png is missing
]

# -------------------------------------------------------------------- sizes
# (glob relative to assets/, max box (w, h) or None = never resize, compression, why)
# First match wins. "drawn" = largest on-screen size at 2400 x 1080.
RULES = [
    # full-screen backgrounds (cover 2400 x 1080)
    ("splendor/ui/menu_bg.png", (2400, 1080), PHOTO, "full-screen backdrop"),
    ("splendor/ui/screen_bg.png", (2400, 1080), PHOTO, "full-screen backdrop"),
    ("splendor/hud/table.png", (2400, 1080), PHOTO, "3D table, covers the screen"),
    # the board and the players' panels
    ("splendor/hud/board.png", (1600, 1600), PLATE, "board drawn ~1290 x 640"),
    ("splendor/hud/panel_me.png", (2400, 400), PLATE, "your panel drawn 1957 x 248"),
    ("splendor/hud/panel_seat.png", (880, 880), PLATE, "seat panel drawn 694 x 287"),
    ("splendor/hud/banner_*.png", (220, 220), PLATE, "score banner drawn <= 155"),
    ("splendor/hud/clock.png", (620, 620), PLATE, "turn clock 310 x 377 on the table, 400 x 490 in How to play"),
    ("splendor/hud/back_*.png", (512, 512), PHOTO, "deck / card backs, 340 x 250 in How to play"),
    ("splendor/hud/slot.png", (320, 320), PLATE, "card slot ~220 x 160"),
    ("splendor/hud/card_*.png", (192, 192), PLATE, "bonus card icon drawn <= 81 x 115"),
    ("splendor/hud/num_*.png", (192, 192), PLATE, "token with count drawn <= 115"),
    ("splendor/hud/tok_*.png", (256, 256), PLATE, "3D chips ~80, How to play tokens 170"),
    # cards, nobles, gems
    ("splendor/cards/*", (600, 600), PHOTO, "card art ~180 on the board, ~440 when inspected (2x)"),
    ("splendor/nobles/*", (512, 512), PHOTO, "noble 420 in its dialog, 460 in How to play"),
    ("splendor/gems/*", (256, 256), CRISP, "gem on cards <= 175 inspected, kit gems <= 120"),
    ("splendor/pips/*", (128, 128), CRISP, "cost medallion <= 96 inspected"),
    # avatars
    ("portraits/A-*.png", (512, 512), PHOTO, "avatar face <= 312 (welcome), image ~370"),
    # the UI kit
    ("splendor/ui/logo_splendor.png", (1800, 1800), CRISP, "splash logo box 1500 x 600"),
    ("splendor/ui/logo_emblem.png", (1000, 1000), PLATE, "fallback emblem box 760 x 560"),
    ("splendor/ui/logo_splendor_mark.png", (512, 512), CRISP, "app icon source only (assets/icon/)"),
    ("splendor/ui/dialog_body.png", (1024, 1024), PLATE,
     "9-slice: corner = 16.7% of its width must stay >= 15% of the largest dialog's short side (~880)"),
    ("splendor/ui/dialog_header.png", (1600, 1600), PLATE, "dialog crest up to ~1300 wide"),
    ("splendor/ui/dialog_footer.png", (1600, 1600), PLATE, "footer up to ~1180 wide"),
    ("splendor/ui/btn_*_[sml].png", (1200, 200), PLATE, "plate buttons drawn <= 160 high (ends scale with height)"),
    ("splendor/ui/btn_onyx_plate.png", (1200, 200), PLATE, "onyx plate drawn <= 160 high"),
    ("splendor/ui/btn_round_*.png", (256, 256), PLATE, "round buttons <= 170"),
    ("splendor/ui/btn_square_onyx.png", (256, 256), PLATE, "(not used yet)"),
    ("splendor/ui/btn_arrow_*.png", (256, 256), PLATE, "arrow buttons <= 150"),
    ("splendor/ui/btn_back.png", (256, 256), PLATE, "back button 130"),
    ("splendor/ui/btn_close.png", (256, 256), PLATE, "close button <= 140"),
    ("splendor/ui/icon_crown.png", (448, 448), CRISP, "crown 340 x 300 in How to play"),
    ("splendor/ui/icon_*.png", (160, 160), CRISP, "icons on buttons <= 82"),
    ("splendor/ui/medal_*.png", (320, 320), PLATE, "medal 240 in How to play"),
    ("splendor/ui/badge_*.png", (320, 320), CRISP, "win / loss badge 220 x 110"),
    ("splendor/ui/mode_*.png", (900, 900), PLATE, "mode tiles 560 x 717"),
    ("splendor/ui/avatar_frame.png", (512, 512), PLATE, "avatar frame <= 400"),
    ("splendor/ui/portrait_frame.png", (512, 512), PLATE, "table avatar frame ~210"),
    ("splendor/ui/page_dot_*.png", (96, 96), CRISP, "page dots"),
    ("splendor/ui/toggle_*.png", (400, 400), PLATE, "switch 270 x 102"),
    ("splendor/ui/slider_knob.png", (128, 128), CRISP, "resized at runtime to 2.1 x the slider height (84)"),
    ("splendor/ui/slider_*.png", (640, 640), PLATE, "slider groove 500 x 40"),
    ("splendor/ui/tab_*.png", (1024, 128), PLATE, "tabs <= 100 high (ends scale with height)"),
    ("splendor/ui/row_*.png", (1024, 160), PLATE, "list rows 116 high"),
    ("splendor/ui/input_field.png", (1024, 160), PLATE, "name field 900 x 140"),
    ("splendor/ui/title_ribbon.png", (1400, 1400), PLATE, "title ribbon 1100 wide"),
    ("splendor/ui/score_badge.png", (256, 256), PLATE, "(not used yet)"),
    ("splendor/ui/*", (1024, 1024), PLATE, "other kit pieces"),
    # what is left of the old kit (crop_dialog.gd -> ui.gd)
    ("ui/btn_*.png", (1000, 140), PLATE, "photo crop dialog buttons 110 high"),
    ("ui/slider_track.png", None, PLATE, "ui.gd uses a fixed 60 px 9-slice margin: keep its size"),
    ("ui/slider_knob.png", None, CRISP, "160 px, resized at runtime"),
    # app icons are made by tools/make_icons.py at their exact sizes
    ("icon/*", None, CRISP, "app icons"),
]

SLACK = 1.02  # leave images within 2 % of their box alone


def rel(path):
    return os.path.relpath(path, ASSETS).replace(os.sep, "/")


def rule_for(r):
    for glob, box, comp, why in RULES:
        if fnmatch.fnmatch(r, glob):
            return box, comp, why
    return None


def backup(path, root):
    """Copy `path` (and its .import) to root/<path relative to the project>."""
    for p in (path, path + ".import"):
        if not os.path.exists(p):
            continue
        dst = os.path.join(root, os.path.relpath(p, PROJECT))
        if os.path.exists(dst):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(p, dst)


def drop(dry):
    n = 0
    freed = 0
    for dirpath, dirs, files in os.walk(ASSETS):
        for f in files:
            if f.endswith(".import"):
                continue
            path = os.path.join(dirpath, f)
            r = rel(path)
            if r.startswith("audio/"):
                continue
            if not any(fnmatch.fnmatch(r, g) for g in DROP):
                continue
            n += 1
            freed += os.path.getsize(path)
            print("  drop", r)
            if dry:
                continue
            dst = os.path.join(BACKUP, os.path.relpath(path, PROJECT))
            if os.path.exists(dst):  # an older copy is already there: keep both
                k = 2
                while os.path.exists(f"{dst}.{k}"):
                    k += 1
                dst = f"{dst}.{k}"
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(path, dst)
            if os.path.exists(path + ".import"):
                shutil.move(path + ".import", dst + ".import")
    # remove folders left empty
    if not dry:
        for dirpath, dirs, files in os.walk(ASSETS, topdown=False):
            if dirpath != ASSETS and not os.listdir(dirpath):
                os.rmdir(dirpath)
    print(f"{n} unused file(s) {'would be ' if dry else ''}moved to {BACKUP} ({freed / 1e6:.1f} MB)")


def fit(size, box):
    w, h = size
    k = min(box[0] / w, box[1] / h, 1.0)
    return max(1, round(w * k)), max(1, round(h * k))


def set_import(path, comp, dry):
    imp = path + ".import"
    if not os.path.exists(imp):
        return "no .import yet"
    with open(imp, encoding="utf-8") as fh:
        text = fh.read()
    mode, q = comp
    new = re.sub(r"(?m)^compress/mode=.*$", f"compress/mode={mode}", text)
    new = re.sub(r"(?m)^compress/lossy_quality=.*$", f"compress/lossy_quality={q}", new)
    if new == text:
        return ""
    if not dry:
        with open(imp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(new)
    return "import " + ("lossless" if mode == 0 else f"lossy {q}")


def optimize(dry):
    before = after = 0
    unmatched = []
    for dirpath, dirs, files in os.walk(ASSETS):
        for f in sorted(files):
            if not f.lower().endswith(IMAGE_EXT):
                continue
            path = os.path.join(dirpath, f)
            r = rel(path)
            if r.startswith("audio/"):
                continue
            if not args.no_drop and any(fnmatch.fnmatch(r, g) for g in DROP):
                continue  # (only reached in a dry run)
            rule = rule_for(r)
            if rule is None:
                unmatched.append(r)
                continue
            box, comp, why = rule
            size0 = os.path.getsize(path)
            before += size0
            notes = []
            with Image.open(path) as im:
                im.load()
                src_size = im.size
                if box and (im.width > box[0] * SLACK or im.height > box[1] * SLACK):
                    new_size = fit(im.size, box)
                    notes.append(f"{im.width}x{im.height} -> {new_size[0]}x{new_size[1]}")
                    if not dry:
                        backup(path, ORIGINALS)
                        mode = "RGBA" if im.mode in ("RGBA", "LA", "P") else "RGB"
                        out = im.convert(mode).resize(new_size, Image.LANCZOS)
                        if path.lower().endswith((".jpg", ".jpeg")):
                            out.convert("RGB").save(path, quality=92, optimize=True)
                        else:
                            out.save(path, optimize=True)
            s = set_import(path, comp, dry)
            if s:
                notes.append(s)
            after += os.path.getsize(path)
            if notes:
                print(f"  {r}: {', '.join(notes)}  ({why})")
            elif args.verbose:
                print(f"  {r}: ok {src_size[0]}x{src_size[1]}")
    for r in unmatched:
        print("  NO RULE (left as is):", r)
    print(f"images: {before / 1e6:.1f} MB -> {after / 1e6:.1f} MB")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="only report what would change")
    ap.add_argument("--no-drop", action="store_true", help="do not move unused files away")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    if not os.path.isdir(ASSETS):
        sys.exit("assets folder not found: " + ASSETS)
    if not args.no_drop:
        drop(args.dry_run)
    optimize(args.dry_run)
