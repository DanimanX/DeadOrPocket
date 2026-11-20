#!/usr/bin/env python3
"""Generate SpaceFish-style monochrome README banner, Pocket platform banner
(model2.bin, 521x165 rotated 90 CCW 16-bit LE grayscale), and Pocket core icon
(icon.bin, 36x36 16-bit LE grayscale) from the Kasumi source artwork.
"""
import math
import os
import struct
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

ROOT = Path("/PROCESOS/DeadOrPocket")
SRC = ROOT / "docs" / "kasumi_raw.jpg"

FONT_TITLE = "/usr/share/fonts/TTF/Roboto-BlackItalic.ttf"
FONT_SUB   = "/usr/share/fonts/TTF/RobotoCondensed-Bold.ttf"
FONT_MONO  = "/usr/share/fonts/liberation/LiberationMono-Bold.ttf"


def extract_kasumi_rgba(src_path: Path) -> Image.Image:
    """Load Kasumi artwork and remove ONLY the border-connected white studio
    backdrop via flood-fill so bright skin highlights and white fabric remain
    100% intact."""
    from collections import deque
    im = Image.open(src_path).convert("RGBA")
    px = im.load()
    w, h = im.size

    def is_bg(r, g, b):
        mx = max(r, g, b)
        mn = min(r, g, b)
        return ((r + g + b) // 3) > 224 and (mx - mn) < 22

    visited = bytearray(w * h)
    q = deque()
    # Seed flood-fill from all 4 outer edges
    for x in range(w):
        for y in (0, h - 1):
            r, g, b, _ = px[x, y]
            if is_bg(r, g, b):
                idx = y * w + x
                if not visited[idx]:
                    visited[idx] = 1
                    q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            r, g, b, _ = px[x, y]
            if is_bg(r, g, b):
                idx = y * w + x
                if not visited[idx]:
                    visited[idx] = 1
                    q.append((x, y))

    while q:
        x, y = q.popleft()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < w and 0 <= ny < h:
                idx = ny * w + nx
                if not visited[idx]:
                    r, g, b, _ = px[nx, ny]
                    if is_bg(r, g, b):
                        visited[idx] = 1
                        q.append((nx, ny))

    # Build clean alpha mask and slightly feather 1-2 px on outer edge
    mask = Image.new("L", (w, h), 255)
    mpx = mask.load()
    for y in range(h):
        row = y * w
        for x in range(w):
            if visited[row + x]:
                mpx[x, y] = 0
    # Slight erosion/blur to kill white halo fringe
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.2))
    im.putalpha(mask)
    return im


