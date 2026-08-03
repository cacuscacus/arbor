#!/usr/bin/env python3
"""Build the Arbor macOS app icon from app_icon_proposal.png.

Crops the squircle artwork out of the proposal render, applies a clean
rounded-rect alpha mask, centers it on a transparent 1024x1024 canvas
(824px artwork per Apple HIG) and emits every size required by
apps/macos/Arbor/Assets.xcassets/AppIcon.appiconset.

Usage:  .venv-icon/bin/python scripts/build_app_icon.py
Requires: Pillow (python3 -m venv .venv-icon && .venv-icon/bin/pip install Pillow)
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "app_icon_proposal.png"
APPICONSET = ROOT / "apps/macos/Arbor/Assets.xcassets/AppIcon.appiconset"

# Squircle bounds measured in the 1664x928 proposal render.
CROP_BOX = (461, 87, 1201, 827)  # 740x740
CORNER_RADIUS = 166  # ~22.4% of 740, matches the artwork's corners

CANVAS = 1024
ARTWORK = 824  # HIG: rounded-rect artwork inset on the 1024 canvas

# (filename, pixel size) for each slot in the appiconset.
SLOTS = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def rounded_mask(size: int, radius: int) -> Image.Image:
    """Anti-aliased rounded-rect alpha mask via 4x supersampling."""
    ss = 4
    mask = Image.new("L", (size * ss, size * ss), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        [0, 0, size * ss - 1, size * ss - 1], radius=radius * ss, fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def build_master() -> Image.Image:
    face = Image.open(SOURCE).convert("RGBA").crop(CROP_BOX)
    face.putalpha(rounded_mask(face.width, CORNER_RADIUS))
    artwork = face.resize((ARTWORK, ARTWORK), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - ARTWORK) // 2
    canvas.paste(artwork, (offset, offset), artwork)
    return canvas


def main() -> None:
    master = build_master()
    APPICONSET.mkdir(parents=True, exist_ok=True)

    images = []
    for filename, px in SLOTS:
        master.resize((px, px), Image.LANCZOS).save(APPICONSET / filename)
        size_label = filename.split("@")[0].removeprefix("icon_")
        scale = "2x" if "@2x" in filename else "1x"
        images.append({"idiom": "mac", "scale": scale, "size": size_label,
                       "filename": filename})

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (APPICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

    for filename, _ in SLOTS:
        print("wrote", APPICONSET / filename)


if __name__ == "__main__":
    main()
