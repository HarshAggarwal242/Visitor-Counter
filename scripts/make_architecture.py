"""
Generate reports/architecture.png - the architecture diagram used in the report.

Usage (from the project root):
    python scripts/make_architecture.py

Requires Pillow (pip install pillow). Uses Windows fonts when available and
falls back to Pillow's built-in font, so it also runs on other systems.
"""

import math
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = PROJECT_ROOT / "reports" / "architecture.png"

WIDTH, HEIGHT = 2200, 1300

INK = "#0F172A"
MUTED = "#475569"
WHITE = "#FFFFFF"
GREY_BORDER = "#CBD5E1"

DOCKER_FILL = "#EFF6FF"
DOCKER_BORDER = "#2563EB"
PRIMARY_FILL = "#EFF6FF"
PRIMARY_BORDER = "#1D4ED8"
SECONDARY_FILL = "#F5F3FF"
SECONDARY_BORDER = "#7C3AED"
NOTE_FILL = "#FFFBEB"
NOTE_BORDER = "#D97706"
ARROW = "#334155"
FAILOVER = "#DC2626"

FONT_REGULAR = [
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]
FONT_BOLD = [
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]

_cache = {}


def resolve_font(candidates):
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


_REGULAR = resolve_font(FONT_REGULAR)
_BOLD = resolve_font(FONT_BOLD)


def font(size, bold=False):
    key = (size, bold)
    if key not in _cache:
        path = _BOLD if bold else _REGULAR
        if path:
            _cache[key] = ImageFont.truetype(path, size)
        else:
            try:
                _cache[key] = ImageFont.load_default(size=size)
            except TypeError:  # Pillow < 10.1
                _cache[key] = ImageFont.load_default()
    return _cache[key]


def text_width(text, fnt):
    left, _, right, _ = fnt.getbbox(text)
    return right - left


def wrap(text, fnt, max_width):
    words = text.split()
    lines, current = [], ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if text_width(candidate, fnt) <= max_width or not current:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def draw_center(draw, cx, y, text, fnt, fill=INK):
    draw.text((cx - text_width(text, fnt) / 2, y), text, font=fnt, fill=fill)


def rounded_box(draw, box, fill, outline, width=2, radius=14):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def label_box(draw, box, title, body_lines, outline=GREY_BORDER, fill=WHITE,
              title_size=19, body_size=13):
    rounded_box(draw, box, fill, outline)
    x1, y1, x2, y2 = box
    cx = (x1 + x2) / 2
    inner = (x2 - x1) - 30

    title_font = font(title_size, bold=True)
    body_font = font(body_size)
    title_lines = wrap(title, title_font, inner)
    body_wrapped = []
    for line in body_lines:
        body_wrapped.extend(wrap(line, body_font, inner))

    title_h = len(title_lines) * (title_size + 4)
    body_h = len(body_wrapped) * (body_size + 5)
    total = title_h + (6 if body_wrapped else 0) + body_h
    y = (y1 + y2) / 2 - total / 2

    for line in title_lines:
        draw_center(draw, cx, y, line, title_font)
        y += title_size + 4
    if body_wrapped:
        y += 6
        for line in body_wrapped:
            draw_center(draw, cx, y, line, body_font, MUTED)
            y += body_size + 5


def arrow(draw, start, end, color=ARROW, width=3, dashed=False, head=13):
    x1, y1 = start
    x2, y2 = end
    angle = math.atan2(y2 - y1, x2 - x1)
    tip_x = x2 - head * 0.8 * math.cos(angle)
    tip_y = y2 - head * 0.8 * math.sin(angle)

    if dashed:
        dashed_line(draw, (x1, y1), (tip_x, tip_y), color, width)
    else:
        draw.line([(x1, y1), (tip_x, tip_y)], fill=color, width=width)

    left = (x2 - head * math.cos(angle - math.pi / 7), y2 - head * math.sin(angle - math.pi / 7))
    right = (x2 - head * math.cos(angle + math.pi / 7), y2 - head * math.sin(angle + math.pi / 7))
    draw.polygon([(x2, y2), left, right], fill=color)


