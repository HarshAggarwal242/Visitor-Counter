"""
Render reports/project_report.md into reports/project_report.pdf.

No third-party libraries are required: this script contains a small PDF writer
(text, rules, tables) plus a minimal Markdown renderer.

Usage (from the project root):
    python scripts/build_report_pdf.py

Supported Markdown subset: #..#### headings, paragraphs, "- " bullets,
"1. " numbered lists, "|" tables, "```" code blocks, "> " block quotes, "---"
rules. Inline **bold** and `code` are supported in paragraphs.
"""

import re
import zlib
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SOURCE = PROJECT_ROOT / "reports" / "project_report.md"
OUTPUT = PROJECT_ROOT / "reports" / "project_report.pdf"

PAGE_W, PAGE_H = 595.28, 841.89  # A4 in points
MARGIN_L = 62
MARGIN_R = 62
MARGIN_T = 64
MARGIN_B = 58
CONTENT_W = PAGE_W - MARGIN_L - MARGIN_R

INK = (0.06, 0.09, 0.16)
MUTED = (0.35, 0.38, 0.44)
RULE = (0.72, 0.75, 0.80)
ACCENT = (0.10, 0.30, 0.70)
TABLE_HEAD = (0.90, 0.93, 0.98)
CODE_BG = (0.96, 0.97, 0.99)

# ---------------------------------------------------------------------------
# Helvetica / Helvetica-Bold glyph widths (per 1000 units), chars 32..126
# ---------------------------------------------------------------------------
_HELV = (
    [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278]
    + [556] * 10
    + [278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278,
       500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667,
       611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222,
       222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500,
       500, 334, 260, 334, 584]
)

_HELV_BOLD = (
    [278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278]
    + [556] * 10
    + [333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278,
       556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667,
       611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278,
       278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556,
       500, 389, 280, 389, 584]
)

REPLACEMENTS = {
    "\u2192": "->",
    "\u2190": "<-",
    "\u2013": "-",
    "\u2014": "--",
    "\u2018": "'",
    "\u2019": "'",
    "\u201c": '"',
    "\u201d": '"',
    "\u2022": "-",
    "\u2026": "...",
    "\u00a0": " ",
    "\u2264": "<=",
    "\u2265": ">=",
    "\u2248": "~",
    "\u2713": "OK",
}


def sanitise(text):
    for bad, good in REPLACEMENTS.items():
        text = text.replace(bad, good)
    return text


def string_width(text, size, bold=False, mono=False):
    if mono:
        return len(text) * 0.6 * size
    table = _HELV_BOLD if bold else _HELV
    total = 0
    for char in text:
        index = ord(char) - 32
        total += table[index] if 0 <= index < 95 else 556
    return total * size / 1000.0


def escape_pdf(text):
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


