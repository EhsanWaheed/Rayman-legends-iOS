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


# The DualSense in the atlas: 400 pixels wide from x 1, its top at y 26; its face buttons' center where the Xbox
# pad's is, its left stick lower down (button_prompts.h moves the guide's stick and Move line there).
DS_W, DS_X, DS_Y = 400.0, 1.0, 26.0
DS_H = DS_W * 0.66


def ds(u, v):
    """A point of the DualSense in the atlas, from its front view's normalized coordinates."""
    return DS_X + u * DS_W, DS_Y + v * DS_H


DUALSENSE_STICK = ds(0.345, 0.60)


def catmull_rom(points, steps=24):
    """A closed smooth curve through the points."""
    out = []
    n = len(points)
    for i in range(n):
        p0, p1, p2, p3 = points[i - 1], points[i], points[(i + 1) % n], points[(i + 2) % n]
        for s in range(steps):
            t = s / steps
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * (2 * p1[j] + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 +
                                    (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in range(2)))
    return out


def mirrored(left):
    """A closed outline from its left half (top center to bottom center, clockwise around the left)."""
    right = [(1 - u, v) for u, v in reversed(left[1:-1])]
    return left + right


# The outline: the top edge with the shoulders, the long grips tapering down and out, the arch between them.
DS_OUTLINE = mirrored([(0.50, 0.035), (0.30, 0.03), (0.15, 0.035), (0.07, 0.08), (0.035, 0.17), (0.02, 0.32),
                       (0.022, 0.50), (0.035, 0.68), (0.06, 0.84), (0.10, 0.95), (0.155, 0.995), (0.21, 0.98),
                       (0.25, 0.92), (0.285, 0.82), (0.33, 0.74), (0.40, 0.70), (0.50, 0.69)])
# The black core around the sticks and the PS button, up under the touchpad.
DS_CORE = mirrored([(0.50, 0.30), (0.32, 0.30), (0.285, 0.40), (0.255, 0.55), (0.265, 0.68), (0.31, 0.745),
                    (0.40, 0.705), (0.50, 0.695)])


