"""Gera o icone do app (1024x1024, sem transparencia) em ios/App/Assets.xcassets.

Desenho: sinal de integral branco que vira ondas de som, sobre gradiente indigo.
Uso: python ios/tools/make_icon.py   (requer Pillow)
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersampling para bordas suaves
S = SIZE * SS
OUT = Path(__file__).resolve().parents[1] / "App" / "Assets.xcassets"


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def background() -> Image.Image:
    top, bottom = (52, 40, 140), (12, 10, 38)
    grad = Image.new("RGB", (1, 256))
    for y in range(256):
        grad.putpixel((0, y), lerp(top, bottom, y / 255))
    img = grad.resize((S, S), Image.BICUBIC)
    # brilho suave no canto superior esquerdo
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((-S * 0.35, -S * 0.45, S * 0.75, S * 0.55), fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
    img.paste((120, 110, 255), mask=glow)
    return img


def cubic(p0, p1, p2, p3, n=400):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t**3 * p3[1]
        pts.append((x * S, y * S))
    return pts


def stroke(draw: ImageDraw.ImageDraw, pts, width, fill):
    # pincel redondo carimbado ao longo do caminho (sem frestas nas curvas)
    r = width / 2
    step = max(1.0, r / 6)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(x1 - x0, y1 - y0) / step))
        for k in range(n + 1):
            x, y = x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n
            draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def arc(draw, cx, cy, radius, width, fill, span=38):
    pts = []
    for i in range(121):
        a = math.radians(-span + 2 * span * i / 120)
        pts.append(((cx + radius * math.cos(a)) * S, (cy + radius * math.sin(a)) * S))
    stroke(draw, pts, width * S, fill)


def main() -> None:
    img = background()
    d = ImageDraw.Draw(img)
    white = (255, 255, 255)

    # integral: S alongado com as pontas curvadas
    upper = cubic((0.50, 0.20), (0.44, 0.13), (0.38, 0.22), (0.38, 0.36))
    middle = cubic((0.38, 0.36), (0.38, 0.50), (0.35, 0.56), (0.35, 0.64))
    lower = cubic((0.35, 0.64), (0.35, 0.78), (0.29, 0.87), (0.23, 0.80))
    stroke(d, upper + middle[1:] + lower[1:], 0.075 * S, white)

    # ondas de som saindo do meio da integral
    cx, cy = 0.44, 0.50
    for i, (r, alpha) in enumerate(((0.14, 255), (0.24, 200), (0.34, 140))):
        col = lerp((12, 10, 38), (190, 200, 255), alpha / 255)
        arc(d, cx, cy, r, 0.045 - i * 0.006, col)

    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    icon_dir = OUT / "AppIcon.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    img.save(icon_dir / "icon-1024.png", optimize=True)
    (icon_dir / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon-1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n", encoding="utf-8")
    (OUT / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    print("ok:", icon_dir / "icon-1024.png")


if __name__ == "__main__":
    main()
