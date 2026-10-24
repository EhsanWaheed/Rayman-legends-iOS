#!/usr/bin/env python3
"""The pause menu Help screen's controller, repainted for PlayStation-style pads.

The Help screen (controllerguidexbox) draws the Xbox 360 pad from classicpadtutoxbox_a1.tga: the body in the top
two thirds of a 512x512 atlas, the left stick (drawn over the body's empty socket, animated), the move arrow, the
trigger pieces and the shadow below. The guide's lines end where that layout has its controls: left stick top left,
face buttons top right. This repaints the atlas, piece for piece in the same places:

  backbone   the Backbone One PlayStation Edition (art/backbone_one_source.webp), which has the same layout
  dualsense  a DualSense, from the line drawing art/dualsense_glyph_source.jpg, its face buttons where the lines end
             (its left stick is lower down: see button_prompts.h for the guide's moved stick)

usage: make_pad_art.py <backbone|dualsense> <xbox atlas png> <out png>
"""
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# The Xbox atlas (512x512).
STICK = (80.0, 113.0)          # the left stick socket
FACE = (325.0, 113.0)          # the face buttons' center (X 292,114  B 358,113  Y 326,81  A 325,144)
BODY = (0, 0, 410, 308)        # the body's area
SHADOW = (112, 371, 292, 511)  # the shadow piece's area
BODY_BBOX = (4, 5, 403, 303)   # the Xbox body's extent, to map the shadow
SHADOW_BBOX = (116, 375, 287, 507)
PIECES = {  # the stick pieces: area, center
    'shaft': ((118, 330, 162, 370), (140, 350)),
    'ring': ((165, 321, 226, 377), (195.5, 349)),
    'cap': ((237, 321, 302, 382), (269.5, 351.5)),
}
TRIGGERS = [(318, 321, 357, 342), (321, 357, 357, 390)]

SS = 4  # supersampling for drawn shapes


def rgba(path):
    return Image.open(path).convert('RGBA')


def clear(atlas, box):
    atlas.paste((0, 0, 0, 0), box)