def dualsense(xbox):
    """A DualSense, drawn: the white shell and grips with the D-pad and face buttons, the black core with the
    sticks and the PS button, the touchpad framed by its light bars. Its face buttons where the Xbox pad's are."""
    atlas = xbox.copy()
    clear(atlas, BODY)
    k = SS
    W, H = 512 * k, 320 * k
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def P(u, v):
        x, y = ds(u, v)
        return x * k, y * k

    def poly(points):
        return [P(u, v) for u, v in catmull_rom(points)]

    def ellipse(u, v, r_px):
        x, y = P(u, v)
        return (x - r_px * k, y - r_px * k, x + r_px * k, y + r_px * k)

    # The shell: white, a little darker toward the bottom, a soft gray outline.
    shell = Image.new('L', (W, H), 0)
    ImageDraw.Draw(shell).polygon(poly(DS_OUTLINE), fill=255)
    grad = Image.linear_gradient('L').resize((W, H))
    white = Image.merge('RGB', (grad.point(lambda v: 248 - v * 30 // 255),
                                grad.point(lambda v: 248 - v * 30 // 255),
                                grad.point(lambda v: 252 - v * 26 // 255)))
    rim = shell.filter(ImageFilter.MaxFilter(7))
    im.paste((128, 131, 142, 255), (0, 0), rim)
    im.paste(white, (0, 0), shell)
    # a soft shadow inside the lower edge of the grips
    inner = shell.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.GaussianBlur(6 * k))
    edge = Image.composite(Image.new('L', (W, H), 70), Image.new('L', (W, H), 0),
                           Image.eval(inner, lambda v: 255 - v))
    edge = Image.composite(edge, Image.new('L', (W, H), 0), shell)
    im.paste((150, 152, 165, 255), (0, 0), edge)

    # The black core.
    core = Image.new('L', (W, H), 0)
    ImageDraw.Draw(core).polygon(poly(DS_CORE), fill=255)
    core = Image.composite(core, Image.new('L', (W, H), 0), shell)
    dark = Image.merge('RGB', [Image.linear_gradient('L').resize((W, H)).point(lambda v: 42 - v * 20 // 255)] * 3)
    im.paste(dark, (0, 0), core)

    # The touchpad, flush with the top edge, its light bars down its lower corners.
    tl, br = P(0.305, 0.035), P(0.695, 0.36)
    d.rounded_rectangle((tl[0], tl[1], br[0], br[1]), 16 * k, fill=(238, 239, 244, 255),
                        outline=(184, 186, 196, 255), width=2 * k)
    d.rounded_rectangle((tl[0] + 10 * k, tl[1] + 2 * k, br[0] - 10 * k, tl[1] + 9 * k), 4 * k,
                        fill=(250, 250, 253, 255))
    for (u0, u1) in ((0.288, 0.300), (0.700, 0.712)):
        a0, a1 = P(u0, 0.16), P(u1, 0.37)
        d.rounded_rectangle((a0[0], a0[1], a1[0], a1[1]), 3 * k, fill=(66, 146, 255, 255))
    # create and options
    for u in (0.255, 0.745):
        a0, a1 = P(u - 0.008, 0.12), P(u + 0.008, 0.20)
        d.rounded_rectangle((a0[0], a0[1], a1[0], a1[1]), 3 * k, fill=(70, 72, 82, 255))

    # The D-pad: four pointed buttons in a shallow well.
    dx, dy = ds(0.19, 0.33)
    d.ellipse(((dx - 36) * k, (dy - 36) * k, (dx + 36) * k, (dy + 36) * k), fill=(228, 230, 237, 255))
    arrow = [(-9, -7), (9, -7), (9, 9), (0, 18), (-9, 9)]
    for angle in (0, 90, 180, 270):
        a = math.radians(angle)
        pts = []
        for x, y in arrow:
            y += 9
            rx, ry = x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)
            pts += [(dx + rx) * k, (dy + ry) * k]
        d.polygon(pts, fill=(92, 95, 106, 255), outline=(124, 127, 140, 255))

    # The face buttons, where the lines end: square left, circle right, triangle top, cross bottom.
    fx, fy, gap, r = FACE[0], FACE[1], 30, 13
    d.ellipse(((fx - 48) * k, (fy - 48) * k, (fx + 48) * k, (fy + 48) * k), fill=(228, 230, 237, 255))
    sym = (220, 222, 230, 255)
    for name, (bx, by) in {'triangle': (fx, fy - gap), 'square': (fx - gap, fy), 'circle': (fx + gap, fy),
                           'cross': (fx, fy + gap)}.items():
        d.ellipse(((bx - r) * k, (by - r) * k, (bx + r) * k, (by + r) * k), fill=(58, 60, 70, 255),
                  outline=(100, 103, 116, 255), width=k)
        w = max(2, int(1.8 * k))
        if name == 'triangle':
            d.polygon([(bx * k, (by - 7) * k), ((bx + 7) * k, (by + 5) * k), ((bx - 7) * k, (by + 5) * k)],
                      outline=sym, width=w)
        elif name == 'square':
            d.rectangle(((bx - 6) * k, (by - 6) * k, (bx + 6) * k, (by + 6) * k), outline=sym, width=w)
        elif name == 'circle':
            d.ellipse(((bx - 7) * k, (by - 7) * k, (bx + 7) * k, (by + 7) * k), outline=sym, width=w)
        else:
            d.line(((bx - 6) * k, (by - 6) * k, (bx + 6) * k, (by + 6) * k), fill=sym, width=w)
            d.line(((bx - 6) * k, (by + 6) * k, (bx + 6) * k, (by - 6) * k), fill=sym, width=w)

    # The PS button and the mute button between the sticks.
    d.ellipse(ellipse(0.5, 0.60, 8), fill=(16, 16, 20, 255), outline=(96, 98, 108, 255), width=k)
    a0, a1 = P(0.485, 0.665), P(0.515, 0.68)
    d.rounded_rectangle((a0[0], a0[1], a1[0], a1[1]), 2 * k, fill=(236, 122, 62, 255))

    im = im.resize((512, 320), Image.LANCZOS)
    # The sticks: the left one's socket (the guide's animated stick is drawn over it), the right one drawn.
    socket(im, DUALSENSE_STICK, 21)
    rs = stick_top(19)
    rx, ry = ds(0.655, 0.60)
    im.alpha_composite(rs, (int(rx - rs.width / 2), int(ry - rs.height / 2)))
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
