#!/usr/bin/env python3
"""Make a Pocket platform banner or core icon from a picture.

usage: png2pocket.py PICTURE --size banner|icon --out FILE [--fill] [--invert]

  banner  Platforms/_images/saturn.bin  (521 x 165)
  icon    Cores/akoaysigod.Saturn/icon.bin  (36 x 36)

The format (checked against the PSX core's banner and icon): greyscale, 16 bits per pixel, little-endian, grey level
in the low byte. The banner is stored rotated 90 degrees counter-clockwise (165 pixels wide, 521 tall); the icon is not.
By default the picture is scaled to fit and centred, the rest black; --fill scales it to cover the whole size and
crops the edges. --invert swaps black and white (a dark picture on the black background of the icon).
"""
import argparse
import struct

from PIL import Image, ImageOps

# name: (width, height, stored rotated 90 degrees counter-clockwise)
SIZES = {'banner': (521, 165, True), 'icon': (36, 36, False)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('picture')
    ap.add_argument('--size', choices=sorted(SIZES), required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--fill', action='store_true', help='cover the whole size and crop, instead of fitting')
    ap.add_argument('--invert', action='store_true', help='swap black and white')
    a = ap.parse_args()
    w, h, rotate = SIZES[a.size]

    im = Image.open(a.picture).convert('L')
    if a.invert:                        # before the padding, which stays black
        im = ImageOps.invert(im)
    if a.fill:
        im = ImageOps.fit(im, (w, h), Image.LANCZOS)
    else:
        im = ImageOps.contain(im, (w, h), Image.LANCZOS)
        canvas = Image.new('L', (w, h), 0)
        canvas.paste(im, ((w - im.width) // 2, (h - im.height) // 2))
        im = canvas
    if rotate:
        im = im.rotate(90, expand=True)
    data = b''.join(struct.pack('<H', g) for g in im.getdata())
    with open(a.out, 'wb') as f:
        f.write(data)
    print('wrote %s: %d x %d stored, %d bytes' % (a.out, im.width, im.height, len(data)))


if __name__ == '__main__':
    main()
