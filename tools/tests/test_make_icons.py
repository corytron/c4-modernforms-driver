"""Unit tests for tools/make_icons.py: the six committed Composer icons (the fan driver's fan and light, the
Breeze switch's gust) are RGBA at 16 and 32 px with a transparent background and something drawn on it, each
lies in its own package and is the file that package's driver.xml names, and the generator, run into a
temporary directory, reproduces them byte for byte.

Skipped when Pillow cannot be imported (CI's runner may not have it): the generator is the one tool that
needs it.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import contextlib
import io
import os
import re
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

try:
    from PIL import Image
except ImportError:  # CI's runner may not have Pillow
    Image = None
    make_icons = None
else:
    import make_icons

ICONS = [
    ("modernforms_fan", 16),
    ("modernforms_fan", 32),
    ("modernforms_light", 16),
    ("modernforms_light", 32),
    ("modernforms_breeze", 16),
    ("modernforms_breeze", 32),
]

# The package each icon belongs to: src/<package>/www/images/.
PACKAGE = {
    "modernforms_fan": "modernforms_fan",
    "modernforms_light": "modernforms_fan",
    "modernforms_breeze": "modernforms_breeze",
}

# The share of an icon's pixels that must be (nearly) opaque: the fan's five blades and hub cover
# over a quarter of the square, the drum light over half of it; the gust's three strokes about a fifth
# at 32 px and under a third at 16 px.
MIN_OPAQUE_SHARE = {"modernforms_fan": 0.2, "modernforms_light": 0.2, "modernforms_breeze": 0.15}


@unittest.skipUnless(Image is not None, "Pillow is not installed")
class MakeIconsTest(unittest.TestCase):
    def committed(self, name, size):
        return os.path.join(REPO, make_icons.rel_path(name, size))

    def test_committed_icons_are_rgba_at_their_size(self):
        for name, size in ICONS:
            with self.subTest(icon="%s_%d" % (name, size)):
                path = self.committed(name, size)
                self.assertTrue(os.path.isfile(path), path)
                with Image.open(path) as im:
                    self.assertEqual(im.format, "PNG")
                    self.assertEqual(im.mode, "RGBA")
                    self.assertEqual(im.size, (size, size))

    def test_background_is_transparent(self):
        for name, size in ICONS:
            with self.subTest(icon="%s_%d" % (name, size)), Image.open(self.committed(name, size)) as im:
                alpha = im.getchannel("A")
                last = size - 1
                for corner in ((0, 0), (last, 0), (0, last), (last, last)):
                    self.assertEqual(alpha.getpixel(corner), 0, corner)

    def test_icons_are_not_empty(self):
        for name, size in ICONS:
            with self.subTest(icon="%s_%d" % (name, size)), Image.open(self.committed(name, size)) as im:
                alpha = im.getchannel("A")
                opaque = sum(1 for y in range(size) for x in range(size) if alpha.getpixel((x, y)) >= 200)
                self.assertGreaterEqual(opaque, MIN_OPAQUE_SHARE[name] * size * size)

    def test_the_generator_draws_exactly_these_icons(self):
        self.assertEqual([(name, size) for name, size, _fn in make_icons.ICONS], ICONS)

    def test_each_icon_lies_in_its_own_package(self):
        for name, size in ICONS:
            with self.subTest(icon="%s_%d" % (name, size)):
                sub = "devices_sm" if size == 16 else "devices_lg"
                self.assertEqual(
                    make_icons.rel_path(name, size),
                    os.path.join("src", PACKAGE[name], "www", "images", sub, "%s_%d.png" % (name, size)),
                )

    def test_each_driver_xml_names_its_own_drawn_icons(self):
        # <small>, <large> and every proxy's small_image and large_image, all from the c4z.
        for package in sorted(set(PACKAGE.values())):
            with self.subTest(package=package):
                with open(os.path.join(REPO, "src", package, "driver.xml"), encoding="utf-8") as f:
                    xml = re.sub(r"<!--.*?-->", "", f.read(), flags=re.S)
                named = set(re.findall(r'<(?:small|large) image_source="c4z">([^<]+)</', xml))
                named |= set(re.findall(r'(?:small|large)_image="([^"]+)"', xml))
                drawn = {
                    make_icons.rel_path(name, size).split(os.sep + "www" + os.sep, 1)[1].replace(os.sep, "/")
                    for name, size in ICONS
                    if PACKAGE[name] == package
                }
                self.assertTrue(named, "driver.xml names no icon")
                self.assertTrue(named <= drawn, sorted(named - drawn))
                self.assertIn("images/devices_sm/%s_16.png" % package, named)
                self.assertIn("images/devices_lg/%s_32.png" % package, named)

    def test_generator_reproduces_the_committed_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(make_icons.main(["--out", tmp]), 0)
            for name, size in ICONS:
                with self.subTest(icon="%s_%d" % (name, size)):
                    with open(os.path.join(tmp, make_icons.rel_path(name, size)), "rb") as f:
                        fresh = f.read()
                    with open(self.committed(name, size), "rb") as f:
                        committed = f.read()
                    self.assertEqual(fresh, committed, "run python3 tools/make_icons.py and commit the icons it writes")


if __name__ == "__main__":
    unittest.main()
