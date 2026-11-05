#!/usr/bin/env python3
"""Draw the Composer icons for the Modern Forms fan driver.

Composer shows a driver's icon at 16 px (the project tree and the Items
pane) and 32 px (List View), 96 DPI. Both are too small for line art to
look like anything, so every icon is rendered as a lit, shaded object on a
512 px master canvas (32x the 16 px icon, 16x the 32 px icon) and then
downsampled:

  * a height map of the object (hub, blades, rings, drum) drives a
    directional light from the top-left: bevelled edges get a highlight on
    the lit side and a shadow on the far side, and dips get ambient
    occlusion;
  * every surface has a gradient albedo, matte parts get a touch of grain,
    and the object casts a soft drop shadow onto the transparent
    background;
  * the geometry is given in target pixels and laid out per size (hub and
    ring radii, band rows, stroke widths) so the strongest edges land on
    the pixel grid after the LANCZOS downsample, and each size gets its own
    unsharp mask and contrast tuning so the 16 px version still reads.

Designs (original artwork drawn from geometry; no photo is traced, sampled
or embedded, and there is no logo, text or trademark):

Fan    a matte black flush-mount ceiling fan seen straight from below
       (an angled view muddles five black blades and the canopy into one
       blot at 16 px): a flat round hub (with a stepped cap at 32 px) and
       five long blades swept the same way round, wide at the hub and
       tapering to an angled tip. Each blade is pitched, so it takes the
       light from the top-left at its own angle and the five read apart
       even where they meet the hub; a lit rim along the top-left edges
       and a soft drop shadow give the black its shape.
Light  a flush-mount drum ceiling light seen from slightly below:
       a thin black ceiling disc, a wide, short, glowing opal drum, and a
       black ring at the bottom edge through which the lit diffuser shows.
       The drum glows warm white with a faint warm halo, and a soft grey
       outline and drop shadow keep it visible on a white tree.

Run from the repo root with no arguments:

    python3 tools/make_icons.py

Writes:
    src/modernforms_fan/www/images/devices_sm/modernforms_fan_16.png
    src/modernforms_fan/www/images/devices_lg/modernforms_fan_32.png
    src/modernforms_fan/www/images/devices_sm/modernforms_light_16.png
    src/modernforms_fan/www/images/devices_lg/modernforms_light_32.png

    python3 tools/make_icons.py --out DIR

writes the same four files under DIR (at the same relative paths) instead
of the repository, which is how tools/tests/test_make_icons.py checks that
the committed icons are exactly what this script draws.

    python3 tools/make_icons.py --inspect DIR

also writes the 512 px masters (icons_master_<name>_<size>.png) and a sheet
(icons_sheet.png) showing each icon at 1x, 4x and 8x on white and on
Composer's #f0f0f0, for eyeballing.

Pillow (12.x) is the one exception to "tools are standard library only":
nothing else in tools/ needs it, CI's test skips the check without it, and
the icons it draws are committed. Deterministic: the grain comes from a
seeded generator and the PNGs carry no timestamps, so a second run leaves
the files byte for byte the same.
"""

import argparse
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

MASTER = 512
DPI = (96, 96)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVER = "modernforms_fan"


def rel_path(name, size):
    sub = "devices_sm" if size == 16 else "devices_lg"
    return os.path.join("src", DRIVER, "www", "images", sub, "%s_%d.png" % (name, size))


# --------------------------------------------------------------------------
# Low-level helpers. Everything is drawn on a MASTER x MASTER canvas; S is
# the number of master pixels per target pixel, and all geometry arguments
# are in target pixels so the same drawing code serves both sizes.
# --------------------------------------------------------------------------


