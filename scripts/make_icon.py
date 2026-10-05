#!/usr/bin/env python3
"""Generates App/Resources/Assets.xcassets/AppIcon.appiconset (macOS + iOS) and AccentColor.

The mark is a bold "D" whose counter is a play triangle, on a dark violet gradient.
Usage: python3 scripts/make_icon.py   (requires Pillow)
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..", "App", "Resources", "Assets.xcassets")
ICONSET = os.path.join(ROOT, "AppIcon.appiconset")
SS = 4  # supersampling factor
TOP = (52, 30, 110)
BOTTOM = (10, 8, 28)
ACCENT = (139, 92, 246)


def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = min(1.0, max(0.0, (0.75 * y + 0.25 * x) / size))
            px[x, y] = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    return img


def glyph_mask(size):
    """White D with a play-triangle counter, centred in a size x size canvas."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    w, h = size * 0.52, size * 0.56
    x0, y0 = (size - w) / 2 + size * 0.02, (size - h) / 2
    rx = w * 0.48
    d.rectangle([x0, y0, x0 + w - rx, y0 + h], fill=255)
    d.ellipse([x0 + w - 2 * rx, y0, x0 + w, y0 + h], fill=255)
    # Play triangle cut out of the D.
    cx, cy = x0 + w * 0.47, y0 + h / 2
    th = h * 0.46
    tw = th * 0.9
    d.polygon([(cx - tw * 0.42, cy - th / 2), (cx - tw * 0.42, cy + th / 2), (cx + tw * 0.58, cy)], fill=0)
    return m


def layer(rgb, mask, opacity, offset=(0, 0)):
    out = Image.new("RGBA", mask.size, rgb + (0,))
    alpha = Image.new("L", mask.size, 0)
    alpha.paste(mask.point(lambda v: int(v * opacity)), offset)
    out.putalpha(alpha)
    return out


def master(size, rounded):
    big = size * SS
    bg = gradient(big // 4).resize((big, big), Image.BICUBIC)
    glyph = glyph_mask(big)
    shadow = glyph.filter(ImageFilter.GaussianBlur(big * 0.02))
    canvas = bg.convert("RGBA")
    canvas.alpha_composite(layer((0, 0, 0), shadow, 0.45, (0, int(big * 0.012))))
    canvas.alpha_composite(layer((255, 255, 255), glyph, 1.0))
    if rounded:
        # macOS: rounded rect on the Big Sur grid (824/1024) with a soft drop shadow.
        inset = int(big * 100 / 1024)
        inner = big - 2 * inset
        tile = canvas.resize((inner, inner), Image.LANCZOS)
        mask = Image.new("L", (inner, inner), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, inner - 1, inner - 1], radius=int(inner * 0.225), fill=255)
        sh = Image.new("L", (big, big), 0)
        sh.paste(mask, (inset, inset + int(big * 0.01)))
        sh = sh.filter(ImageFilter.GaussianBlur(big * 0.012))
        out = layer((0, 0, 0), sh, 0.4)
        tile.putalpha(mask)
        out.alpha_composite(tile, (inset, inset))
        canvas = out
    return canvas.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(ICONSET, exist_ok=True)
    images = []
    ios = master(1024, rounded=False).convert("RGB")  # iOS icons must be opaque
    ios.save(os.path.join(ICONSET, "icon-ios-1024.png"))
    images.append({"filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"})

    mac = master(1024, rounded=True)
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon-mac-{pt}@{scale}x.png"
            mac.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})

    with open(os.path.join(ICONSET, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)

    accent = os.path.join(ROOT, "AccentColor.colorset")
    os.makedirs(accent, exist_ok=True)
    comps = {k: f"{v / 255:.3f}" for k, v in zip(("red", "green", "blue"), ACCENT)}
    comps["alpha"] = "1.000"
    with open(os.path.join(accent, "Contents.json"), "w") as f:
        json.dump({"colors": [{"color": {"color-space": "srgb", "components": comps}, "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)
    with open(os.path.join(ROOT, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    main()
