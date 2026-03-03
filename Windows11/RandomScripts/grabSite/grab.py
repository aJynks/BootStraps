import sys
import os
import re
import trafilatura
from urllib.request import urlopen

WIDTH = 88

def usage():
    print('Usage: py grab.py [-d output_dir] <url>  (the -d option can be before or after the url)')
    sys.exit(1)

args = sys.argv[1:]

out_dir = None
url = None

# Order-independent parsing:
#   grab.py URL
#   grab.py -d DIR URL
#   grab.py URL -d DIR
i = 0
while i < len(args):
    if args[i] == "-d":
        if i + 1 >= len(args):
            usage()
        out_dir = args[i + 1]
        i += 2
    else:
        if url is None:
            url = args[i]
        i += 1

if not url:
    usage()

html = urlopen(url).read().decode("utf-8", errors="replace")

md = trafilatura.extract(
    html,
    output_format="markdown",
    include_tables=True,
    include_comments=False,
)

if not md:
    print("Extraction failed (empty content).")
    sys.exit(1)

def md_to_pretty_text(md: str, width: int = WIDTH) -> str:
    import textwrap  # (still used for list wrapping only; tables/code never wrap)

    md = md.replace("¶", "").replace("\r\n", "\n")

    # --------- Markdown table helpers ----------
    def is_table_line(s: str) -> bool:
        s = s.strip()
        return s.startswith("|") and "|" in s[1:]

    def is_separator_line(s: str) -> bool:
        s = s.strip()
        if not is_table_line(s):
            return False
        parts = [p.strip() for p in s.strip("|").split("|")]
        return all(re.fullmatch(r":?-{3,}:?", p) for p in parts)

    def split_row(s: str):
        return [p.strip() for p in s.strip().strip("|").split("|")]

    def render_table(rows):
        """
        NO truncation, NO wrapping.
        Columns expand to the longest cell content.
        """
        if not rows:
            return ""

        ncols = max(len(r) for r in rows)
        rows = [r + [""] * (ncols - len(r)) for r in rows]

        # Normalize whitespace inside cells (but keep ALL text)
        norm_rows = []
        for r in rows:
            norm_rows.append([re.sub(r"\s+", " ", (c or "")).strip() for c in r])
        rows = norm_rows

        # Column widths = longest cell in that column
        colw = [0] * ncols
        for r in rows:
            for i, cell in enumerate(r):
                colw[i] = max(colw[i], len(cell))

        def border(ch="-"):
            return "+" + "+".join(ch * (w + 2) for w in colw) + "+"

        lines = [border("-")]
        for ridx, r in enumerate(rows):
            cells = [r[i].ljust(colw[i]) for i in range(ncols)]
            lines.append("| " + " | ".join(cells) + " |")
            lines.append(border("=" if ridx == 0 else "-"))
        return "\n".join(lines)

    # --------- Code boxing (NO truncation, NO wrapping) ----------
    def detect_lang(fence_line: str) -> str:
        m = re.match(r"^```+\s*([A-Za-z0-9_+-]+)?", fence_line.strip())
        return (m.group(1) or "").strip().lower() if m else ""

    def box_code(code_lines, lang: str = ""):
        # Trim blank lines at start/end
        while code_lines and not code_lines[0].strip():
            code_lines = code_lines[1:]
        while code_lines and not code_lines[-1].strip():
            code_lines = code_lines[:-1]
        if not code_lines:
            code_lines = [""]

        label = (lang.upper() if lang else "")
        max_len = max(len(l) for l in code_lines)  # infinite width behavior

        inner_width = max_len + 2  # spaces padding inside box

        # Top line with optional label (still no truncation)
        if label:
            label_txt = f" {label} "
            # Put label after ┌ and then fill the rest with ─
            top = "┌" + label_txt + ("─" * max(0, inner_width - len(label_txt))) + "┐"
        else:
            top = "┌" + ("─" * inner_width) + "┐"

        bot = "└" + ("─" * inner_width) + "┘"

        out = [top]
        for l in code_lines:
            out.append("│ " + l.ljust(max_len) + " │")
        out.append(bot)
        return out

    # --------- Main parse loop ----------
    out = []
    lines = md.split("\n")
    i = 0

    in_code = False
    code_buffer = []
    code_lang = ""

    while i < len(lines):
        line = lines[i].rstrip()

        # CODE FENCES -> boxed
        if line.startswith("```"):
            if not in_code:
                in_code = True
                code_buffer = []
                code_lang = detect_lang(line)
            else:
                in_code = False
                out.append("")
                out.extend(box_code([l.rstrip("\n") for l in code_buffer], code_lang))
                out.append("")
            i += 1
            continue

        if in_code:
            code_buffer.append(line)
            i += 1
            continue

        # TABLE BLOCK (with repair for mangled rows)
        if is_table_line(line) or ("##" in line and "|" in line and line.count("|") >= 2):
            table_lines = []

            while i < len(lines):
                s = lines[i].rstrip()

                if is_table_line(s) or is_separator_line(s) or ("##" in s and "|" in s and s.count("|") >= 2):
                    table_lines.append(s)
                    i += 1
                    continue

                # Repair pattern: split across 2 lines
                if i + 1 < len(lines):
                    a = lines[i].rstrip()
                    b = lines[i + 1].rstrip()
                    if ("##" in a and "|" in a and a.count("|") <= 2) and ("|" in b and b.count("|") >= 2):
                        table_lines.append(a + " " + b)
                        i += 2
                        continue

                break

            repaired = []
            for tl in table_lines:
                s = tl.strip()

                if is_separator_line(s):
                    repaired.append(s)
                    continue

                if is_table_line(s):
                    repaired.append(s)
                    continue

                # Repair: "name()## name() | desc | ret | ||"
                msum = re.match(r"^(.*?)##\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*\|\|?\s*$", s)
                if msum:
                    fn = msum.group(2).strip() or msum.group(1).strip()
                    desc = msum.group(3).strip()
                    ret = msum.group(4).strip()
                    repaired.append(f"| {fn} | {ret} | {desc} |")
                    continue

                if "|" in s:
                    repaired.append("| " + s.strip().strip("|") + " |")
                    continue

            rows = []
            for tl in repaired:
                if is_separator_line(tl):
                    continue
                if is_table_line(tl):
                    rows.append(split_row(tl))

            if rows:
                out.append("")
                out.append(render_table(rows))
                out.append("")
            continue

        # HEADINGS
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            title = m.group(2).strip()
            if title:
                out.append("")
                out.append(title.upper() if level <= 2 else title)
                underline_char = "=" if level == 1 else "-"
                if level <= 3:
                    out.append(underline_char * len(title))
                out.append("")
            i += 1
            continue

        # LISTS (these still wrap to be readable; tables/code do not)
        lm = re.match(r"^(\s*)([-*+]|\d+\.)\s+(.*)$", line)
        if lm:
            indent = len(lm.group(1))
            bullet = lm.group(2)
            body = lm.group(3).strip()
            prefix = " " * indent + ("• " if bullet in "-*+" else f"{bullet} ")
            wrap_w = max(20, width - len(prefix))
            out.append(textwrap.fill(
                body,
                width=wrap_w,
                initial_indent=prefix,
                subsequent_indent=" " * len(prefix),
            ))
            i += 1
            continue

        # BLANK
        if not line.strip():
            out.append("")
            i += 1
            continue

        out.append(line)
        i += 1

    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"
    return text





text = md_to_pretty_text(md, width=WIDTH)

# Filename from URL
name = url.rstrip("/").split("/")[-1] or "page"
filename = f"{name}.txt"

if out_dir:
    os.makedirs(out_dir, exist_ok=True)
    filepath = os.path.join(out_dir, filename)
else:
    filepath = filename

with open(filepath, "w", encoding="utf-8") as f:
    f.write(text)

print(f"Saved: {filepath}")