def make_readme_banner(kasumi_rgba: Image.Image) -> Image.Image:
    """Create 1280x720 high-contrast grayscale banner matching SpaceFish style."""
    W, H = 1280, 720
    bg = Image.new("L", (W, H), 12)
    draw = ImageDraw.Draw(bg)

    # Vertical sky/horizon gradient
    for y in range(H):
        if y < 440:
            v = int(10 + 48 * ((y / 440.0) ** 1.7))
        else:
            t = (y - 440) / (H - 440.0)
            v = int(26 + 18 * (1.0 - t))
        draw.line([(0, y), (W, y)], fill=v)

    # Subtle radial spotlight behind Kasumi (x ~ 930, y ~ 300)
    spot = Image.new("L", (W, H), 0)
    spx = spot.load()
    cx, cy = 935, 310
    for y in range(0, H, 2):
        dy2 = (y - cy) * (y - cy)
        for x in range(400, W, 2):
            d = math.sqrt((x - cx) * (x - cx) + dy2)
            if d < 460:
                val = int(115 * ((1.0 - d / 460.0) ** 1.8))
                spx[x, y] = val
                if x + 1 < W: spx[x + 1, y] = val
                if y + 1 < H: spx[x, y + 1] = val
                if x + 1 < W and y + 1 < H: spx[x + 1, y + 1] = val
    # Composite additive spotlight
    bg_px = bg.load()
    for y in range(H):
        for x in range(400, W):
            nv = bg_px[x, y] + spx[x, y]
            if nv > 255: nv = 255
            bg_px[x, y] = nv

    # Perspective Sega Model 2 wireframe floor grid (y = 440..720)
    horizon_y = 440
    draw.line([(0, horizon_y), (W, horizon_y)], fill=170, width=2)
    for i in range(1, 14):
        y = int(horizon_y + (H - horizon_y) * ((i / 13.0) ** 2.0))
        draw.line([(0, y), (W, y)], fill=75 + min(90, i * 6), width=1)
    vp_x = 580
    for k in range(-14, 18):
        bx = vp_x + k * 150
        draw.line([(vp_x, horizon_y), (bx, H)], fill=70, width=1)

    # Diagonal high-contrast speed slash accent
    draw.polygon([(700, 0), (760, 0), (610, H), (550, H)], fill=28)
    draw.line([(700, 0), (550, H)], fill=120, width=2)
    draw.line([(760, 0), (610, H)], fill=80, width=1)

    # Paste Kasumi (cropped nicely from head to thighs, converted to crisp B&W)
    kw, kh = kasumi_rgba.size
    crop = kasumi_rgba.crop((0, 0, kw, int(kh * 0.72)))
    target_h = 700
    target_w = int(crop.width * (target_h / crop.height))
    crop = crop.resize((target_w, target_h), Image.LANCZOS)

    k_gray = crop.convert("L")
    k_gray = ImageEnhance.Brightness(k_gray).enhance(0.94)
    k_gray = ImageEnhance.Contrast(k_gray).enhance(1.12)
    k_gray = ImageEnhance.Sharpness(k_gray).enhance(1.18)
    k_alpha = crop.split()[3]

    # Subtle outer white rim glow around Kasumi
    glow = k_alpha.filter(ImageFilter.GaussianBlur(10))
    glow_layer = Image.new("L", (W, H), 0)
    kx = W - target_w - 75
    ky = 20
    glow_layer.paste(glow, (kx, ky))
    gl_px = glow_layer.load()
    for y in range(H):
        for x in range(max(0, kx - 20), W):
            add = gl_px[x, y] // 4
            if add:
                nv = bg_px[x, y] + add
                bg_px[x, y] = 255 if nv > 255 else nv

    bg.paste(k_gray, (kx, ky), k_alpha)

    # Gentle CRT scanlines (22% darkening instead of solid black so facial features stay crisp)
    for y in range(0, H, 3):
        for x in range(W):
            bg_px[x, y] = (bg_px[x, y] * 200) >> 8

    # Typography on left side
    f_big   = ImageFont.truetype(FONT_TITLE, 108)
    f_big2  = ImageFont.truetype(FONT_TITLE, 118)
    f_sub   = ImageFont.truetype(FONT_SUB, 30)
    f_mono  = ImageFont.truetype(FONT_MONO, 20)

    # Shadow + crisp white title
    def shadow_text(pos, txt, font, fill=248, sh=8, off=5):
        draw.text((pos[0] + off, pos[1] + off), txt, font=font, fill=sh)
        draw.text(pos, txt, font=font, fill=fill)

    shadow_text((56, 128), "DEAD OR", f_big, fill=235)
    shadow_text((52, 232), "POCKET", f_big2, fill=255)

    # Accent bar
    draw.rectangle([(58, 372), (615, 380)], fill=235)
    shadow_text((58, 396), "SEGA MODEL 2 & 2A-CRX · HYBRID openFPGA", f_sub, fill=225, off=3)

    # Tech badge pill (bottom-left, echoing SpaceFish badge layout)
    draw.rounded_rectangle([(56, 560), (545, 658)], radius=10, fill=14, outline=220, width=3)
    draw.text((78, 578), "ANALOGUE POCKET  ·  5CEBA4F23C8", font=f_mono, fill=240)
    draw.text((78, 614), "COMPUTE CARTRIDGE + 60 FPS RENDER", font=f_mono, fill=175)

    return bg