# ---------------------------------------------------------------------------
# Document / PDF writer
# ---------------------------------------------------------------------------
class Document:
    def __init__(self):
        self.pages = []
        self.buffer = []
        self.y = MARGIN_T + 12
        self.page_started = False

    # -- low level -------------------------------------------------------
    def _emit(self, command):
        self.buffer.append(command)

    def text(self, x, text, size, bold=False, mono=False, oblique=False, color=INK):
        text = sanitise(text)
        if not text:
            return
        font = "F3" if mono else ("F2" if bold else ("F4" if oblique else "F1"))
        r, g, b = color
        self._emit(
            f"BT /{font} {size:.2f} Tf {r:.3f} {g:.3f} {b:.3f} rg "
            f"1 0 0 1 {x:.2f} {PAGE_H - self.y:.2f} Tm ({escape_pdf(text)}) Tj ET"
        )

    def rule(self, x1, x2, y_offset=0.0, width=0.7, color=RULE):
        r, g, b = color
        self._emit(
            f"{width:.2f} w {r:.3f} {g:.3f} {b:.3f} RG {x1:.2f} {PAGE_H - self.y - y_offset:.2f} m "
            f"{x2:.2f} {PAGE_H - self.y - y_offset:.2f} l S"
        )

    def rect(self, x, y_top, width, height, color):
        r, g, b = color
        self._emit(
            f"{r:.3f} {g:.3f} {b:.3f} rg {x:.2f} {PAGE_H - y_top - height:.2f} "
            f"{width:.2f} {height:.2f} re f"
        )

    def rect_outline(self, x, y_top, width, height, color=RULE, line_width=0.6):
        r, g, b = color
        self._emit(
            f"{line_width:.2f} w {r:.3f} {g:.3f} {b:.3f} RG {x:.2f} {PAGE_H - y_top - height:.2f} "
            f"{width:.2f} {height:.2f} re S"
        )

    # -- page handling ---------------------------------------------------
    def new_page(self):
        if self.buffer:
            self.pages.append("\n".join(self.buffer))
        self.buffer = []
        self.y = MARGIN_T + 12
        self.page_started = True

    def ensure(self, height):
        if self.y + height > PAGE_H - MARGIN_B:
            self.new_page()

    def space(self, amount):
        self.y = min(self.y + amount, PAGE_H - MARGIN_B)

    # -- blocks ----------------------------------------------------------
    def heading(self, text, level):
        sizes = {1: 19, 2: 14.5, 3: 12, 4: 11}
        size = sizes.get(level, 11)
        self.ensure(size * 2.6)
        if level == 1:
            self.space(6)
            self.rule(MARGIN_L, PAGE_W - MARGIN_R, y_offset=size + 6, width=0.6)
        self.space(size * 0.9)
        self.text(MARGIN_L, text, size, bold=True, color=ACCENT if level <= 2 else INK)
        self.space(size * 0.55)

    def paragraph(self, text, size=10.5, indent=0.0, width=None, leading=None,
                  oblique=False, color=INK):
        width = width or (CONTENT_W - indent)
        leading = leading or (size * 1.45)
        tokens = parse_inline(text)
        self._layout_words(tokens, size, MARGIN_L + indent, width, leading,
                           oblique=oblique, color=color)

    def bullet(self, text, marker="-", size=10.5):
        indent = 16
        self.ensure(size * 1.6)
        self.text(MARGIN_L + 4, marker, size, color=MUTED)
        self.paragraph(text, size=size, indent=indent)

    def code_block(self, lines):
        size = 8.4
        leading = size * 1.42
        padding = 8
        height = len(lines) * leading + padding * 2
        self.ensure(min(height, PAGE_H - MARGIN_T - MARGIN_B))
        if self.y + height > PAGE_H - MARGIN_B:
            self.new_page()
        start_y = self.y + 2
        self.rect(MARGIN_L, start_y - padding, CONTENT_W, height, CODE_BG)
        self.rect_outline(MARGIN_L, start_y - padding, CONTENT_W, height, RULE)
        self.y = start_y + size
        for line in lines:
            for chunk in wrap_plain(line, size, CONTENT_W - 2 * padding - 6, mono=True):
                self.ensure(leading)
                self.text(MARGIN_L + padding + 3, chunk, size, mono=True, color=(0.12, 0.14, 0.2))
                self.y += leading
        self.y += padding
        self.space(8)

    def table(self, rows):
        if not rows:
            return

        size = 8.6
        leading = size * 1.35
        padding = 5
        columns = max(len(row) for row in rows)

        normalised = []
        for row in rows:
            cells = [sanitise(str(cell)) for cell in row]
            cells += [""] * (columns - len(cells))
            normalised.append(cells)

        widths = self._column_widths(normalised, columns, size)
        x_positions = []
        running = MARGIN_L
        for width in widths:
            x_positions.append(running)
            running += width

        def draw_row(cells, bold=False, fill=None):
            """Draw one table row. Returns False when it did not fit (page break)."""
            cell_lines = [
                wrap_plain(cells[i], size, widths[i] - 2 * padding, bold=bold) for i in range(columns)
            ]
            line_count = max(len(lines) for lines in cell_lines)
            height = line_count * leading + padding * 2

            if self.y + height > PAGE_H - MARGIN_B:
                self.new_page()
                return False

            top = self.y + 2
            if fill:
                self.rect(MARGIN_L, top, sum(widths), height, fill)
            self.y = top + padding + size
            for line_index in range(line_count):
                for column in range(columns):
                    if line_index < len(cell_lines[column]):
                        self.text(x_positions[column] + padding, cell_lines[column][line_index], size, bold=bold)
                self.y += leading
            self.y = top + height
            self._table_row_borders(x_positions, widths, top, height)
            return True

        if not draw_row(normalised[0], bold=True, fill=TABLE_HEAD):
            draw_row(normalised[0], bold=True, fill=TABLE_HEAD)

        for row in normalised[1:]:
            if not draw_row(row):
                draw_row(normalised[0], bold=True, fill=TABLE_HEAD)  # repeat header
                draw_row(row)

        self.space(10)

    def _table_row_borders(self, x_positions, widths, top, height):
        self.rect_outline(MARGIN_L, top, sum(widths), height)
        for index in range(1, len(widths)):
            x = x_positions[index]
            self._emit(
                f"0.4 w {RULE[0]:.3f} {RULE[1]:.3f} {RULE[2]:.3f} RG "
                f"{x:.2f} {PAGE_H - top:.2f} m {x:.2f} {PAGE_H - top - height:.2f} l S"
            )

    def _column_widths(self, rows, columns, size):
        natural = []
        for index in range(columns):
            widest = 0
            for row in rows:
                if index < len(row):
                    widest = max(widest, string_width(sanitise(str(row[index])), size))
            natural.append(min(max(widest + 12, 46), CONTENT_W * 0.5))
        total = sum(natural)
        if total <= CONTENT_W:
            # distribute the leftover space proportionally
            extra = CONTENT_W - total
            return [width + extra / columns for width in natural]
        factor = CONTENT_W / total
        return [width * factor for width in natural]

    def _layout_words(self, tokens, size, x_start, width, leading, oblique=False, color=INK):
        space_width = string_width(" ", size)
        line = []  # (word, bold, mono)
        line_width = 0.0

        def flush():
            nonlocal line, line_width
            if not line:
                return
            self.ensure(leading)
            x = x_start
            for word, bold, mono in line:
                self.text(x, word, size, bold=bold, mono=mono, oblique=oblique, color=color)
                x += string_width(word, size, bold=bold, mono=mono) + space_width
            self.y += leading
            line = []
            line_width = 0.0

        for token in tokens:
            for word in token["text"].split(" "):
                if word == "":
                    continue
                word_width = string_width(word, size, bold=token["bold"], mono=token["mono"])
                needed = word_width + (space_width if line else 0)
                if line and line_width + needed > width:
                    flush()
                line.append((word, token["bold"], token["mono"]))
                line_width += needed if len(line) > 1 else word_width
        flush()

    # -- output ----------------------------------------------------------
    def build(self, metadata):
        if self.buffer:
            self.pages.append("\n".join(self.buffer))

        total_pages = len(self.pages)
        final_pages = []
        for index, content in enumerate(self.pages, start=1):
            footer = (
                f"BT /F1 8 Tf {MUTED[0]:.3f} {MUTED[1]:.3f} {MUTED[2]:.3f} rg "
                f"1 0 0 1 {PAGE_W / 2 - 24:.2f} 26 Tm (Page {index} of {total_pages}) Tj ET"
            )
            final_pages.append(content + "\n" + footer)

        count = len(final_pages)
        objects = {}

        first_page_obj = 8
        page_numbers = [first_page_obj + 2 * i for i in range(count)]
        content_numbers = [first_page_obj + 2 * i + 1 for i in range(count)]

        objects[1] = f"<< /Type /Catalog /Pages 2 0 R >>"
        kids = " ".join(f"{num} 0 R" for num in page_numbers)
        objects[2] = f"<< /Type /Pages /Kids [{kids}] /Count {count} >>"
        objects[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
        objects[4] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"
        objects[5] = "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"
        objects[6] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >>"

        info = (
            "<< /Title ({}) /Author ({}) /Subject ({}) /Creator (build_report_pdf.py) /Producer (Python) >>"
        ).format(
            escape_pdf(sanitise(metadata["title"])),
            escape_pdf(sanitise(metadata.get("author", ""))),
            escape_pdf(sanitise(metadata.get("subject", ""))),
        )
        objects[7] = info

        for index, content in enumerate(final_pages):
            page_num = page_numbers[index]
            content_num = content_numbers[index]
            objects[page_num] = (
                f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W:.2f} {PAGE_H:.2f}] "
                f"/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R >> >> "
                f"/Contents {content_num} 0 R >>"
            )
            compressed = zlib.compress(content.encode("cp1252", errors="replace"))
            objects[content_num] = (
                b"<< /Length " + str(len(compressed)).encode() + b" /Filter /FlateDecode >>\nstream\n"
                + compressed + b"\nendstream"
            )

        out = bytearray()
        out += b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
        offsets = {}
        for number in sorted(objects):
            body = objects[number]
            if isinstance(body, str):
                body = body.encode("cp1252", errors="replace")
            offsets[number] = len(out)
            out += f"{number} 0 obj\n".encode()
            out += body
            out += b"\nendobj\n"

        max_number = max(objects)
        xref_offset = len(out)
        out += f"xref\n0 {max_number + 1}\n".encode()
        out += b"0000000000 65535 f \n"
        for number in range(1, max_number + 1):
            offset = offsets.get(number, 0)
            out += f"{offset:010d} 00000 n \n".encode()
        out += (
            f"trailer\n<< /Size {max_number + 1} /Root 1 0 R /Info 7 0 R >>\n"
            f"startxref\n{xref_offset}\n%%EOF\n"
        ).encode()

        return bytes(out), count


# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------
def parse_inline(text):
    """Split markdown text into tokens carrying bold/mono flags."""
    tokens = []
    pattern = re.compile(r"(\*\*[^*]+\*\*|`[^`]+`)")
    for part in pattern.split(text):
        if not part:
            continue
        if part.startswith("**") and part.endswith("**"):
            tokens.append({"text": part[2:-2], "bold": True, "mono": False})
        elif part.startswith("`") and part.endswith("`"):
            tokens.append({"text": part[1:-1], "bold": False, "mono": True})
        else:
            tokens.append({"text": part, "bold": False, "mono": False})
    return tokens


def strip_markdown(text):
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    return sanitise(text)


def wrap_plain(text, size, width, bold=False, mono=False):
    """Word-wrap a plain string for a fixed width."""
    if not text.strip():
        return [""]
    words = text.split()
    lines, current = [], ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if string_width(candidate, size, bold=bold, mono=mono) <= width or not current:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


BLOCK_START = re.compile(r"^(#{1,4}\s|\s*[-*]\s|\s*\d+\.\s|>|\||```|---)")


def is_block_start(line):
    return bool(BLOCK_START.match(line.strip())) or line.strip() == "---"


def render_body(lines, doc):
    index = 0
    total = len(lines)

    while index < total:
        raw = lines[index]
        line = raw.rstrip()
        stripped = line.strip()

        if not stripped:
            doc.space(5)
            index += 1
            continue

        if stripped == "---":
            doc.space(4)
            doc.rule(MARGIN_L, PAGE_W - MARGIN_R)
            doc.space(10)
            index += 1
            continue

        if stripped.startswith("```"):
            index += 1
            code = []
            while index < total and not lines[index].strip().startswith("```"):
                code.append(lines[index].rstrip())
                index += 1
            index += 1
            doc.code_block(code)
            continue

        heading = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if heading:
            level = len(heading.group(1))
            text = strip_markdown(heading.group(2))
            if level == 1:
                doc.ensure(70)
            doc.heading(text, level)
            index += 1
            continue

        if stripped.startswith(">"):
            quote = []
            while index < total and lines[index].strip().startswith(">"):
                quote.append(lines[index].strip()[1:].strip())
                index += 1
            doc.space(4)
            for entry in quote:
                if not entry:
                    doc.space(4)
                else:
                    doc.paragraph(entry, size=9.8, indent=10, oblique=True, color=MUTED)
            doc.space(6)
            continue

        if stripped.startswith("|"):
            rows = []
            while index < total and lines[index].strip().startswith("|"):
                row = lines[index].strip()
                cells = [cell.strip() for cell in row.strip("|").split("|")]
                if not all(re.fullmatch(r":?-{2,}:?", cell) for cell in cells):
                    rows.append(cells)
                index += 1
            doc.table(rows)
            continue

        bullet = re.match(r"^[-*]\s+(.*)$", stripped)
        if bullet:
            doc.bullet(strip_markdown(bullet.group(1)), marker="-")
            index += 1
            continue

        numbered = re.match(r"^(\d+)\.\s+(.*)$", stripped)
        if numbered:
            indent = 20
            doc.ensure(15)
            doc.text(MARGIN_L + 2, f"{numbered.group(1)}.", 10.5, color=MUTED)
            doc.paragraph(numbered.group(2), size=10.5, indent=indent)
            index += 1
            continue

        # paragraph: gather following plain lines
        paragraph = [stripped]
        index += 1
        while index < total:
            nxt = lines[index]
            if not nxt.strip() or is_block_start(nxt):
                break
            paragraph.append(nxt.strip())
            index += 1
        doc.paragraph(" ".join(paragraph))


