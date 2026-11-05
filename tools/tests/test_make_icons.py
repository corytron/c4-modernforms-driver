"""Unit tests for tools/make_icons.py: the four committed Composer icons are RGBA at 16 and 32 px with a
transparent background and something drawn on it, and the generator, run into a temporary directory,
reproduces them byte for byte.

Skipped when Pillow cannot be imported (CI's runner may not have it): the generator is the one tool that
needs it.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import contextlib
import io
import os
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
]

# The share of an icon's pixels that must be (nearly) opaque: the fan's five blades and hub cover
# over a quarter of the square, the drum light over half of it.
MIN_OPAQUE_SHARE = 0.2


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
                self.assertGreaterEqual(opaque, MIN_OPAQUE_SHARE * size * size)

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
