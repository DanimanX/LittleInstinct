#!/usr/bin/env python3
"""Rectify a photo of the LittleInstinct debug screen to the native text grid.

The status page is a 320x240 picture: 20 columns by 15 rows of 16x16 cells.
A hand-held photo of the Pocket LCD is skewed, scaled and full of moire, and
reading hex out of it by eye is how a previous session recorded values that the
photo did not contain. This tool finds the dark screen rectangle, warps it to
320x240 with a projective transform, and then cuts the 15 rows out separately so
each one can be read at 8x without its neighbours bleeding into it.

Usage:
    tools/read_debug_photo.py IMG_0001.jpg [-o OUTDIR]

Writes, under OUTDIR (default: /tmp/kidebug_<stem>/):
    screen.png        the whole 320x240 rectified screen, 2x
    row_00.png..15    one strip per text row, 8x

Requires numpy + scipy + Pillow. No OpenCV.
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def PIL_from(arr):
    return Image.fromarray(np.ascontiguousarray(arr))

# The status page geometry, from ki_debug_screen.sv: twenty 16-pixel columns
# and fifteen 16-pixel rows over a 320x240 field.
GRID_W, GRID_H = 320, 240
CELL = 16
COLS, ROWS = GRID_W // CELL, GRID_H // CELL + 0  # 20 x 15


def find_screen(gray):
    """Return the four corners of the dark LCD area, ordered TL TR BR BL.

    The active area is near black; the shell around it is a bright cream. So a
    plain luminance threshold isolates the screen, and the four diagonal
    extremes of that blob land on its corners because the shape is a
    near-rectangle seen at a shallow angle.
    """
    dark = gray < 70
    # Kill the vignetted photo border, which is also dark: only keep the
    # component that does not touch the frame.
    lbl, n = ndimage.label(dark)
    areas = ndimage.sum(dark, lbl, index=np.arange(1, n + 1))
    border = set(lbl[0, :]) | set(lbl[-1, :]) | set(lbl[:, 0]) | set(lbl[:, -1])
    inside = [i for i in range(1, n + 1) if i not in border]
    if not inside:
        raise SystemExit("no dark screen region found")
    best = max(inside, key=lambda i: areas[i - 1])
    ys, xs = np.nonzero(lbl == best)
    # Shrink to the blob's own bounding frame so a stray dark pixel does not
    # define a corner.
    pts = np.stack([xs, ys], axis=1).astype(np.float64)
    s, d = pts[:, 0] + pts[:, 1], pts[:, 0] - pts[:, 1]
    tl = pts[np.argmin(s)]
    br = pts[np.argmax(s)]
    tr = pts[np.argmax(d)]
    bl = pts[np.argmin(d)]
    quad = np.array([tl, tr, br, bl], dtype=np.float64)

    # The four extremes above are found by diagonal projection, which is blind
    # to which pair of edges is the 320-pixel axis. The LCD is landscape, so
    # the longer edge is that axis: rotate the ordering until edge 0->1 is the
    # long one, otherwise the warp lays the long axis on the 240 side and the
    # text comes out running vertically.
    if np.linalg.norm(quad[1] - quad[0]) < np.linalg.norm(quad[2] - quad[1]):
        quad = np.roll(quad, -1, axis=0)
    return quad


def homography(src, dst):
    """Solve the 8x8 DLT for the mapping src -> dst (4 points each)."""
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y])
    A = np.array(A, dtype=np.float64)
    b = np.array(dst, dtype=np.float64).reshape(-1)
    h = np.linalg.solve(A, b)
    return np.append(h, 1.0).reshape(3, 3)


def warp(img, H, out_w, out_h):
    """Sample the source through H into an out_w x out_h RGB image."""
    ys, xs = np.mgrid[0:out_h, 0:out_w]
    ones = np.ones_like(xs)
    p = np.stack([xs, ys, ones], axis=0).reshape(3, -1).astype(np.float64)
    q = np.linalg.inv(H) @ p
    sx = (q[0] / q[2]).reshape(out_h, out_w)
    sy = (q[1] / q[2]).reshape(out_h, out_w)
    sx = np.clip(np.rint(sx).astype(np.int32), 0, img.shape[1] - 1)
    sy = np.clip(np.rint(sy).astype(np.int32), 0, img.shape[0] - 1)
    return img[sy, sx]


def ink_mask(gray):
    """Bright glyph pixels, with the photo's vignetting normalised away.

    The LCD is photographed off-axis, so the bottom rows are noticeably dimmer
    than the top. A single global threshold keeps the bright half and drops the
    dim half, which destroys row periodicity - the exact failure that made the
    first fit land on a pitch of 14 and blank the picture. Comparing each pixel
    to a local mean cancels the gradient.
    """
    bg = ndimage.uniform_filter(gray, size=25)
    return gray > bg * 1.35 + 8.0


def fit_grid(screen, vertical):
    """Return (offset, pitch) of the text grid along one axis of a coarse warp.

    The quad from find_screen() lands on the dark LCD area, which is not exactly
    the 320x240 picture: the Pocket leaves black margins, so assuming a pitch of
    16 puts every band boundary in the wrong place and each strip then straddles
    two text rows.

    So the grid is measured from the ink itself. Find the first and last
    inked position along the axis, and divide that span into the known cell
    count - 15 rows, 20 columns. This needs no assumed pitch and no thin
    periodic signal, which is what made the searches above unreliable.

    vertical=True fits along Y (15 rows), False along X (20 columns).
    """
    g = np.asarray(Image.fromarray(np.ascontiguousarray(screen)).convert("L"),
                   dtype=np.float32)
    ink = ink_mask(g)
    prof = ink.sum(axis=1 if vertical else 0).astype(np.float64)
    cells = ROWS if vertical else COLS

    # A cell is inked if it holds at least a few glyph pixels; the threshold is
    # relative to the axis' own peak so a dim region still counts.
    live = prof > max(2.0, prof.max() * 0.04)
    idx = np.nonzero(live)[0]
    if idx.size < cells:
        return 0.0, 16.0
    lo, hi = int(idx[0]), int(idx[-1]) + 1
    pitch = (hi - lo) / float(cells)
    return float(lo), float(pitch)




def resample(screen, ox, px, oy, py):
    """Cut the fitted grid out of a coarse warp and scale it to 320x240.

    fit_grid returns the source offset and the source pixels PER CELL, while
    this needs source pixels per OUTPUT pixel: one cell is CELL output pixels,
    so the step is pitch/CELL. Using the cell pitch directly samples 16x past
    the right and bottom edges and yields a flat field - which is exactly what
    the first version of this function did.
    """
    xs = ox + np.arange(GRID_W) * (px / CELL)
    ys = oy + np.arange(GRID_H) * (py / CELL)
    xs = np.clip(np.rint(xs).astype(np.int32), 0, screen.shape[1] - 1)
    ys = np.clip(np.rint(ys).astype(np.int32), 0, screen.shape[0] - 1)
    return screen[np.ix_(ys, xs)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("photo")
    ap.add_argument("-o", "--outdir", default=None)
    ap.add_argument("--inset", type=float, default=0.004,
                    help="fraction of the screen to trim off each edge (default 0.004)")
    args = ap.parse_args()

    im = Image.open(args.photo).convert("RGB")
    img = np.asarray(im)
    gray = np.asarray(im.convert("L")).astype(np.float32)

    corners = find_screen(gray)
    # A little inset absorbs the bezel shadow that the threshold includes.
    cx, cy = corners.mean(axis=0)
    corners = cx + (corners - cx) * (1.0 - args.inset)

    src = [tuple(c) for c in corners]
    dst = [(0, 0), (GRID_W, 0), (GRID_W, GRID_H), (0, GRID_H)]
    H = homography(src, dst)
    screen = warp(img, H, GRID_W, GRID_H)

    # The ordering above fixes the long axis but not which way up it is: the
    # photo may be upside down, or mirrored by the roll. Offsets 0 and 2 are
    # the two upright orientations, so try both and keep the one whose rows
    # actually break on the 16-pixel text grid - a correctly turned screen has
    # bright glyph bands separated by near-empty seams.
    best, best_score = screen, -1.0
    for cand in (screen, np.rot90(screen, 2)):
        g = np.asarray(Image.fromarray(np.ascontiguousarray(cand)).convert("L"),
                       dtype=np.float32)
        band = (g > 100).reshape(ROWS, CELL, GRID_W).sum(axis=(1, 2)).astype(np.float64)
        # Glyph rows have ink; the seams between them do not. A correct
        # orientation maximises the gap between the inkful rows and the empties.
        score = float(band.mean() - band.min()) + float(band.max() - band.mean())
        if score > best_score:
            best, best_score = cand, score
    screen = best

    # Fit the 16-pixel text grid to the ink and re-cut, so each emitted row
    # strip contains exactly one text row.
    oy, py = fit_grid(screen, vertical=True)
    ox, px = fit_grid(screen, vertical=False)
    screen = resample(screen, ox, px, oy, py)

    outdir = args.outdir or os.path.join("/tmp", "kidebug_" +
                                         os.path.splitext(os.path.basename(args.photo))[0])
    os.makedirs(outdir, exist_ok=True)

    Image.fromarray(screen).resize((GRID_W * 2, GRID_H * 2), Image.LANCZOS).save(
        os.path.join(outdir, "screen.png"))

    for r in range(ROWS):
        strip = screen[r * CELL:(r + 1) * CELL, :, :]
        Image.fromarray(strip).resize((GRID_W * 4, CELL * 8), Image.NEAREST).save(
            os.path.join(outdir, "row_%02d.png" % r))

    print("corners:", corners.astype(int).tolist())
    print("wrote:", outdir)


if __name__ == "__main__":
    sys.exit(main())