def _clamp(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


def _lut(fn):
    return [_clamp(fn(v)) for v in range(256)]


def empty():
    return Image.new("L", (MASTER, MASTER), 0)


def ellipse(S, cx, cy, rx, ry):
    """L mask of an ellipse; centre and radii in target pixels."""
    m = empty()
    ImageDraw.Draw(m).ellipse(
        (round((cx - rx) * S), round((cy - ry) * S), round((cx + rx) * S) - 1, round((cy + ry) * S) - 1), fill=255
    )
    return m


def rrect(S, box, radius):
    """L mask of a rounded rectangle; box (x1/y1 exclusive) in target pixels."""
    m = empty()
    x0, y0, x1, y1 = box
    ImageDraw.Draw(m).rounded_rectangle(
        (round(x0 * S), round(y0 * S), round(x1 * S) - 1, round(y1 * S) - 1), radius=radius * S, fill=255
    )
    return m


def polygon(S, pts):
    m = empty()
    ImageDraw.Draw(m).polygon([(x * S, y * S) for x, y in pts], fill=255)
    return m


def blur(img, r_px, S):
    if r_px <= 0:
        return img
    return img.filter(ImageFilter.GaussianBlur(r_px * S))


def soften(mask, r_px, S):
    """Round a mask's corners (convex and concave) with radius about r."""
    return blur(mask, r_px, S).point(_lut(lambda v: (v - 128) * 8 + 128))


def shift(img, dx_px, dy_px, S):
    return ImageChops.offset(img, round(dx_px * S), round(dy_px * S))


def scale(mask, k):
    return mask.point(_lut(lambda v: v * k))


def mul(a, b):
    return ImageChops.multiply(a, b)


def union(*masks):
    out = masks[0]
    for m in masks[1:]:
        out = ImageChops.lighter(out, m)
    return out


def minus(a, b):
    return ImageChops.subtract(a, b)


def solid(colour):
    return Image.new("RGBA", (MASTER, MASTER), colour)


def layer(mask, colour, alpha=1.0):
    """RGBA layer of one colour whose alpha is the mask times alpha."""
    out = Image.new("RGBA", (MASTER, MASTER), tuple(colour[:3]) + (0,))
    out.putalpha(scale(mask, alpha) if alpha != 1.0 else mask)
    return out


def over(dst, src):
    return Image.alpha_composite(dst, src)


def lin_grad(S, p0, p1):
    """L gradient, 0 at target point p0 rising to 255 at p1, clipped."""
    x0, y0 = p0[0] * S, p0[1] * S
    dx, dy = (p1[0] - p0[0]) * S, (p1[1] - p0[1]) * S
    n = dx * dx + dy * dy
    kx, ky = dx / n, dy / n
    # Each axis is stored offset by 128 so a negative share survives the
    # 8-bit image; add() removes both offsets and clips the sum to 0..255.
    xs = [_clamp(128 + 255 * kx * (x - x0)) for x in range(MASTER)]
    ys = [_clamp(128 + 255 * ky * (y - y0)) for y in range(MASTER)]
    gx = Image.new("L", (MASTER, 1))
    gx.putdata(xs)
    gy = Image.new("L", (1, MASTER))
    gy.putdata(ys)
    return ImageChops.add(
        gx.resize((MASTER, MASTER), Image.Resampling.NEAREST),
        gy.resize((MASTER, MASTER), Image.Resampling.NEAREST),
        1.0,
        -256,
    )


def column_profile(S, fn):
    """L image whose every column x has the value fn(x in target pixels)."""
    row = Image.new("L", (MASTER, 1))
    row.putdata([_clamp(fn((x + 0.5) / S)) for x in range(MASTER)])
    return row.resize((MASTER, MASTER), Image.Resampling.NEAREST)


def radial(S, centre, r_px, inner=0.0, ry_px=None):
    """L: 255 at the centre falling to 0 at radius r (smoothstep); an
    optional vertical radius makes it elliptical."""
    cx, cy = centre[0] * S, centre[1] * S
    r = r_px * S
    sy = r_px / ry_px if ry_px else 1.0
    ri = inner * S
    data = []
    for y in range(MASTER):
        dy = (y + 0.5 - cy) * sy
        for x in range(MASTER):
            d = math.hypot(x + 0.5 - cx, dy)
            if d <= ri:
                data.append(255)
            elif d >= r:
                data.append(0)
            else:
                t = (d - ri) / (r - ri)
                data.append(int(255 * (1 - t * t * (3 - 2 * t))))
    m = Image.new("L", (MASTER, MASTER))
    m.putdata(data)
    return m


def grad_fill(mask, c0, c1, S, p0, p1):
    """RGBA: colour c0 at p0 shading to c1 at p1, cut out by mask."""
    g = lin_grad(S, p0, p1)
    col = Image.composite(solid(tuple(c1) + (255,)), solid(tuple(c0) + (255,)), g)
    col.putalpha(mask)
    return col


def modulate(img, signed, gain_hi, gain_lo, mask=None):
    """Lighten where signed > 128 and darken where < 128 (RGB only)."""
    hi = signed.point(_lut(lambda v: (v - 128) * gain_hi))
    lo = signed.point(_lut(lambda v: (128 - v) * gain_lo))
    if mask is not None:
        hi = mul(hi, mask)
        lo = mul(lo, mask)
    a = img.getchannel("A")
    white = solid((255, 255, 255, 0))
    white.putalpha(a)
    black = solid((0, 0, 0, 0))
    black.putalpha(a)
    out = Image.composite(white, img, hi)
    return Image.composite(black, out, lo)


def light_map(H, S, d_px):
    """Directional derivative of the height map along the light (top-left
    to bottom-right), centred on 128: >128 faces the light."""
    d = max(1, round(d_px * S))
    return ImageChops.subtract(ImageChops.offset(H, -d, -d), ImageChops.offset(H, d, d), 1.0, 128)


def shade(img, H, S, d_px=0.2, gain_hi=1.6, gain_lo=1.6, mask=None):
    return modulate(img, light_map(H, S, d_px), gain_hi, gain_lo, mask)


def specular(img, H, S, d_px, strength, gloss_mask, power=3, soften_px=0.0):
    L = light_map(H, S, d_px)
    spec = mul(L.point(_lut(lambda v: 255 * strength * max(0.0, (v - 128) / 127.0) ** power)), gloss_mask)
    spec = blur(spec, soften_px, S)
    white = solid((255, 255, 255, 0))
    white.putalpha(img.getchannel("A"))
    return Image.composite(white, img, spec)


def occlusion(img, H, S, r_px, gain, mask=None):
    """Darken dips: where the blurred height is above the local height."""
    ao = ImageChops.subtract(blur(H, r_px, S), H, 1.0, 128)
    return modulate(img, ao, 0.0, gain, mask)


def grain(img, S, amount, seed, mask=None):
    """Matte grain, seeded so the output never changes."""
    rng = random.Random(seed)
    noise = Image.frombytes("L", (MASTER, MASTER), bytes(rng.getrandbits(8) for _ in range(MASTER * MASTER)))
    noise = blur(noise, 0.03, S)
    return modulate(img, noise, amount, amount, mask)


def drop_shadow(mask, S, dx, dy, r, alpha, colour=(0, 0, 0)):
    return layer(blur(shift(mask, dx, dy, S), r, S), colour, alpha)


def add_height(H, mask, amount, r_px, S):
    """Add (or subtract) a blurred mask to the height map."""
    m = blur(mask, r_px, S) if r_px else mask
    if amount >= 0:
        return ImageChops.add(H, scale(m, amount / 255.0))
    return ImageChops.subtract(H, scale(m, -amount / 255.0))


def edge_ring(mask, S, width_px):
    """The band of a mask within width of its outline (inside it)."""
    inner = blur(mask, width_px * 0.5, S).point(_lut(lambda v: (v - 250) * 50))
    return minus(mask, inner)


def mix(c0, c1, t):
    return tuple(int(a + (b - a) * t + 0.5) for a, b in zip(c0, c1, strict=True))


# --------------------------------------------------------------------------
# Finishing: master -> target size.
# --------------------------------------------------------------------------


def finish(master, size, sharpen, contrast, gamma):
    out = master.resize((size, size), Image.Resampling.LANCZOS)
    if sharpen:
        radius, percent = sharpen
        # Sharpen premultiplied so transparent neighbours (black, alpha 0)
        # cannot ring dark fringes into the edge pixels.
        out = out.convert("RGBa").filter(ImageFilter.UnsharpMask(radius, percent, 0)).convert("RGBA")
    if contrast != 1.0:
        out = ImageEnhance.Contrast(out).enhance(contrast)
    if gamma != 1.0:
        lut = _lut(lambda v: 255 * (v / 255.0) ** gamma + 0.5)
        r, g, b, a = out.split()
        out = Image.merge("RGBA", (r.point(lut), g.point(lut), b.point(lut), a))
    return out


# --------------------------------------------------------------------------
# The fan: five swept blades on a flat round hub, seen straight from below.
# --------------------------------------------------------------------------

# Light direction for the per-blade pitch shading: from the top-left and
# towards the viewer (screen x right, y down, z out of the screen).
LIGHT = (-0.55, -0.65, 0.52)

BLADE_DARK = (16, 16, 19)  # a blade turned away from the light
BLADE_LIT = (86, 86, 94)  # a blade turned towards it
HUB_TL, HUB_BR = (80, 80, 86), (24, 24, 27)
CAP_TL, CAP_BR = (30, 30, 34), (66, 66, 72)  # the cap is a shallow dish: lit on the far side
FAN_RIM = (150, 150, 158)


def fan_geometry(size):
    """Layout per size in target pixels. The hub is centred on a pixel and
    its radius ends on the pixel grid."""
    if size == 32:
        return dict(
            c=(15.5, 15.5),
            R=14.2,  # blade tip radius
            hub=4.5,
            cap=2.5,  # the stepped cap in the hub's middle (0: none)
            root=0.18,  # blade root radius, as a share of R
            hw_root=0.215,  # half-width at the root and at the tip, shares of R
            hw_tip=0.15,
            sweep=0.34,  # radians the centreline turns from root to tip
            cut=0.07,  # the tip's trailing corner is set back by this share of R
            rot=0.25,  # rotation of the whole fan, radians
            pitch=0.6,
            round_px=0.35,
            shadow=(0.6, 0.85, 0.85, 0.42),
            rim=0.55,
        )
    return dict(
        c=(7.5, 7.5),
        R=7.1,
        hub=2.5,
        cap=0.0,
        root=0.18,
        hw_root=0.23,
        hw_tip=0.16,
        sweep=0.34,
        cut=0.07,
        rot=0.25,
        pitch=0.6,
        round_px=0.25,
        shadow=(0.5, 0.7, 0.6, 0.45),
        rim=0.45,
    )


def _centreline(g, theta0, t):
    """Point, unit tangent and half-width of a blade's centreline at t
    (0 root .. 1 tip), relative to the hub's centre."""
    R = g["R"]
    r0 = g["root"] * R
    r = r0 + (R - r0) * t
    th = theta0 + g["sweep"] * t**1.5
    dth = g["sweep"] * 1.5 * t**0.5
    tx = (R - r0) * math.cos(th) - r * math.sin(th) * dth
    ty = (R - r0) * math.sin(th) + r * math.cos(th) * dth
    k = math.hypot(tx, ty)
    hw = R * (g["hw_root"] + (g["hw_tip"] - g["hw_root"]) * t)
    return r * math.cos(th), r * math.sin(th), tx / k, ty / k, hw


def blade_outline(g, theta0):
    """Polygon of one blade in target pixels: a swept centreline from the
    root to the tip, offset either side by a half-width that tapers, with
    the trailing corner of the tip set back (an angled cut)."""
    cx, cy = g["c"]
    lead, trail = [], []
    n = 64
    for i in range(n + 1):
        t = i / n
        x, y, tx, ty, hw = _centreline(g, theta0, t)
        lead.append((cx + x - ty * hw, cy + y + tx * hw))  # the leading side, where theta grows
        x, y, tx, ty, hw = _centreline(g, theta0, t * (1.0 - g["cut"]))
        trail.append((cx + x + ty * hw, cy + y - tx * hw))
    return lead + trail[::-1], theta0 + g["sweep"] * 0.5**1.5


def blade_tone(g, mid_angle):
    """Lambert shade of a pitched blade: its normal (towards the viewer)
    leans towards the blade's leading side by the pitch angle, so each of
    the five takes the light differently."""
    px, py = -math.sin(mid_angle), math.cos(mid_angle)
    s, c = math.sin(g["pitch"]), math.cos(g["pitch"])
    n = (s * px, s * py, c)
    ln = math.sqrt(sum(v * v for v in LIGHT))
    lam = sum(a * b for a, b in zip(n, LIGHT, strict=True)) / ln
    # Map the useful range of lam onto dark .. lit.
    return max(0.0, min(1.0, (lam - 0.1) / 0.8))


def render_fan(size):
    S = MASTER // size
    g = fan_geometry(size)
    cx, cy = g["c"]
    R = g["R"]
    near, far = (cx - R, cy - R), (cx + R, cy + R)

    blades = []
    for i in range(5):
        axis = g["rot"] + 2 * math.pi * i / 5 - math.pi / 2
        pts, mid = blade_outline(g, axis - g["sweep"] * 0.5)
        blades.append((soften(polygon(S, pts), g["round_px"], S), mid))
    blades_m = union(*[m for m, _ in blades])
    hub_m = ellipse(S, cx, cy, g["hub"], g["hub"])
    fan_m = union(blades_m, hub_m)

    # ---- height map: the blades and the hub's foot as one plane, the hub
    # proud of it, its cap stepped down ----
    H = empty()
    H = add_height(H, fan_m, 120, 0.35, S)
    H = add_height(H, hub_m, 60, 0.3, S)
    cap_m = ellipse(S, cx, cy, g["cap"], g["cap"]) if g["cap"] else None
    if cap_m:
        H = add_height(H, cap_m, -16, 0.12, S)

    # ---- albedo ----
    img = solid((0, 0, 0, 0))
    sdx, sdy, sr, sa = g["shadow"]
    img = over(img, drop_shadow(fan_m, S, sdx, sdy, sr, sa))
    img = over(img, drop_shadow(fan_m, S, 0.12, 0.18, 0.2, 0.3))
    for m, mid in blades:
        tone = blade_tone(g, mid)
        c_root = mix(BLADE_DARK, BLADE_LIT, tone * 0.7)
        c_tip = mix(BLADE_DARK, BLADE_LIT, min(1.0, tone * 0.95 + 0.05))
        # Along the blade: a touch darker at the root, in the hub's shadow.
        p0 = (cx + 0.25 * R * math.cos(mid), cy + 0.25 * R * math.sin(mid))
        p1 = (cx + R * math.cos(mid), cy + R * math.sin(mid))
        img = over(img, grad_fill(m, c_root, c_tip, S, p0, p1))
    img = grain(img, S, 0.05, seed=7, mask=blades_m)

    # The hub's shadow onto the blade roots, then the hub and its cap.
    sh = drop_shadow(hub_m, S, 0.35, 0.45, 0.45, 0.5)
    sh.putalpha(mul(sh.getchannel("A"), minus(blades_m, hub_m)))
    img = over(img, sh)
    hr = g["hub"]
    img = over(img, grad_fill(hub_m, HUB_TL, HUB_BR, S, (cx - hr, cy - hr), (cx + hr, cy + hr)))
    if cap_m:
        cr = g["cap"]
        img = over(img, grad_fill(cap_m, CAP_TL, CAP_BR, S, (cx - cr, cy - cr), (cx + cr, cy + cr)))
    img = grain(img, S, 0.04, seed=19, mask=hub_m)

    # ---- lighting ----
    img = shade(img, H, S, d_px=0.2, gain_hi=1.5, gain_lo=1.2, mask=fan_m)
    img = occlusion(img, H, S, r_px=0.5, gain=0.8, mask=fan_m)
    img = specular(img, H, S, d_px=0.25, strength=0.45, gloss_mask=fan_m, power=2.0, soften_px=0.06)

    # ---- outline: a lit rim on the top-left edges so the black reads ----
    rim = edge_ring(fan_m, S, g["rim"])
    img = over(img, layer(mul(rim, lin_grad(S, far, near)), FAN_RIM, 0.55))
    return img


# --------------------------------------------------------------------------
# The light: a glowing drum between black rings, seen from slightly below.
# --------------------------------------------------------------------------

BLACK_TL, BLACK_BR = (74, 74, 80), (18, 18, 21)
DRUM_LIT = (255, 252, 245)  # the glowing body, warm white
DRUM_EDGE = (224, 218, 208)  # its left silhouette, where the opal is seen edge-on
DRUM_SHADE = (196, 190, 181)  # its right side, away from the light
DRUM_TOP = (206, 201, 194)  # under the ceiling disc, where less light reaches
DIFFUSER = (255, 246, 222)
GLOW = (255, 182, 84)
OUTLINE = (128, 124, 118)


def light_geometry(size):
    """Layout per size in target pixels (y grows downwards). The disc's
    lower edge and the ring's top and bottom rows land on the pixel grid."""
    if size == 32:
        return dict(
            cx=15.5,
            disc=(4.0, 3.5, 27.0, 6.0),  # the ceiling disc band, narrower than the drum
            disc_r=1.0,
            drum=(2.0, 6.0, 29.0),  # x0, top, x1 of the drum's sides
            shoulder=1.6,  # the drum's rounded top corners
            ring_c=22.5,  # centre row of the bottom ring
            ring_rx=12.0,
            ring_ry=4.5,
            ring_w=1.5,  # ring width across (x) and down (y)
            ring_wy=1.25,
            glow=(1.5, 0.5),
            shadow=(0.6, 0.9, 0.9, 0.38),
            outline=0.6,
            outline_alpha=0.65,
        )
    return dict(
        cx=7.5,
        disc=(3.0, 1.5, 12.0, 3.0),
        disc_r=0.5,
        drum=(1.0, 3.0, 14.0),
        shoulder=0.8,
        ring_c=11.5,
        ring_rx=6.0,
        ring_ry=2.5,
        ring_w=1.0,
        ring_wy=1.0,
        glow=(1.0, 0.55),
        shadow=(0.45, 0.6, 0.55, 0.42),
        outline=0.5,
        outline_alpha=0.8,
    )


def render_light(size):
    S = MASTER // size
    g = light_geometry(size)
    cx = g["cx"]
    dx0, dtop, dx1 = g["drum"]
    drx = (dx1 - dx0) / 2.0
    rc, rrx, rry = g["ring_c"], g["ring_rx"], g["ring_ry"]
    near, far = (dx0 - 2, g["disc"][1] - 2), (dx1 + 2, rc + rry + 2)

    disc_m = rrect(S, g["disc"], g["disc_r"])
    # The drum: its side from the ceiling disc down to the bottom edge, an
    # ellipse a little wider than the ring, whose near (upper) arc the ring
    # covers; seen from below, so the ring's whole ellipse shows.
    side = union(
        rrect(S, (dx0, dtop, dx1, rc), g["shoulder"]),
        ellipse(S, cx, rc - 0.2 * rry, drx, rry * drx / rrx),
    )
    ring_outer = ellipse(S, cx, rc, rrx, rry)
    ring_inner = ellipse(S, cx, rc, rrx - g["ring_w"], rry - g["ring_wy"])
    ring_m = minus(ring_outer, ring_inner)
    drum_m = minus(side, union(ring_outer, disc_m))
    body_m = union(side, ring_outer, disc_m)

    # ---- height map ----
    H = empty()
    H = add_height(H, body_m, 110, 0.35, S)
    H = add_height(H, ring_m, 40, 0.15, S)
    H = add_height(H, disc_m, 30, 0.15, S)
    H = add_height(H, ring_inner, -30, 0.3, S)

    img = solid((0, 0, 0, 0))
    # A faint warm glow round the whole fixture, then its drop shadow.
    gr, ga = g["glow"]
    img = over(img, layer(blur(union(side, ring_outer), gr, S), GLOW, ga))
    sdx, sdy, sr, sa = g["shadow"]
    img = over(img, drop_shadow(body_m, S, sdx, sdy, sr, sa))

    # ---- the glowing drum: emissive, brightest a little left of centre,
    # falling off towards both silhouettes and more on the right ----
    def drum_tone(x):
        u = max(-1.0, min(1.0, (x - cx) / drx))  # -1 .. 1 across the drum
        if u < -0.25:
            return 255 * (1 - ((u + 0.25) / 0.75) ** 2)
        return 255 * (1 - ((u + 0.25) / 1.25) ** 1.7)

    prof = column_profile(S, drum_tone)  # 255 lit .. 0 edge
    left = column_profile(S, lambda x: 255 if x < cx else 0)
    edge_col = Image.composite(solid(DRUM_EDGE + (255,)), solid(DRUM_SHADE + (255,)), left)
    drum = Image.composite(solid(DRUM_LIT + (255,)), edge_col, prof)
    drum.putalpha(drum_m)
    img = over(img, drum)
    # Less light right under the disc; it gathers just above the ring.
    top = mul(ImageChops.invert(lin_grad(S, (0, dtop), (0, (dtop + rc) / 2.0))), drum_m)
    img = over(img, layer(top, DRUM_TOP, 0.45))
    band = mul(blur(minus(ellipse(S, cx, rc - 0.4, rrx + 0.4, rry + 0.4), ring_outer), 0.5, S), drum_m)
    img = over(img, layer(band, (255, 238, 205), 0.4))

    # ---- the diffuser inside the ring: the brightest part ----
    dif = grad_fill(ring_inner, (255, 255, 250), DIFFUSER, S, (cx - rrx, rc - rry), (cx + rrx, rc + rry))
    img = over(img, dif)
    hot = mul(radial(S, (cx - 0.15 * rrx, rc + 0.1 * rry), rrx * 0.8, ry_px=rry * 0.8), ring_inner)
    img = over(img, layer(hot, (255, 255, 255), 0.6))

    # ---- the black parts ----
    img = over(img, grad_fill(ring_m, BLACK_TL, BLACK_BR, S, near, far))
    img = over(img, grad_fill(disc_m, BLACK_TL, BLACK_BR, S, near, far))
    blacks = union(ring_m, disc_m)
    img = grain(img, S, 0.05, seed=29, mask=blacks)

    # ---- lighting on the black parts ----
    img = shade(img, H, S, d_px=0.18, gain_hi=1.3, gain_lo=0.9, mask=blacks)
    img = specular(img, H, S, d_px=0.2, strength=0.35, gloss_mask=blacks, power=2.0, soften_px=0.05)
    # The disc throws a little shadow onto the top of the drum.
    sh = drop_shadow(disc_m, S, 0.0, 0.35, 0.35, 0.35)
    sh.putalpha(mul(sh.getchannel("A"), drum_m))
    img = over(img, sh)

    # ---- outline: a soft grey edge round the drum's silhouette ----
    rim = mul(edge_ring(side, S, g["outline"]), drum_m)
    img = over(img, layer(rim, OUTLINE, g["outline_alpha"]))
    return img


# --------------------------------------------------------------------------
# Output.
# --------------------------------------------------------------------------

FINISH = {
    # size: (unsharp (radius, percent), contrast, gamma)
    32: ((0.7, 60), 1.04, 1.0),
    16: ((0.6, 85), 1.08, 0.98),
}

ICONS = [
    ("modernforms_fan", 16, render_fan),
    ("modernforms_fan", 32, render_fan),
    ("modernforms_light", 16, render_light),
    ("modernforms_light", 32, render_light),
]


def build_all():
    """Returns [(name, size, master, icon)] in output order."""
    out = []
    for name, size, fn in ICONS:
        master = fn(size)
        sharpen, contrast, gamma = FINISH[size]
        out.append((name, size, master, finish(master, size, sharpen, contrast, gamma)))
    return out


def save(img, path, root):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, format="PNG", dpi=DPI, optimize=True)
    with Image.open(path) as check:
        print("wrote %s (%dx%d, %s)" % (os.path.relpath(path, root), check.width, check.height, check.mode))


