"""Synthetic IC-package photographs for exercising the real OCR pipeline.

These are NOT real photographs. They render marking text the way it appears on
a moulded IC package (light etched glyphs on a dark epoxy body), then apply the
field degradations the pipeline claims to handle: rotation, blur, low light,
specular glare, sensor noise, small glyphs, several chips in one frame.

They exist so the OCR -> match -> verdict chain can be run end to end with the
real Tesseract engine in CI. Passing on these images is necessary, not
sufficient: real laser-etched packages under a phone camera are harder, which is
why docs/FIELD_ACCEPTANCE_TEST.md requires a physical-device test as well.
"""
from __future__ import annotations

import io
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"


def _font(size: int):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:  # pragma: no cover - font missing on some CI images
        return ImageFont.load_default()


def chip(lines: list[str], *, glyph: int = 46, rotate: float = 0.0, blur: float = 0.0,
         brightness: float = 1.0, glare: bool = False, noise: int = 0,
         body=(28, 28, 30), ink=(205, 205, 200), seed: int = 7) -> Image.Image:
    rnd = random.Random(seed)
    f = _font(glyph)
    width = max(int(f.getlength(t)) for t in lines) + glyph * 2
    height = int(len(lines) * glyph * 1.45) + glyph * 2
    img = Image.new("RGB", (width, height), body)
    d = ImageDraw.Draw(img)
    # pin-1 dot, as on a real package
    d.ellipse((glyph // 3, glyph // 3, glyph // 3 + glyph // 3, glyph // 3 + glyph // 3),
              fill=(55, 55, 58))
    y = glyph
    for t in lines:
        d.text((glyph, y), t, font=f, fill=ink)
        y += int(glyph * 1.45)
    if glare:
        g = Image.new("L", img.size, 0)
        gd = ImageDraw.Draw(g)
        cx, cy = int(width * 0.7), int(height * 0.3)
        gd.ellipse((cx - glyph, cy - glyph // 2, cx + glyph, cy + glyph // 2), fill=255)
        g = g.filter(ImageFilter.GaussianBlur(glyph // 3))
        img = Image.composite(Image.new("RGB", img.size, (255, 255, 255)), img, g)
    if rotate:
        img = img.rotate(rotate, resample=Image.BICUBIC, expand=True, fillcolor=(90, 110, 90))
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(blur))
    if brightness != 1.0:
        img = img.point(lambda v: max(0, min(255, int(v * brightness))))
    if noise:
        px = img.load()
        for _ in range(img.size[0] * img.size[1] // 6):
            x, y = rnd.randrange(img.size[0]), rnd.randrange(img.size[1])
            r, g_, b = px[x, y]
            n = rnd.randint(-noise, noise)
            px[x, y] = (max(0, min(255, r + n)),) * 3
    return img


def board(chips: list[Image.Image], pad: int = 60) -> Image.Image:
    """Several packages on one green PCB, side by side."""
    w = sum(c.size[0] for c in chips) + pad * (len(chips) + 1)
    h = max(c.size[1] for c in chips) + pad * 2
    img = Image.new("RGB", (w, h), (30, 90, 45))
    x = pad
    for c in chips:
        img.paste(c, (x, pad))
        x += c.size[0] + pad
    return img


def jpeg(img: Image.Image, quality: int = 90) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()
