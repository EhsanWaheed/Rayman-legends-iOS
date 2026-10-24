#!/usr/bin/env python3
"""Xbox 360 UbiArt textures (.tga.ckd: Xenos k_DXT1 = 18, k_DXT2_3 = 19 (explicit alpha), k_DXT4_5 = 20; tiled,
8in16): decode to PNG, encode a PNG back in place (DXT3).

usage: x360tex.py decode in.tga.ckd out.png
       x360tex.py encode in.tga.ckd image.png out.tga.ckd   (tiled DXT3 at the template's size, the mips down
                                                             to the packed tail, the mip range ending there;
                                                             needs Pillow, numpy and etcpak: the repo's .venv)
"""
import struct, sys, zlib

def tiled_offset(x, y, pitch, log2_bpp):
    macro = ((y >> 5) * (pitch >> 5)) << (log2_bpp + 7)
    micro = ((y & 6) << 2) << log2_bpp
    outer = macro + ((micro & ~0xF) << 1) + (micro & 0xF) + ((y & 8) << (3 + log2_bpp)) + ((y & 1) << 4)
    macro = (x >> 5) << (log2_bpp + 7)
    micro = (x & 7) << log2_bpp
    off = outer + (macro + ((micro & ~0xF) << 1) + (micro & 0xF))
    off = ((off & ~0x1FF) << 3) + ((off & 0x1C0) << 2) + (off & 0x3F) + ((y & 16) << 7) + \
          (((((y & 8) >> 2) + (x >> 3)) & 3) << 6)
    return off >> log2_bpp

def parse(d):
    w, h = struct.unpack('>HH', d[0x10:0x14])
    fetch = struct.unpack('>6I', d[0x50:0x68])
    fmt = fetch[1] & 0x3F
    endian = (fetch[1] >> 6) & 3
    tiled = fetch[0] >> 31
    return w, h, fmt, endian, tiled, 0x68

def swap16(b):
    out = bytearray(b)
    out[0::2], out[1::2] = b[1::2], b[0::2]
    return bytes(out)

