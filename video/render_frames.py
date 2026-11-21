#!/usr/bin/env python3
"""Render demo-video frames for the Aevum Pay demo video.
1280x720, 30fps. Slides + terminal playback.
"""
import os, math, textwrap
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
FPS = 30
OUT = "/home/hatch/workspace/aevum/video/frames"
os.makedirs(OUT, exist_ok=True)

F_MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
F_MONO_B = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
F_SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
F_SANS_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

BG = (13, 17, 23)          # dark navy
BG2 = (22, 27, 34)
ACCENT = (88, 166, 255)    # blue
GREEN = (63, 185, 80)
TEXT = (230, 237, 243)
MUTED = (139, 148, 158)
TERM_BG = (12, 12, 12)
TERM_FG = (200, 200, 200)
TERM_GREEN = (80, 200, 120)
TERM_CYAN = (90, 180, 220)
TERM_YELLOW = (220, 180, 80)
RED = (248, 81, 73)

def font(path, size):
    return ImageFont.truetype(path, size)

def base():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    # subtle top accent bar
    d.rectangle([0, 0, W, 6], fill=ACCENT)
    return img, d

def wrap_text(d, text, fnt, max_w):
    words = text.split()
    lines, cur = [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=fnt) <= max_w:
            cur = t
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines

def slide_title(title, subtitle, footer):
    img, d = base()
    f_t = font(F_SANS_B, 64)
    f_s = font(F_SANS, 30)
    f_f = font(F_MONO, 22)
    # center title
    y = 240
    for line in title.split("\n"):
        tw = d.textlength(line, font=f_t)
        d.text(((W - tw) / 2, y), line, font=f_t, fill=TEXT)
        y += 78
    y += 20
    for line in subtitle.split("\n"):
        tw = d.textlength(line, font=f_s)
        d.text(((W - tw) / 2, y), line, font=f_s, fill=MUTED)
        y += 42
    tw = d.textlength(footer, font=f_f)
    d.text(((W - tw) / 2, H - 70), footer, font=f_f, fill=ACCENT)
    return img

def slide_bullets(heading, bullets, footer=""):
    img, d = base()
    f_h = font(F_SANS_B, 44)
    f_b = font(F_SANS, 28)
    f_f = font(F_MONO, 20)
    d.text((80, 60), heading, font=f_h, fill=TEXT)
    d.rectangle([80, 125, 240, 131], fill=ACCENT)
    y = 170
    for b in bullets:
        # bullet dot
        d.ellipse([80, y + 10, 96, y + 26], fill=ACCENT)
        lines = wrap_text(d, b, f_b, W - 220)
        for ln in lines:
            d.text((120, y), ln, font=f_b, fill=TEXT)
            y += 40
        y += 18
    if footer:
        d.text((80, H - 60), footer, font=f_f, fill=MUTED)
    return img

def slide_code(heading, code_lines, footer="", font_size=24, line_h=36):
    """Dark terminal-style code slide."""
    img, d = base()
    f_h = font(F_SANS_B, 40)
    f_c = font(F_MONO, font_size)
    f_f = font(F_MONO, 20)
    d.text((80, 50), heading, font=f_h, fill=TEXT)
    d.rectangle([80, 110, 240, 116], fill=ACCENT)
    # terminal box
    x0, y0, x1, y1 = 80, 140, W - 80, H - 80
    d.rounded_rectangle([x0, y0, x1, y1], radius=12, fill=TERM_BG, outline=(48, 54, 61), width=2)
    y = y0 + 20
    for ln, color in code_lines:
        d.text((x0 + 28, y), ln, font=f_c, fill=color)
        y += line_h
    if footer:
        d.text((80, H - 60), footer, font=f_f, fill=MUTED)
    return img

def term_frame(lines, prompt="$ "):
    """Render a terminal window with the given (text, color) lines."""
    img = Image.new("RGB", (W, H), TERM_BG)
    d = ImageDraw.Draw(img)
    f_t = font(F_MONO, 22)
    # title bar
    d.rectangle([0, 0, W, 44], fill=(30, 30, 30))
    d.ellipse([20, 15, 34, 29], fill=(255, 95, 86))
    d.ellipse([44, 15, 58, 29], fill=(255, 189, 46))
    d.ellipse([68, 15, 82, 29], fill=(39, 201, 63))
    d.text((110, 10), "agent — node agent.mjs 4 --payer 0x7099…79C8", font=font(F_MONO, 20), fill=MUTED)
    y = 64
    max_lines = 26
    shown = lines[-max_lines:]
    for ln, color in shown:
        # wrap long lines
        wrapped = textwrap.wrap(ln, width=86) or [""]
        for wln in wrapped:
            if y > H - 40:
                break
            d.text((28, y), wln, font=f_t, fill=color)
            y += 28
    return img

def save(img, name):
    img.save(os.path.join(OUT, name))

if __name__ == "__main__":
    print("renderer loaded OK")