def dashed_line(draw, p1, p2, color=ARROW, width=3, dash=12, gap=9):
    x1, y1 = p1
    x2, y2 = p2
    total = math.hypot(x2 - x1, y2 - y1)
    if total == 0:
        return
    pos = 0.0
    while pos < total:
        end_pos = min(pos + dash, total)
        sx = x1 + (x2 - x1) * pos / total
        sy = y1 + (y2 - y1) * pos / total
        ex = x1 + (x2 - x1) * end_pos / total
        ey = y1 + (y2 - y1) * end_pos / total
        draw.line([(sx, sy), (ex, ey)], fill=color, width=width)
        pos += dash + gap


def panel(draw, box, title, subtitle, fill, outline):
    rounded_box(draw, box, fill, outline, width=4, radius=22)
    x1, y1, x2, y2 = box
    cx = (x1 + x2) / 2
    draw_center(draw, cx, y1 + 16, title, font(24, bold=True), outline)
    if subtitle:
        draw_center(draw, cx, y1 + 56, subtitle, font(15), MUTED)


def pods(draw, box, count=3, size=36):
    x1, y1, x2, y2 = box
    gap = 18
    total = count * size + (count - 1) * gap
    start_x = (x1 + x2) / 2 - total / 2
    top = y2 - size - 14
    for index in range(count):
        px = start_x + index * (size + gap)
        draw.rounded_rectangle((px, top, px + size, top + size), radius=8, fill=WHITE,
                               outline="#94A3B8", width=2)
        draw_center(draw, px + size / 2, top + 9, "pod", font(11, bold=True), MUTED)


def k8s_cluster(draw, top, title, subtitle, fill, outline):
    """Draw one Minikube cluster panel; `top` is the panel's top edge."""
    panel(draw, (1080, top, 2140, top + 450), title, subtitle, fill, outline)

    row1 = top + 98
    row2 = row1 + 70
    row3 = row2 + 70
    row4 = row3 + 116

    # metrics + autoscaler
    label_box(draw, (1110, row1, 1420, row1 + 54), "Metrics Server", ["addon: metrics-server"], outline)
    label_box(draw, (1460, row1, 2110, row1 + 54), "Horizontal Pod Autoscaler",
              ["CPU target 50% · min 2 · max 5"], outline)

    # service
    label_box(draw, (1110, row2, 2110, row2 + 54), "Service visitor-counter",
              ["NodePort 30080 → targetPort 5000"], outline)
    arrow(draw, (1610, row1 + 54), (1610, row2 - 4))

    # deployment with pods
    deployment = (1110, row3, 2110, row3 + 96)
    rounded_box(draw, deployment, WHITE, outline)
    draw_center(draw, 1610, row3 + 9, "Deployment visitor-counter · 2–5 Pods (gunicorn)",
                font(17, bold=True))
    pods(draw, deployment, count=3)
    arrow(draw, (1610, row2 + 54), (1610, row3 - 4))

    # HPA control path: dashed line down the panel edge, into the Deployment
    dashed_line(draw, (2126, row1 + 27), (2126, row3 + 48), outline, 3)
    arrow(draw, (2126, row3 + 48), (2112, row3 + 48), color=outline, head=10)

    # redis service + pod
    label_box(draw, (1110, row4, 1600, row4 + 58), "Service redis", ["ClusterIP :6379"], outline)
    label_box(draw, (1640, row4, 2110, row4 + 58), "Deployment redis + PVC",
              ["Redis 7 · AOF · 1Gi persistent volume"], outline)
    arrow(draw, (1300, row3 + 96), (1300, row4 - 4))
    arrow(draw, (1600, row4 + 29), (1640, row4 + 29), head=10)