def rgb565(c):
    r = (c >> 11) & 31; g = (c >> 5) & 63; b = c & 31
    return (r * 255 // 31, g * 255 // 63, b * 255 // 31)

def decode_dxt1_block(blk, four_color=False):
    c0, c1, bits = struct.unpack('<HHI', blk)
    p0, p1 = rgb565(c0), rgb565(c1)
    if c0 > c1 or four_color:
        pal = [p0 + (255,), p1 + (255,), tuple((2*a+b)//3 for a, b in zip(p0, p1)) + (255,),
               tuple((a+2*b)//3 for a, b in zip(p0, p1)) + (255,)]
    else:
        pal = [p0 + (255,), p1 + (255,), tuple((a+b)//2 for a, b in zip(p0, p1)) + (255,), (0, 0, 0, 0)]
    return [pal[(bits >> (2*i)) & 3] for i in range(16)]

def decode_dxt3_block(blk):
    abits = int.from_bytes(blk[0:8], 'little')
    rgb = decode_dxt1_block(blk[8:16], four_color=True)
    return [rgb[i][:3] + (((abits >> (4*i)) & 15) * 17,) for i in range(16)]

def decode_dxt5_block(blk):
    a0, a1 = blk[0], blk[1]
    abits = int.from_bytes(blk[2:8], 'little')
    if a0 > a1: apal = [a0, a1] + [((6-i)*a0 + (i+1)*a1)//7 for i in range(6)]
    else: apal = [a0, a1] + [((4-i)*a0 + (i+1)*a1)//5 for i in range(4)] + [0, 255]
    rgb = decode_dxt1_block(blk[8:16], four_color=True)
    return [rgb[i][:3] + (apal[(abits >> (3*i)) & 7],) for i in range(16)]

def write_png(path, w, h, px):
    raw = b''.join(b'\0' + bytes(c for p in px[y*w:(y+1)*w] for c in p) for y in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

def decode(src, dst):
    d = open(src, 'rb').read()
    w, h, fmt, endian, tiled, off = parse(d)
    bpb = 8 if fmt == 18 else 16
    log2 = 3 if bpb == 8 else 4
    data = d[off:]
    if endian == 1: data = swap16(data)
    bw, bh = w // 4, h // 4
    pitch = (bw + 31) & ~31
    px = [(0, 0, 0, 0)] * (w * h)
    for by in range(bh):
        for bx in range(bw):
            i = tiled_offset(bx, by, pitch, log2) if tiled else by * bw + bx
            blk = data[i*bpb:(i+1)*bpb]
            texels = (decode_dxt1_block(blk) if fmt == 18 else
                      decode_dxt3_block(blk) if fmt == 19 else decode_dxt5_block(blk))
            for t in range(16):
                px[(by*4 + t//4) * w + bx*4 + t%4] = texels[t]
    write_png(dst, w, h, px)
    print(f'{w}x{h} format {fmt} endian {endian} tiled {tiled}')

def dxt3_blocks(im):
    """DXT3 (BC2) blocks of an RGBA image, row by row: etcpak's colors (put in 4-color order, as DXT3 always
    reads them), 4-bit alpha."""
    import etcpak
    import numpy as np
    w, h = im.size
    color = np.frombuffer(etcpak.compress_bc1(im.tobytes(), w, h), np.uint8).reshape(-1, 8).copy()
    c0 = color[:, 0].astype(np.uint16) | (color[:, 1].astype(np.uint16) << 8)
    c1 = color[:, 2].astype(np.uint16) | (color[:, 3].astype(np.uint16) << 8)
    bits = np.frombuffer(color[:, 4:8].tobytes(), '<u4').copy()
    swap = c0 < c1
    # endpoints swapped: indices 0<->1, 2<->3 (3-color blocks have no 4-color equivalent; rare, kept close)
    flipped = bits ^ 0x55555555
    bits = np.where(swap, flipped, bits)
    c0s, c1s = np.where(swap, c1, c0), np.where(swap, c0, c1)
    color[:, 0], color[:, 1] = c0s & 0xFF, c0s >> 8
    color[:, 2], color[:, 3] = c1s & 0xFF, c1s >> 8
    color[:, 4:8] = np.frombuffer(bits.astype('<u4').tobytes(), np.uint8).reshape(-1, 4)
    a = np.asarray(im)[..., 3].astype(np.int32)
    blocks_a = a.reshape(h // 4, 4, w // 4, 4).transpose(0, 2, 1, 3).reshape(-1, 16)
    nibbles = ((blocks_a + 8) // 17).clip(0, 15).astype(np.uint8)
    alpha = (nibbles[:, 0::2] | (nibbles[:, 1::2] << 4)).astype(np.uint8)
    return np.hstack([alpha, color]).tobytes()


def encode(template, image, dst):
    from PIL import Image
    d = bytearray(open(template, 'rb').read())
    w, h, fmt, endian, tiled, off = parse(d)
    if fmt != 19 or not tiled:
        sys.exit('encode: tiled DXT3 (k_DXT2_3) templates only')
    im = Image.open(image).convert('RGBA')
    if im.size != (w, h):
        sys.exit(f'encode: the image must be {w}x{h}')
    data = bytearray(len(d) - off)
    # Tiled levels: pitch and height in blocks aligned to 32, one after another after the base; levels of 16
    # texels or less go in the packed tail, not written here (the mip range ends before them).
    dword4 = struct.unpack('>I', d[0x60:0x64])[0]
    template_max = (dword4 >> 6) & 0xF
    pos, level, last = 0, 0, 0
    import numpy as np
    rgba = np.asarray(im).astype(np.float32)
    premultiplied = Image.fromarray(np.dstack([rgba[..., :3] * rgba[..., 3:4] / 255, rgba[..., 3:4]]).astype(np.uint8))
    while level <= template_max:
        lw, lh = max(w >> level, 1), max(h >> level, 1)
        if level and (lw <= 16 or lh <= 16):
            break
        if level == 0:
            lim = im
        else:
            # box filtered with premultiplied alpha, then back
            pa = np.asarray(premultiplied.resize((lw, lh), Image.BOX)).astype(np.float32)
            alpha = pa[..., 3:4]
            rgb = np.where(alpha > 0, pa[..., :3] * 255 / np.maximum(alpha, 1), 0)
            lim = Image.fromarray(np.dstack([np.clip(rgb, 0, 255), alpha]).astype(np.uint8))
        bw, bh = lw // 4, lh // 4
        pitch = (bw + 31) & ~31
        height = (bh + 31) & ~31
        blocks = dxt3_blocks(lim)
        for by in range(bh):
            for bx in range(bw):
                i = tiled_offset(bx, by, pitch, 4)
                data[pos + i*16:pos + (i+1)*16] = blocks[(by*bw + bx)*16:(by*bw + bx + 1)*16]
        last = level
        pos += pitch * height * 16
        level += 1
    if pos > len(data):
        sys.exit('encode: the levels do not fit the template')
    if endian == 1:
        data = bytearray(swap16(bytes(data)))
    d[off:] = data
    d[0x60:0x64] = struct.pack('>I', (dword4 & ~(0xF << 6)) | (last << 6))
    open(dst, 'wb').write(bytes(d))
    print(f'{w}x{h} DXT3, levels 0-{last} -> {dst}')

if __name__ == '__main__':
    if sys.argv[1] == 'decode': decode(sys.argv[2], sys.argv[3])
    if sys.argv[1] == 'encode': encode(sys.argv[2], sys.argv[3], sys.argv[4])