def make_platform_banner_img(kasumi_rgba: Image.Image) -> Image.Image:
    """521x165 high-contrast grayscale Pocket platform banner (model2.bin)."""
    W, H = 521, 165
    im = Image.new("L", (W, H), 0)
    draw = ImageDraw.Draw(im)

    # Subtle frame lines
    draw.line([(0, 12), (W, 12)], fill=90, width=1)
    draw.line([(0, H - 12), (W, H - 12)], fill=90, width=1)

    # Crop Kasumi head+shoulders tightly for the right side
    kw, kh = kasumi_rgba.size
    bust = kasumi_rgba.crop((int(kw * 0.05), 0, int(kw * 0.95), int(kh * 0.44)))
    th = H - 6
    tw = int(bust.width * (th / bust.height))
    bust = bust.resize((tw, th), Image.LANCZOS)
    b_gray = ImageEnhance.Contrast(bust.convert("L")).enhance(1.35)
    b_alpha = bust.split()[3]
    im.paste(b_gray, (W - tw - 10, 3), b_alpha)

    f_t = ImageFont.truetype(FONT_TITLE, 48)
    f_s = ImageFont.truetype(FONT_SUB, 20)
    draw.text((22, 26), "SEGA MODEL 2", font=f_t, fill=255)
    draw.line([(24, 88), (336, 88)], fill=200, width=2)
    draw.text((24, 100), "DEAD OR POCKET · 2 / 2A-CRX", font=f_s, fill=195)
    draw.text((24, 126), "HYBRID 60 FPS openFPGA", font=f_s, fill=135)
    return im


def make_icon_img(kasumi_rgba: Image.Image) -> Image.Image:
    """36x36 crisp high-contrast Kasumi portrait icon for Analogue Pocket."""
    kw, kh = kasumi_rgba.size
    # Tight portrait crop around face & collar
    face = kasumi_rgba.crop((int(kw * 0.16), 0, int(kw * 0.78), int(kh * 0.30)))
    icon = Image.new("L", (36, 36), 0)
    face_fit = ImageOps.fit(face, (36, 36), Image.LANCZOS, centering=(0.5, 0.25))
    fg = ImageEnhance.Contrast(face_fit.convert("L")).enhance(1.45)
    fg = ImageEnhance.Sharpness(fg).enhance(1.4)
    icon.paste(fg, (0, 0), face_fit.split()[3])
    return icon


def write_pocket_bin(im_l: Image.Image, out_path: Path, rotate_ccw: bool):
    if rotate_ccw:
        im_l = im_l.rotate(90, expand=True)
    data = b"".join(struct.pack("<H", g) for g in im_l.getdata())
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(data)
    print(f"Wrote {out_path} ({im_l.width}x{im_l.height}, {len(data)} bytes)")


def main():
    kasumi = extract_kasumi_rgba(SRC)

    banner = make_readme_banner(kasumi)
    banner.save(ROOT / "banner.png")
    banner.save(ROOT / "docs" / "banner_bw.png")
    print("Wrote banner.png and docs/banner_bw.png (1280x720 L)")

    plat = make_platform_banner_img(kasumi)
    plat.save(ROOT / "docs" / "platform_model2_preview.png")
    write_pocket_bin(plat, ROOT / "apf" / "Platforms" / "_images" / "model2.bin", rotate_ccw=True)

    icon = make_icon_img(kasumi)
    icon.save(ROOT / "docs" / "icon_preview.png")
    write_pocket_bin(icon, ROOT / "apf" / "Cores" / "danimanx.DeadOrPocket" / "icon.bin", rotate_ccw=False)


if __name__ == "__main__":
    main()