def build():
    img = Image.new("RGB", (WIDTH, HEIGHT), WHITE)
    draw = ImageDraw.Draw(img)

    # ---------------- title ----------------
    draw_center(draw, WIDTH / 2, 20, "Visitor Counter — Cloud Computing Project Architecture",
                font(38, bold=True))
    draw_center(draw, WIDTH / 2, 74,
                "Flask + Redis · Docker Compose · Kubernetes (Minikube) · HPA autoscaling · "
                "two-cluster hybrid cloud failover simulation",
                font(17), MUTED)

    # ---------------- browser ----------------
    label_box(draw, (760, 120, 1440, 198), "User / Browser",
              ["http://localhost:8080 · concurrent visitors generate the load"],
              outline="#4338CA", fill="#EEF2FF", title_size=21)

    draw.line([(1100, 198), (1100, 222)], fill=ARROW, width=3)
    draw.line([(540, 222), (1500, 222)], fill=ARROW, width=3)
    arrow(draw, (540, 222), (540, 250), head=10)
    arrow(draw, (1500, 222), (1500, 250), head=10)

    # ---------------- Docker Compose panel ----------------
    panel(draw, (60, 250, 1020, 700), "Docker Desktop · Docker Compose",
          "local development and first verification", DOCKER_FILL, DOCKER_BORDER)

    label_box(draw, (110, 340, 970, 430), "Container visitor-counter-flask",
              ["image visitor-counter:optimized (python:3.12-slim, non-root)",
               "gunicorn on :5000 · published as localhost:8080"],
              DOCKER_BORDER)
    arrow(draw, (540, 430), (540, 466))
    label_box(draw, (110, 466, 970, 556), "Container visitor-counter-redis",
              ["redis:7-alpine · :6379 · appendonly yes · requirepass"], DOCKER_BORDER)
    arrow(draw, (540, 556), (540, 588))
    label_box(draw, (110, 588, 970, 646), "Named volume redis-data → /data",
              ["the visit count survives container restarts"], "#94A3B8")

    draw_center(draw, 540, 664, "bridge network visitor-counter-net · healthchecks on both containers",
                font(14), MUTED)

    # ---------------- Kubernetes clusters ----------------
    k8s_cluster(draw, 250, "Minikube cluster 1 · vc-primary",
                "simulated PRIVATE cloud (active environment)", PRIMARY_FILL, PRIMARY_BORDER)
    k8s_cluster(draw, 770, "Minikube cluster 2 · vc-secondary",
                "simulated PUBLIC cloud (standby environment)", SECONDARY_FILL, SECONDARY_BORDER)

    # failover connector
    arrow(draw, (2000, 700), (2000, 768), color=FAILOVER, width=4, dashed=True, head=15)
    draw_center(draw, 1400, 720,
                "failover.ps1 · probes /health and re-points localhost:8080 to the standby cluster",
                font(15, bold=True), FAILOVER)

    # ---------------- notes / legend ----------------
    panel(draw, (60, 770, 1020, 1185), "What the project demonstrates", None, NOTE_FILL, NOTE_BORDER)

    notes = [
        "Self-healing: deleting a Flask Pod makes the Deployment create a replacement.",
        "Autoscaling: above 50% CPU the HPA adds Pods (max 5); when load stops it returns to 2.",
        "Failover: the same image runs in both clusters; only the active endpoint is switched.",
        "Persistence: Redis uses a named volume (Docker) and a PVC (Kubernetes).",
        "Redis is NOT replicated between clusters, so visit counts differ after a failover.",
    ]
    note_font = font(16)
    body_font = font(14)
    y = 840
    for item in notes:
        draw.ellipse((110, y + 7, 119, y + 16), fill=NOTE_BORDER)
        for line in wrap(item, note_font, 870):
            draw.text((132, y), line, font=note_font, fill=INK)
            y += 25
        y += 16

    legend_y = 1075
    draw.text((110, legend_y), "Legend", font=font(17, bold=True), fill=INK)
    legend_y += 32
    draw.line([(110, legend_y + 8), (180, legend_y + 8)], fill=ARROW, width=3)
    arrow(draw, (176, legend_y + 8), (196, legend_y + 8), head=11)
    draw.text((210, legend_y - 2), "request / data path", font=body_font, fill=MUTED)

    legend_y += 32
    arrow(draw, (110, legend_y + 8), (196, legend_y + 8), color=FAILOVER, width=3, dashed=True, head=11)
    draw.text((210, legend_y - 2), "control path (scaling, failover)", font=body_font, fill=MUTED)

    # ---------------- footer ----------------
    draw_center(draw, WIDTH / 2, 1252,
                "Files: app.py · Dockerfile · docker-compose.yml · k8s.yaml · hpa.yaml · "
                "failover/failover.ps1 · load_test.py",
                font(14), MUTED)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUTPUT)
    print(f"Architecture diagram written to {OUTPUT} ({img.width}x{img.height})")


if __name__ == "__main__":
    build()