def stick_top(radius, tilt=0.0):
    """A Backbone-style stick seen from above: black, a concave top with a soft rim light."""
    size = int(math.ceil(radius * 2 + 4)) * SS
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = size / 2
    r = radius * SS
    d.ellipse((c - r, c - r + tilt * SS, c + r, c + r + tilt * SS), fill=(14, 15, 18, 255))  # the side
    d.ellipse((c - r, c - r, c + r, c + r), fill=(32, 33, 38, 255))
    d.ellipse((c - r * 0.78, c - r * 0.78, c + r * 0.78, c + r * 0.78), fill=(22, 23, 27, 255))
    # rim light, top left
    d.arc((c - r * 0.92, c - r * 0.92, c + r * 0.92, c + r * 0.92), 190, 280, fill=(92, 94, 102, 255),
          width=max(1, int(r * 0.09)))
    return im.resize((size // SS, size // SS), Image.LANCZOS)


def socket(atlas, center, radius):
    size = int(radius * 2 + 6) * SS
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = size / 2
    r = radius * SS
    d.ellipse((c - r - 2 * SS, c - r - 2 * SS, c + r + 2 * SS, c + r + 2 * SS), fill=(176, 179, 188, 255))
    d.ellipse((c - r, c - r, c + r, c + r), fill=(18, 19, 22, 255))
    im = im.resize((size // SS, size // SS), Image.LANCZOS)
    atlas.alpha_composite(im, (int(round(center[0] - im.width / 2)), int(round(center[1] - im.height / 2))))


def place_body(atlas, body, scale, anchor_src, anchor_dst):
    """Pastes the body image scaled, with anchor_src landing on anchor_dst."""
    w, h = round(body.width * scale), round(body.height * scale)
    scaled = body.resize((w, h), Image.LANCZOS)
    x = round(anchor_dst[0] - anchor_src[0] * scale)
    y = round(anchor_dst[1] - anchor_src[1] * scale)
    layer = Image.new('RGBA', atlas.size, (0, 0, 0, 0))
    layer.paste(scaled, (x, y))
    layer = layer.crop(BODY)
    atlas.alpha_composite(layer, (BODY[0], BODY[1]))
    return layer


def shadow_from(atlas, xbox, body_layer):
    """The shadow piece: the new body's silhouette, mapped as the Xbox body's is, in the Xbox shadow's color."""
    xs = np.asarray(xbox.crop(SHADOW)).astype(float)
    sel = xs[..., 3] > 32
    color = xs[sel][:, :3].mean(axis=0) if sel.any() else np.array([40, 0, 40])
    peak = np.percentile(xs[..., 3][sel], 90) if sel.any() else 100  # a translucent shadow
    alpha = body_layer.split()[3]
    bx0, by0, bx1, by1 = BODY_BBOX
    sx0, sy0, sx1, sy1 = SHADOW_BBOX
    kx, ky = (sx1 - sx0) / (bx1 - bx0), (sy1 - sy0) / (by1 - by0)
    full = Image.new('L', atlas.size, 0)
    full.paste(alpha, (BODY[0], BODY[1]))
    small = full.resize((round(512 * kx), round(512 * ky)), Image.LANCZOS)
    layer = Image.new('L', atlas.size, 0)
    layer.paste(small, (round(sx0 - bx0 * kx), round(sy0 - by0 * ky)))
    layer = layer.filter(ImageFilter.GaussianBlur(2)).point(lambda v: int(v * peak / 255))
    clear(atlas, SHADOW)
    tint = Image.new('RGBA', atlas.size, tuple(int(c) for c in color) + (0,))
    tint.putalpha(layer)
    atlas.alpha_composite(tint.crop(SHADOW), (SHADOW[0], SHADOW[1]))


def stick_pieces(atlas, radius):
    for name, (box, center) in PIECES.items():
        clear(atlas, box)
        im = stick_top(radius, tilt={'shaft': 3.0, 'ring': 0.0, 'cap': 1.5}[name])
        if name == 'shaft':
            # the stick from the side: a short dark column under the cap
            col = Image.new('RGBA', (int(radius * 1.2) * SS, int(radius * 1.4) * SS), (0, 0, 0, 0))
            ImageDraw.Draw(col).rounded_rectangle((0, 0, col.width - 1, col.height - 1), radius * SS * 0.3,
                                                  fill=(20, 21, 25, 255))
            col = col.resize((col.width // SS, col.height // SS), Image.LANCZOS)
            atlas.alpha_composite(col, (int(center[0] - col.width / 2), int(center[1] - col.height / 2)))
            continue
        atlas.alpha_composite(im, (int(round(center[0] - im.width / 2)), int(round(center[1] - im.height / 2))))


def triggers_clear(atlas):
    # The Xbox triggers' press pieces, drawn where the Xbox pad's triggers are: above these pads' bodies.
    for box in TRIGGERS:
        clear(atlas, box)


def backbone(xbox):
    atlas = xbox.copy()
    clear(atlas, BODY)
    src = rgba(sys.path[0] + '/../art/backbone_one_source.webp')
    stick_src, face_src = (278.0, 215.0), (910.0, 212.0)
    scale = (FACE[0] - STICK[0]) / (face_src[0] - stick_src[0])
    # the photo's own left stick out of the way: the socket replaces it (the animated stick is drawn over it)
    body = src.copy()
    layer = place_body(atlas, body, scale, stick_src, STICK)
    socket(atlas, STICK, 12.5 * 1.0)
    shadow_from(atlas, xbox, layer)
    stick_pieces(atlas, 11.5)
    triggers_clear(atlas)
    return atlas


# The DualSense: the line drawing in art/dualsense_glyph_source.jpg (white on black), scaled so its face buttons'
# center lands where the Xbox pad's is; its left stick lower down (button_prompts.h moves the guide's stick and Move
# line there).
DS_SOURCE_FACE = (423.3, 173.0)
DS_SOURCE_STICK = (263.3, 209.0)
DS_SCALE = 1.18


def ds_atlas(x, y):
    return FACE[0] + (x - DS_SOURCE_FACE[0]) * DS_SCALE, FACE[1] + (y - DS_SOURCE_FACE[1]) * DS_SCALE


DUALSENSE_STICK = ds_atlas(*DS_SOURCE_STICK)
LINE = (246, 247, 252)
FILL = (16, 20, 40, 150)


def stick_glyph(radius):
    """The stick as the drawing has it: a dark cap in a white ring, a smaller ring inside."""
    size = int(math.ceil(radius * 2 + 6)) * SS
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c, r, w = size / 2, radius * SS, int(1.6 * SS)
    d.ellipse((c - r, c - r, c + r, c + r), fill=(20, 24, 44, 230), outline=LINE + (255,), width=w)
    r2 = r * 0.62
    d.ellipse((c - r2, c - r2, c + r2, c + r2), outline=LINE + (255,), width=w)
    return im.resize((size // SS, size // SS), Image.LANCZOS)


def dualsense(xbox):
    atlas = xbox.copy()
    clear(atlas, BODY)
    src = Image.open(sys.path[0] + '/../art/dualsense_glyph_source.jpg').convert('L')
    lines = np.asarray(src).astype(np.float32)
    # The controller's inside: everything the lines enclose (the outside reached from the border).
    from scipy import ndimage
    walls = lines > 60
    outside_labels, _ = ndimage.label(~walls)
    border = set(outside_labels[0, :]) | set(outside_labels[-1, :]) | set(outside_labels[:, 0]) | set(outside_labels[:, -1])
    outside = np.isin(outside_labels, [l for l in border if l])
    inside = ~outside
    # The left stick out of the drawing (still inside): the guide's animated stick is drawn there.
    yy, xx = np.mgrid[0:lines.shape[0], 0:lines.shape[1]]
    sx, sy = DS_SOURCE_STICK
    lines[((xx - sx) / 24.0) ** 2 + ((yy - sy) / 21.0) ** 2 <= 1.0] = 0
    # In the atlas: the fill, then the lines.
    h, w = lines.shape
    big = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    fill_alpha = Image.fromarray((inside * FILL[3]).astype(np.uint8))
    big.paste(FILL[:3] + (255,), (0, 0), fill_alpha)
    line_alpha = Image.fromarray(np.clip((lines - 20) * 1.4, 0, 255).astype(np.uint8))
    big.paste(LINE + (255,), (0, 0), line_alpha)
    # alpha where both: lines over the fill
    a = np.maximum(np.asarray(fill_alpha), np.asarray(line_alpha))
    big.putalpha(Image.fromarray(a))
    scaled = big.resize((round(w * DS_SCALE), round(h * DS_SCALE)), Image.LANCZOS)
    x0 = round(FACE[0] - DS_SOURCE_FACE[0] * DS_SCALE)
    y0 = round(FACE[1] - DS_SOURCE_FACE[1] * DS_SCALE)
    layer = Image.new('RGBA', atlas.size, (0, 0, 0, 0))
    layer.paste(scaled, (x0, y0))
    layer = layer.crop(BODY)
    atlas.alpha_composite(layer, (BODY[0], BODY[1]))
    shadow_from(atlas, xbox, layer)
    for name, (box, center) in PIECES.items():
        clear(atlas, box)
        piece = stick_glyph(21 if name != 'shaft' else 12)
        atlas.alpha_composite(piece, (int(round(center[0] - piece.width / 2)), int(round(center[1] - piece.height / 2))))
    triggers_clear(atlas)
    return atlas


def main():
    kind, xbox_path, out = sys.argv[1:4]
    xbox = rgba(xbox_path)
    atlas = {'backbone': backbone, 'dualsense': dualsense}[kind](xbox)
    atlas.save(out)


if __name__ == '__main__':
    main()
