#!/usr/bin/env python3
"""The pause menu Help screen's controller, repainted for PlayStation-style pads.

The Help screen (controllerguidexbox) draws the Xbox 360 pad from classicpadtutoxbox_a1.tga: the body in the top
two thirds of a 512x512 atlas, the left stick (drawn over the body's empty socket, animated), the move arrow, the
trigger pieces and the shadow below. The guide's lines end where that layout has its controls: left stick top left,
face buttons top right. This repaints the atlas, piece for piece in the same places:

  backbone   the Backbone One PlayStation Edition (art/backbone_one_source.webp), which has the same layout
  dualsense  a DualSense, drawn here, its face buttons where the lines end (its left stick is lower down: see
             button_prompts.h for the guide's moved stick)

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


DUALSENSE_STICK = (145.0, 192.0)  # its left stick (button_prompts.h moves the guide's stick and Move line there)


def dualsense(xbox):
    """A DualSense, drawn: white shell and grips with the D-pad and face buttons, the black middle with the
    sticks and the PS button, the touchpad with its light bars. The face buttons where the Xbox pad's are (the guide's lines end there)."""
    atlas = xbox.copy()
    clear(atlas, BODY)
    k = SS
    W, H = 512 * k, 320 * k
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def P(*v):
        return [c * k for c in v]

    # The shell: the top and the two grips.
    shell = Image.new('L', (W, H), 0)
    sd = ImageDraw.Draw(shell)
    sd.rounded_rectangle(P(10, 36, 402, 176), 62 * k, fill=255)
    for cx, sign in ((78, 1), (334, -1)):
        grip = Image.new('L', (W, H), 0)
        ImageDraw.Draw(grip).ellipse(P(cx - 58, 112, cx + 58, 300), fill=255)
        grip = grip.rotate(-16 * sign, center=(cx * k, 200 * k), resample=Image.BICUBIC)
        shell = Image.composite(Image.new('L', (W, H), 255), shell, grip)
    sd = ImageDraw.Draw(shell)
    sd.polygon(P(60, 150, 352, 150, 300, 252, 112, 252), fill=255)
    shell = shell.filter(ImageFilter.GaussianBlur(1.5 * k)).point(lambda v: 255 if v > 127 else 0)
    # white, shaded darker toward the bottom and the outline
    grad = Image.linear_gradient('L').resize((W, H))
    white = Image.merge('RGB', [grad.point(lambda v: 246 - v * 34 // 255)] * 3)
    white = Image.merge('RGB', [white.split()[0], white.split()[1], white.split()[2].point(lambda v: min(255, v + 6))])
    outline = shell.filter(ImageFilter.MaxFilter(5)).point(lambda v: v)
    im.paste((150, 152, 160, 255), (0, 0), outline)
    im.paste(white, (0, 0), shell)

    # The black core.
    core = Image.new('L', (W, H), 0)
    cd = ImageDraw.Draw(core)
    cd.polygon(P(124, 96, 288, 96, 300, 200, 284, 262, 128, 262, 112, 200), fill=255)
    core = core.filter(ImageFilter.GaussianBlur(6 * k)).point(lambda v: 255 if v > 127 else 0)
    core = Image.composite(core, Image.new('L', (W, H), 0), shell)
    dark = Image.merge('RGB', [Image.linear_gradient('L').resize((W, H)).point(lambda v: 40 - v * 18 // 255)] * 3)
    im.paste(dark, (0, 0), core)

    # The touchpad and its light bars.
    d.rounded_rectangle(P(126, 34, 286, 116), 20 * k, fill=(236, 237, 242, 255), outline=(176, 178, 188, 255),
                        width=2 * k)
    for x0, x1 in ((120, 126), (286, 292)):
        d.rounded_rectangle(P(x0, 60, x1, 112), 3 * k, fill=(70, 150, 255, 255))
    # create and options
    for cx in (104, 308):
        d.rounded_rectangle(P(cx - 4, 50, cx + 4, 66), 4 * k, fill=(58, 60, 68, 255))

    # The D-pad and face buttons' wells.
    for cx, cy in ((87, 113), (FACE[0], FACE[1])):
        d.ellipse(P(cx - 44, cy - 44, cx + 44, cy + 44), fill=(226, 228, 234, 255))
    # The D-pad: four pointed buttons.
    dx, dy = 87, 113
    arrow = [(-9, -6), (9, -6), (9, 10), (0, 18), (-9, 10)]
    for angle in (0, 90, 180, 270):
        a = math.radians(angle)
        pts = []
        for x, y in arrow:
            y += 8
            rx, ry = x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)
            pts += [(dx + rx) * k, (dy + ry) * k]
        d.polygon(pts, fill=(86, 88, 96, 255), outline=(120, 122, 132, 255))

    # The face buttons, where the lines end: square left, circle right, triangle top, cross bottom.
    fx, fy, gap, r = FACE[0], FACE[1], 33, 14
    sym = (214, 216, 224, 255)
    for name, (bx, by) in {'triangle': (fx, fy - gap), 'square': (fx - gap, fy), 'circle': (fx + gap, fy),
                           'cross': (fx, fy + gap)}.items():
        d.ellipse(P(bx - r, by - r, bx + r, by + r), fill=(62, 64, 72, 255), outline=(98, 100, 110, 255),
                  width=k)
        w = max(2, int(1.8 * k))
        if name == 'triangle':
            d.polygon(P(bx, by - 7, bx + 7, by + 5, bx - 7, by + 5), outline=sym, width=w)
        elif name == 'square':
            d.rectangle(P(bx - 6, by - 6, bx + 6, by + 6), outline=sym, width=w)
        elif name == 'circle':
            d.ellipse(P(bx - 7, by - 7, bx + 7, by + 7), outline=sym, width=w)
        else:
            d.line(P(bx - 6, by - 6, bx + 6, by + 6), fill=sym, width=w)
            d.line(P(bx - 6, by + 6, bx + 6, by - 6), fill=sym, width=w)

    # The PS button and the mute button.
    d.ellipse(P(198, 180, 214, 196), fill=(18, 18, 22, 255), outline=(90, 92, 100, 255), width=k)
    d.rounded_rectangle(P(199, 204, 213, 209), 2 * k, fill=(232, 120, 60, 255))

    im = im.resize((512, 320), Image.LANCZOS)
    # The sockets: the left stick's (the guide's animated stick is drawn over it), the right stick drawn.
    socket(im, DUALSENSE_STICK, 21)
    rs = stick_top(19)
    im.alpha_composite(rs, (int(267 - rs.width / 2), int(192 - rs.height / 2)))
    layer = Image.new('RGBA', atlas.size, (0, 0, 0, 0))
    layer.paste(im.crop((0, 0, 512, 320)), (0, 0))
    layer = layer.crop(BODY)
    atlas.alpha_composite(layer, (BODY[0], BODY[1]))
    shadow_from(atlas, xbox, layer)
    stick_pieces(atlas, 19)
    triggers_clear(atlas)
    return atlas


def main():
    kind, xbox_path, out = sys.argv[1:4]
    xbox = rgba(xbox_path)
    atlas = {'backbone': backbone, 'dualsense': dualsense}[kind](xbox)
    atlas.save(out)


if __name__ == '__main__':
    main()
