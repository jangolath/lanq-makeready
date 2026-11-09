"""Pixel-art banner + icon for lanq-makeready, matching the LanQueue palette.
Drawn at native low resolution, upscaled with nearest-neighbour. Usage: python makeready_art.py OUTDIR"""
import math
import sys
from PIL import Image

BG = (12, 24, 34)
BG2 = (9, 19, 28)
TEAL = (62, 228, 196)
TEAL_D = (32, 140, 122)
BEIGE = (238, 214, 176)
BEIGE_S = (201, 172, 132)
BEIGE_D = (150, 122, 92)
INK = (26, 30, 36)
SCREEN = (14, 42, 44)
AMBER = (255, 184, 72)
RED = (226, 72, 60)
WHITE = (240, 246, 240)

FONT = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01111", "10000", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    "-": ["00000", "00000", "00000", "01110", "00000", "00000", "00000"],
    "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
    " ": ["00000"] * 7,
}


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("RGB", (w, h), BG)
        self.px = self.img.load()

    def dot(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[x, y] = c

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.dot(xx, yy, c)

    def box(self, x, y, w, h, fill, outline=INK, shade=None):
        self.rect(x, y, w, h, outline)
        self.rect(x + 1, y + 1, w - 2, h - 2, fill)
        if shade:
            self.rect(x + 1, y + h - 3, w - 2, 2, shade)
            self.rect(x + w - 3, y + 1, 2, h - 2, shade)

    def text(self, s, x, y, c, scale=1, gap=1, shadow=None):
        cx = x
        for ch in s.upper():
            g = FONT[ch]
            for gy, row in enumerate(g):
                for gx, bit in enumerate(row):
                    if bit == "1":
                        if shadow:
                            self.rect(cx + gx * scale + 1, y + gy * scale + 1, scale, scale, shadow)
                        self.rect(cx + gx * scale, y + gy * scale, scale, scale, c)
            cx += 5 * scale + gap * scale
        return cx

    @staticmethod
    def text_width(s, scale=1, gap=1):
        return len(s) * (5 + gap) * scale - gap * scale

    def frame(self, inset, radius, c, thick=2):
        x0, y0, x1, y1 = inset, inset, self.w - 1 - inset, self.h - 1 - inset
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                dx = max(x0 + radius - x, 0, x - (x1 - radius))
                dy = max(y0 + radius - y, 0, y - (y1 - radius))
                d = math.hypot(dx, dy) if dx and dy else max(dx, dy)
                edge = min(x - x0, x1 - x, y - y0, y1 - y)
                inside = d <= radius if (dx and dy) else True
                if inside and ((dx and dy and d > radius - thick) or (not (dx and dy) and edge < thick)):
                    self.dot(x, y, c)

    def scanlines(self):
        for y in range(0, self.h, 2):
            for x in range(self.w):
                if self.px[x, y] == BG:
                    self.px[x, y] = BG2

    def ring(self, cx, cy, r, thick, c, fill=None):
        for y in range(cy - r - 1, cy + r + 2):
            for x in range(cx - r - 1, cx + r + 2):
                d = math.hypot(x - cx, y - cy)
                if fill and d < r - thick + 0.5:
                    self.dot(x, y, fill)
                elif r - thick + 0.5 <= d <= r + 0.5:
                    self.dot(x, y, c)


def check(cv, x, y, c):
    for i, (dx, dy) in enumerate([(0, 2), (1, 3), (2, 4), (3, 3), (4, 2), (5, 1), (6, 0)]):
        cv.dot(x + dx, y + dy, c)
        cv.dot(x + dx, y + dy + 1, c)


def old_pc(cv, ox, oy):
    """Beige CRT + desktop case + keyboard; screen shows the scan checklist. ~84x80."""
    # monitor
    cv.box(ox + 8, oy, 64, 50, BEIGE, shade=BEIGE_S)
    cv.rect(ox + 13, oy + 5, 54, 38, INK)
    cv.rect(ox + 14, oy + 6, 52, 36, SCREEN)
    # checklist rows: ok, ok, warn (being fixed)
    rows = [(TEAL, 40, "ok"), (TEAL, 40, "ok"), (AMBER, 22, "warn")]
    for i, (col, fill, kind) in enumerate(rows):
        ry = oy + 10 + i * 10
        cv.rect(ox + 18, ry, 9, 8, col)
        cv.rect(ox + 19, ry + 1, 7, 6, SCREEN)
        if kind == "ok":
            check(cv, ox + 19, ry + 1, col)
        else:
            cv.rect(ox + 22, ry + 2, 1, 3, col)
            cv.dot(ox + 22, ry + 6, col)
        cv.rect(ox + 30, ry + 1, 32, 6, TEAL_D)
        cv.rect(ox + 31, ry + 2, 30, 4, SCREEN)
        for sx in range(ox + 31, ox + 31 + fill // 40 * 30 + (fill % 40) * 30 // 40, 2):
            cv.rect(sx, ry + 2, 1, 4, col)
    # scan beam
    cv.rect(ox + 14, oy + 35, 52, 1, TEAL_D)
    # stand
    cv.rect(ox + 32, oy + 50, 16, 3, BEIGE_D)
    # case
    cv.box(ox, oy + 53, 80, 16, BEIGE, shade=BEIGE_S)
    cv.rect(ox + 44, oy + 58, 28, 2, INK)
    cv.rect(ox + 44, oy + 62, 28, 2, INK)
    cv.rect(ox + 8, oy + 59, 3, 3, RED)
    cv.rect(ox + 14, oy + 59, 3, 3, TEAL)
    # keyboard
    cv.box(ox + 6, oy + 71, 68, 9, BEIGE, shade=BEIGE_S)
    for kx in range(ox + 9, ox + 70, 4):
        cv.rect(kx, oy + 73, 2, 1, BEIGE_D)
        cv.rect(kx + 1, oy + 75, 2, 1, BEIGE_D)


def wrench(cv, x, y):
    """Diagonal wrench, head at (x,y), ~18px long, pointing down-left."""
    for i in range(14):
        cv.rect(x - 4 - i, y + 4 + i, 3, 3, INK)
    for i in range(14):
        cv.rect(x - 4 - i, y + 5 + i, 2, 2, BEIGE_S)
    cv.ring(x, y, 5, 3, INK)
    cv.ring(x, y, 4, 2, BEIGE)
    cv.rect(x + 1, y - 5, 5, 5, BG)  # open jaw
    cv.scan_safe = True


def magnifier(cv, cx, cy, r=10):
    cv.ring(cx, cy, r + 1, 1, INK)
    cv.ring(cx, cy, r, 3, TEAL, fill=None)
    for i in range(10):
        cv.rect(cx + r - 2 + i, cy + r - 2 + i, 4, 4, INK)
        cv.rect(cx + r - 1 + i, cy + r - 1 + i, 2, 2, BEIGE_D)
    cv.dot(cx - r // 2, cy - r // 2, WHITE)
    cv.dot(cx - r // 2 + 1, cy - r // 2, WHITE)
    cv.dot(cx - r // 2, cy - r // 2 + 1, WHITE)


def moon(cv, x, y):
    cv.ring(x, y, 6, 6, AMBER, fill=AMBER)
    cv.ring(x + 3, y - 2, 6, 6, BG, fill=BG)
    for sx, sy in [(x + 14, y - 3), (x + 22, y + 5), (x + 9, y + 11)]:
        cv.dot(sx, sy, WHITE)
        cv.dot(sx - 1, sy, TEAL_D)
        cv.dot(sx + 1, sy, TEAL_D)
        cv.dot(sx, sy - 1, TEAL_D)
        cv.dot(sx, sy + 1, TEAL_D)


def sparks(cv, x, y, c=TEAL):
    for dx, dy in [(0, 0), (1, -1), (2, -2)]:
        cv.dot(x + dx, y + dy, c)
    for dx, dy in [(4, 2), (5, 2), (6, 2)]:
        cv.dot(x + dx, y + dy, c)


def banner(out):
    cv = Canvas(300, 100)
    pc_x, pc_y = 18, 10
    old_pc(cv, pc_x, pc_y)
    magnifier(cv, pc_x + 80, pc_y + 34, 10)
    moon(cv, 214, 15)
    tx = 122
    tw = Canvas.text_width("MAKEREADY", 3, 1)
    cv.text("MAKE", tx, 30, BEIGE, scale=3, shadow=INK)
    cv.text("READY", tx + Canvas.text_width("MAKE", 3, 1) + 4, 30, TEAL, scale=3, shadow=INK)
    # underline swoosh
    for i in range(tw - 16):
        cv.dot(tx + 10 + i, 56 + (0 if i < tw // 2 else 0), TEAL)
        cv.dot(tx + 10 + i, 57, TEAL_D)
    cv.text("OLD PC. READY BY MORNING.", tx, 66, BEIGE, scale=1)
    cv.text("SCAN - TUNE - BACK TO WORK", tx, 76, TEAL, scale=1)
    cv.text("FOR LANQUEUE", 300 - 14 - Canvas.text_width("FOR LANQUEUE"), 84, TEAL_D, scale=1)
    cv.frame(3, 9, TEAL, thick=2)
    cv.scanlines()
    cv.img.resize((1200, 400), Image.NEAREST).save(f"{out}/makeready-banner.png", optimize=True)


def icon(out):
    cv = Canvas(128, 128)
    old_pc(cv, 20, 12)
    magnifier(cv, 100, 48, 9)
    moon(cv, 96, 16)
    tw = Canvas.text_width("MAKEREADY", 2, 1)
    tx = (128 - tw) // 2
    cv.text("MAKE", tx, 102, BEIGE, scale=2, shadow=INK)
    cv.text("READY", tx + Canvas.text_width("MAKE", 2, 1) + 2, 102, TEAL, scale=2, shadow=INK)
    cv.frame(3, 10, TEAL, thick=2)
    cv.scanlines()
    cv.img.resize((512, 512), Image.NEAREST).save(f"{out}/makeready-icon-512.png", optimize=True)
    cv.img.resize((128, 128), Image.NEAREST).save(f"{out}/makeready-icon.png", optimize=True)


if __name__ == "__main__":
    out = sys.argv[1]
    banner(out)
    icon(out)