def inspection_sheet(results, out_dir):
    scales = (1, 4, 8)
    pad = 12
    cell = 32 * 8
    cols = len(results)
    row_h = sum(32 * s for s in scales) + pad * (len(scales) + 1)
    sheet = Image.new("RGB", (cols * (cell + pad) + pad, row_h * 2 + pad), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    for bi, bg in enumerate(((255, 255, 255), (240, 240, 240))):
        y_top = bi * row_h + pad
        d.rectangle((0, bi * row_h, sheet.width, (bi + 1) * row_h), fill=bg)
        for ci, (name, size, _master, icon) in enumerate(results):
            x = pad + ci * (cell + pad)
            y = y_top
            d.text((x, y - 10), "%s %d" % (name, size), fill=(90, 90, 90))
            for s in scales:
                big = icon.resize((size * s, size * s), Image.Resampling.NEAREST)
                sheet.paste(big, (x, y + pad), big)
                y += 32 * s + pad
    path = os.path.join(out_dir, "icons_sheet.png")
    sheet.save(path)
    print("wrote", path)
    for name, size, master, _icon in results:
        mp = os.path.join(out_dir, "icons_master_%s_%d.png" % (name, size))
        master.save(mp)
        print("wrote", mp)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Draw the Composer icons of the Modern Forms fan driver.")
    ap.add_argument("--out", metavar="DIR", default=REPO_ROOT, help="root to write under (default: the repository)")
    ap.add_argument("--inspect", metavar="DIR", help="also write the masters and an inspection sheet here")
    args = ap.parse_args(argv)
    results = build_all()
    for name, size, _master, icon in results:
        save(icon, os.path.join(args.out, rel_path(name, size)), args.out)
    if args.inspect:
        os.makedirs(args.inspect, exist_ok=True)
        inspection_sheet(results, args.inspect)
    return 0


if __name__ == "__main__":
    sys.exit(main())
