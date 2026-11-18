#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
"""Generates the TexPad app icon (1024x1024, no alpha) into the asset catalog."""
import json, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SET = os.path.join(ROOT, "TexPad", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(SET, exist_ok=True)

S = 2048  # draw at 2x, downscale for smooth edges
img = Image.new("RGB", (S, S))

# vertical gradient: indigo -> blue
top, bot = (58, 54, 190), (14, 118, 224)
px = img.load()
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    for x in range(S):
        px[x, y] = c

# soft shadow + white page
page = (430, 330, 1618, 1718)   # x0, y0, x1, y1
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((page[0], page[1] + 40, page[2], page[3] + 40), radius=90, fill=(0, 0, 40, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(40))
img = Image.alpha_composite(img.convert("RGBA"), shadow)
d = ImageDraw.Draw(img)
d.rounded_rectangle(page, radius=90, fill=(255, 255, 255, 255))

# folded corner
fold = 230
d.polygon([(page[2] - fold, page[1]), (page[2], page[1] + fold), (page[2] - fold, page[1] + fold)], fill=(222, 228, 245, 255))
d.polygon([(page[2] - fold, page[1]), (page[2] - fold, page[1] + fold), (page[2], page[1] + fold)], fill=(222, 228, 245, 255))

# "TeX" mark with the lowered E
font_path = "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf"
big = ImageFont.truetype(font_path, 470)
ink = (22, 30, 92, 255)

def adv(ch): return d.textlength(ch, font=big)
em = 470
wT, wE, wX = adv("T"), adv("E"), adv("X")
total = wT + wE + wX - 0.1667 * em - 0.125 * em
x = (page[0] + page[2]) / 2 - total / 2
base_y = 760
d.text((x, base_y), "T", font=big, fill=ink)
x += wT - 0.1667 * em
d.text((x, base_y + 0.23 * em), "E", font=big, fill=ink)   # lowered
x += wE - 0.125 * em
d.text((x, base_y), "X", font=big, fill=ink)

# text lines below, like a document
line_x0, line_x1 = page[0] + 130, page[2] - 130
for i, (w, col) in enumerate([(1.0, (186, 196, 226)), (0.86, (186, 196, 226)), (0.62, (186, 196, 226))]):
    y = 1330 + i * 105
    d.rounded_rectangle((line_x0, y, line_x0 + (line_x1 - line_x0) * w, y + 44), radius=22, fill=col + (255,))
# accent: blinking-cursor bar after the last line
cx = line_x0 + (line_x1 - line_x0) * 0.62 + 36
d.rounded_rectangle((cx, 1330 + 2 * 105 - 14, cx + 20, 1330 + 2 * 105 + 58), radius=8, fill=(255, 140, 40, 255))

out = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
out.save(os.path.join(SET, "icon-1024.png"))

with open(os.path.join(SET, "Contents.json"), "w") as f:
    json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
               "info": {"author": "xcode", "version": 1}}, f, indent=2)
with open(os.path.join(ROOT, "TexPad", "Assets.xcassets", "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
print("wrote", os.path.join(SET, "icon-1024.png"))