def render_cover(doc, title, subtitle, cover_lines):
    doc.new_page()
    doc.y = 150

    for line in wrap_plain(sanitise(title), 24, CONTENT_W, bold=True):
        doc.text((PAGE_W - string_width(line, 24, bold=True)) / 2, line, 24, bold=True, color=ACCENT)
        doc.y += 32
    doc.y += 6
    doc.rule(MARGIN_L, PAGE_W - MARGIN_R, width=1.0, color=ACCENT)
    doc.y += 22

    if subtitle:
        for line in wrap_plain(sanitise(subtitle), 13, CONTENT_W, bold=True):
            doc.text((PAGE_W - string_width(line, 13, bold=True)) / 2, line, 13, bold=True, color=MUTED)
            doc.y += 18
    doc.y += 40

    for entry in cover_lines:
        text = entry.strip()
        if not text:
            doc.y += 10
            continue
        bold = text.startswith("**")
        plain = strip_markdown(text)
        size = 11 if bold else 10.5
        for line_text in wrap_plain(plain, size, CONTENT_W, bold=bold):
            doc.text((PAGE_W - string_width(line_text, size, bold=bold)) / 2, line_text, size,
                     bold=bold, color=INK if bold else MUTED)
            doc.y += size * 1.6

    doc.new_page()


