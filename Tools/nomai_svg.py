#!/usr/bin/env python3
"""Prepares Nomai script from a Nomai text generator's SVG export for Solanum's Quantum Moon easter egg.

    python3 Tools/nomai_svg.py export.svg Support/Name.svg [cell]

Drops the paper background, crops to the script, scales it to 1000 units across, colors it Nomai blue, and puts its
paths in reading order (the spiral's free end to its center) so QuantumMoon.swift can light them in turn. `cell`
(default 40) is about one line's width in output units: raise it if the order jumps around (sparse script), lower it
if neighbouring turns of a tight spiral merge.
"""
import re, sys, math
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
paths = re.findall(r'<path style="([^"]*)" d="([^"]*)"/>', s)
items = []
for style, d in paths:
    toks = d.split()
    nums = [float(t) for t in toks if not t.isalpha()]
    pts = list(zip(nums[0::2], nums[1::2]))
    items.append((style, toks, pts))
xs = [x for _, _, p in items for x, _ in p]; ys = [y for _, _, p in items for _, y in p]
minx, miny, maxx, maxy = min(xs), min(ys), max(xs), max(ys)
pad = 12  # source units, for stroke caps and dots
scale = 1000 / (max(maxx - minx, maxy - miny) + 2 * pad)
def tx(x): return (x - minx + pad) * scale
def ty(y): return (y - miny + pad) * scale
# Reading order: from the spiral's free end (leftmost point) to its center. Path centers snap to a grid about one
# line wide; the occupied cells form a thin curve that a nearest-neighbour walk follows end to end, and each path
# reads at the place of its cell along that walk.
cents = [((sum(x for x, _ in p) / len(p) - minx) * scale, (sum(y for _, y in p) / len(p) - miny) * scale) for _, _, p in items]
CELL = float(sys.argv[3]) if len(sys.argv) > 3 else 40
cells = {}
for i, (x, y) in enumerate(cents):
    cells.setdefault((int(x // CELL), int(y // CELL)), []).append(i)
keys = list(cells)
cc = {c: (sum(cents[i][0] for i in cells[c]) / len(cells[c]), sum(cents[i][1] for i in cells[c]) / len(cells[c])) for c in keys}
cur = min(keys, key=lambda c: cc[c][0])
walk, seen = [cur], {cur}
while len(walk) < len(keys):
    cx, cy = cc[cur]
    cur = min((c for c in keys if c not in seen), key=lambda c: (cc[c][0] - cx) ** 2 + (cc[c][1] - cy) ** 2)
    walk.append(cur); seen.add(cur)
# The walk follows the line until it runs out at the center, then jumps back for cells it passed by: those read
# where their nearest cell on the line does.
d2 = lambda a, b: (cc[a][0] - cc[b][0]) ** 2 + (cc[a][1] - cc[b][1]) ** 2
cut = next((r for r in range(1, len(walk)) if d2(walk[r], walk[r - 1]) > (2.5 * CELL) ** 2), len(walk))
spine = walk[:cut]
pos = {c: r for r, c in enumerate(spine)}
for c in walk[cut:]:
    pos[c] = pos[min(spine, key=lambda m: d2(c, m))] + 0.5
order = sorted(range(len(items)), key=lambda i: (pos[(int(cents[i][0] // CELL), int(cents[i][1] // CELL))], i))
out = []
blue = "rgb(35.294118%,70.588235%,100%)"  # #5AB4FF, Nomai glow blue
for i in order:
    style, toks, _ = items[i]
    style = re.sub(r'rgb\([^)]*\)', blue, style)
    style = re.sub(r'stroke-width:([\d.]+)', lambda m: 'stroke-width:%.2f' % (float(m.group(1)) * scale), style)
    res, nums = [], []
    for t in toks:
        if t.isalpha(): res.append(t)
        else: nums.append(float(t)); res.append(None)
    # Coordinates come in x y pairs in order.
    k = 0; outt = []
    for t in res:
        if t is not None: outt.append(t)
        else:
            v = nums[k]; outt.append('%.1f' % (tx(v) if k % 2 == 0 else ty(v))); k += 1
    out.append('<path style="%s" d="%s"/>' % (style.strip(), ' '.join(outt)))
w, h = (maxx - minx + 2 * pad) * scale, (maxy - miny + 2 * pad) * scale
svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="%.1f" height="%.1f" viewBox="0 0 %.1f %.1f" version="1.1">\n'
       '<!-- Nomai script: transparent, cropped, and its paths in reading order (the spiral\'s free end to its center). -->\n'
       '<g id="nomai_svg">\n%s\n</g>\n</svg>\n') % (w, h, w, h, '\n'.join(out))
open(dst, 'w').write(svg)
print(dst, len(items), "paths", "%.0fx%.0f" % (w, h))