def main():
    if not SOURCE.exists():
        raise SystemExit(f"Missing source file: {SOURCE}")

    markdown = SOURCE.read_text(encoding="utf-8")
    lines = markdown.splitlines()

    title = "Cloud Computing Project Report"
    subtitle = ""
    start = 0
    for index, line in enumerate(lines):
        if line.startswith("# "):
            title = line[2:].strip()
            start = index + 1
            break
    for index in range(start, min(start + 4, len(lines))):
        if lines[index].startswith("## "):
            subtitle = lines[index][3:].strip()
            start = index + 1
            break

    # cover metadata = everything up to the first horizontal rule
    cover_end = start
    for index in range(start, len(lines)):
        if lines[index].strip() == "---":
            cover_end = index
            break
        cover_end = index + 1
    cover_lines = [line for line in lines[start:cover_end] if line.strip()]
    body = lines[cover_end + 1:] if cover_end < len(lines) else []

    doc = Document()
    render_cover(doc, title, subtitle, cover_lines)
    render_body(body, doc)

    pdf_bytes, page_count = doc.build(
        {"title": title, "author": "B.Tech Cloud Computing Project", "subject": subtitle}
    )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(pdf_bytes)
    print(f"Report written to {OUTPUT} ({page_count} pages, {len(pdf_bytes) / 1024:.1f} KiB)")


if __name__ == "__main__":
    main()
