#!/usr/bin/env python3
"""
generate-playbook.py
Config-driven playbook generator. Reads playbook.json and Markdown source files,
outputs a self-contained HTML user guide.

Usage:
    python generate-playbook.py --config playbook.json
"""

import os, re, html as htmllib, json, sys
from pathlib import Path

HERE     = Path(__file__).parent.resolve()
PLAYBOOK = HERE

# Defaults -- overridden by playbook.json
TITLE    = "User Guide"
SUBTITLE = ""
VERSION  = "1.0.0"
DATE     = ""
OUT      = HERE.parent / "USER-GUIDE.html"
COLORS   = {}
SIDEBAR_LABEL = "User Guide"
META_ITEMS = {}
SECTIONS_CONFIG = []

# ---------------------------------------------------------------------------
# Markdown → HTML helpers (stdlib only)
# ---------------------------------------------------------------------------

def esc(s):
    return htmllib.escape(str(s), quote=False)

# Stash table for inline code protection
_CODE_STASH = []

def _stash(m):
    _CODE_STASH.append(m.group(1))
    return f"\x00C{len(_CODE_STASH)-1}\x00"

def _restore(s):
    return re.sub(r"\x00C(\d+)\x00", lambda m: f"<code>{esc(_CODE_STASH[int(m.group(1))])}</code>", s)

def inline_md(text):
    """Convert inline Markdown (bold, italic, code, links) to HTML."""
    _CODE_STASH.clear()
    text = re.sub(r"`([^`]+)`", _stash, text)
    text = esc(text)
    # bold
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    # italic (not preceded/followed by *)
    text = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<em>\1</em>", text)
    # markdown links  [label](target)
    def _link(m):
        label, target = m.group(1), m.group(2).strip()
        # internal cross-references to playbook files → stripped
        if target.endswith('.md') or '.md#' in target:
            return label  # keep label, drop link (in-page navigation done by sidebar)
        return f'<a href="{esc(target)}">{label}</a>'
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", _link, text)
    text = _restore(text)
    return text

def split_row(line):
    line = line.strip().strip("|")
    return [c.strip() for c in line.split("|")]

def is_sep_row(line):
    # A GitHub-flavoured-Markdown table separator: every cell is dashes with
    # optional leading/trailing colon for alignment (e.g. ---, :--, :-:, --:).
    # Checked per-cell rather than with one regex over the whole line, because a
    # single char-class like [...|-|...] silently reads the '-' as a range and
    # drops the literal hyphen, which is what previously let separator rows leak
    # through and render as a spurious "---" data row in every table.
    cells = split_row(line)
    return bool(cells) and all(re.fullmatch(r":?-+:?", c) for c in cells)

def render_table(raw_rows):
    """raw_rows: list of raw table lines (may include sep row)."""
    rows = [split_row(r) for r in raw_rows if not is_sep_row(r)]
    if not rows:
        return ""
    out = ["<table>", "<thead><tr>"]
    for c in rows[0]:
        out.append(f"<th>{inline_md(c)}</th>")
    out.append("</tr></thead><tbody>")
    for r in rows[1:]:
        out.append("<tr>")
        for c in r:
            out.append(f"<td>{inline_md(c)}</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)

def classify_callout(lines):
    """Return (css_class, label) for a blockquote."""
    text = " ".join(lines).lower()
    # Danger
    if any(x in text for x in ["danger", "critical", "security", "must not", "never commit"]):
        return "callout-danger", "Security"
    # Warning
    if any(x in text for x in ["warning", "caution", "important", "never"]):
        return "callout-warning", "Important"
    # Success / Tip
    if any(x in text for x in ["tip", "best practice", "recommended", "proven"]):
        return "callout-success", "Tip"
    # Info / Note
    if any(x in text for x in ["note", "info", "see also", "default"]):
        return "callout-info", "Note"
    return "callout-info", "Note"

def md_to_html(lines):
    """Convert a list of Markdown lines to an HTML string."""
    out = []
    i = 0
    N = len(lines)

    while i < N:
        raw = lines[i]
        s   = raw.strip()

        # ── fenced code block ─────────────────────────────────────────────
        if re.match(r"^```", s):
            i += 1
            code = []
            while i < N and not re.match(r"^```", lines[i].strip()):
                code.append(lines[i])
                i += 1
            i += 1   # skip closing ```
            out.append(f"<pre><code>{esc(chr(10).join(code))}</code></pre>")
            continue

        # ── blank / hr ─────────────────────────────────────────────────────
        if s == "":
            i += 1
            continue
        if re.match(r"^---+\s*$", s):
            i += 1
            continue

        # ── heading ────────────────────────────────────────────────────────
        hm = re.match(r"^(#{1,6})\s+(.+)", s)
        if hm:
            depth = len(hm.group(1))
            txt   = hm.group(2).strip()
            # H1 inside body → h2; H2 → h2; H3 → h3; H4/5 → h4
            tag   = {1:"h2", 2:"h2", 3:"h3", 4:"h4", 5:"h4", 6:"h4"}[depth]
            hid   = re.sub(r"[^a-z0-9]+", "-", txt.lower()).strip("-")
            out.append(f'<{tag} id="{hid}">{inline_md(txt)}</{tag}>')
            i += 1
            continue

        # ── blockquote ─────────────────────────────────────────────────────
        if s.startswith(">"):
            bq = []
            while i < N and lines[i].strip().startswith(">"):
                bq.append(re.sub(r"^>\s?", "", lines[i].strip()))
                i += 1
            css, label = classify_callout(bq)
            inner = md_to_html(bq)
            out.append(f'<div class="callout {css}"><div class="callout-label">{label}</div>{inner}</div>')
            continue

        # ── table ──────────────────────────────────────────────────────────
        if "|" in s:
            tbl = []
            while i < N and "|" in lines[i] and lines[i].strip():
                tbl.append(lines[i])
                i += 1
            out.append(render_table(tbl))
            continue

        # ── unordered list ─────────────────────────────────────────────────
        if re.match(r"^[-*+]\s+", s):
            items = []
            while i < N:
                lm = re.match(r"^[-*+]\s+(.*)", lines[i].strip())
                if lm:
                    items.append(lm.group(1))
                    i += 1
                elif lines[i].strip() == "" and i+1 < N and re.match(r"^[-*+]\s+", lines[i+1].strip()):
                    i += 1  # blank between items
                elif re.match(r"^\s{2,}", lines[i]) and items:
                    items[-1] += " " + lines[i].strip()
                    i += 1
                else:
                    break
            out.append("<ul>" + "".join(f"<li>{inline_md(it)}</li>" for it in items) + "</ul>")
            continue

        # ── ordered list ───────────────────────────────────────────────────
        if re.match(r"^\d+\.\s+", s):
            items = []
            while i < N:
                lm = re.match(r"^\d+\.\s+(.*)", lines[i].strip())
                if lm:
                    items.append(lm.group(1))
                    i += 1
                elif lines[i].strip() == "" and i+1 < N and re.match(r"^\d+\.\s+", lines[i+1].strip()):
                    i += 1
                elif re.match(r"^\s{2,}", lines[i]) and items:
                    items[-1] += " " + lines[i].strip()
                    i += 1
                else:
                    break
            out.append("<ol>" + "".join(f"<li>{inline_md(it)}</li>" for it in items) + "</ol>")
            continue

        # ── paragraph ──────────────────────────────────────────────────────
        para = []
        while i < N:
            l = lines[i]
            ls = l.strip()
            if (ls == ""
                    or re.match(r"^#{1,6}\s", ls)
                    or ls.startswith(">")
                    or re.match(r"^```", ls)
                    or re.match(r"^[-*+]\s+", ls)
                    or re.match(r"^\d+\.\s+", ls)
                    or re.match(r"^---+\s*$", ls)
                    or ("|" in ls)):
                break
            para.append(ls)
            i += 1
        if para:
            out.append(f"<p>{inline_md(' '.join(para))}</p>")
        else:
            i += 1  # safety advance

    return "\n".join(out)

# ---------------------------------------------------------------------------
# Parse the three Markdown files into nav groups
# ---------------------------------------------------------------------------

def read_md(fname):
    return (PLAYBOOK / fname).read_text(encoding="utf-8").splitlines()

def split_h2(lines):
    """Split lines into [(h2_title, body_lines), ...]; text before first H2 is ('', [...])."""
    segs = []
    cur_title = ""
    cur_body  = []
    for line in lines:
        m = re.match(r"^##\s+(.+)", line)
        if m:
            segs.append((cur_title, cur_body))
            cur_title = m.group(1).strip()
            cur_body  = []
        else:
            cur_body.append(line)
    segs.append((cur_title, cur_body))
    return segs

def make_sid(prefix, title):
    clean = re.sub(r"^\d+\.\s*", "", title)
    clean = re.sub(r"[^a-z0-9]+", "-", clean.lower()).strip("-")
    return f"{prefix}-{clean}" if clean else prefix

def parse_generic_md(filename, group_name):
    """Parse any Markdown file into sections. Each ## heading becomes a navigable tab."""
    lines = read_md(filename)
    segs  = split_h2(lines)
    secs  = []
    prefix = re.sub(r'[^a-z0-9]+', '-', group_name.lower()).strip('-')
    intro_body = []
    for raw_title, body in segs:
        if not raw_title:
            intro_body = list(body)
            continue
        tl = raw_title.strip().lower()
        if tl in ("contents", "table of contents"):
            intro_body += ["", f"### {raw_title}"] + body
            continue
        sid = make_sid(prefix, raw_title)
        nav = raw_title
        h2  = inline_md(raw_title)
        secs.append({"id": sid, "nav": nav, "h2": h2, "body": body, "group": group_name})
    if intro_body and any(l.strip() for l in intro_body):
        secs.insert(0, {"id": f"{prefix}-overview", "nav": "Overview",
                        "h2": f"{esc(group_name)} &mdash; Overview",
                        "body": intro_body, "group": group_name})
    return secs

# ---------------------------------------------------------------------------
# Build sidebar + mobile nav HTML
# ---------------------------------------------------------------------------

def nav_link(sid, label, num):
    lbl = esc(label)
    return (f'<a href="javascript:void(0)" onclick="showSection(\'{sid}\'); return false;">'
            f'<span class="sidebar-num">{num}</span><span>{lbl}</span></a>\n')

def mobile_link(sid, label):
    lbl = esc(label[:22])
    return f'<a href="javascript:void(0)" onclick="showSection(\'{sid}\'); return false;">{lbl}</a>\n'

def build_sidebar(all_secs):
    parts   = []
    mobile  = []
    counter = 0
    cur_grp = None

    for sec in all_secs:
        grp = sec["group"]
        if grp != cur_grp:
            parts.append(f'<div class="sidebar-group-label">{esc(grp)}</div>\n')
            cur_grp = grp
        counter += 1
        sid = sec["id"]
        parts.append(nav_link(sid, sec["nav"], counter))
        mobile.append(mobile_link(sid, sec["nav"]))

    return "".join(parts), "".join(mobile)

# ---------------------------------------------------------------------------
# Render section HTML
# ---------------------------------------------------------------------------

def render_section(sec):
    inner = md_to_html(sec["body"])
    return (f'<div id="section-{sec["id"]}" class="report-section" style="display:none">\n'
            f'<h2>{sec["h2"]}</h2>\n'
            f'{inner}\n'
            f'</div>\n')

# ---------------------------------------------------------------------------
# Read framework CSS
# ---------------------------------------------------------------------------

def read_css():
    css = (PLAYBOOK / "_framework.css").read_text(encoding="utf-8")
    # The file wraps everything in <style>…</style>; strip those tags for inline embed.
    css = re.sub(r"^\s*<style[^>]*>", "", css, flags=re.I)
    css = re.sub(r"</style>\s*$", "", css, flags=re.I)
    return css.strip()

EXTRA_CSS = """
/* ─── SIDEBAR GROUP LABELS ─────────────────────────────────────── */
.sidebar-group-label {
    font-size: 0.59rem;
    font-weight: 800;
    letter-spacing: 0.15em;
    text-transform: uppercase;
    color: rgba(91,155,213,0.75);
    padding: 14px 16px 5px;
    border-top: 1px solid rgba(255,255,255,0.07);
    margin-top: 6px;
}
.sidebar-group-label:first-of-type { border-top: none; margin-top: 0; }

/* Sub-tab links within SDK Features */
.sidebar-sub {
    padding-left: 28px !important;
    font-size: 0.74rem !important;
    color: #5a6478 !important;
    border-left-color: transparent !important;
}
.sidebar-sub:hover { color: #9aaac0 !important; }
.sidebar-sub.active { color: var(--accent) !important; border-left-color: var(--accent) !important; }

/* Dark code blocks (override framework's light code-bg) */
.report-section pre {
    background: #1e2738 !important;
    border-color: #2d3a50 !important;
}
.report-section pre code {
    color: #c9d7f0 !important;
    background: none !important;
    border: none !important;
    padding: 0 !important;
}

/* Wider sidebar to fit grouped labels */
:root { --sidebar-w: 238px; }

/* Section max reading width */
.report-section { max-width: 820px; }
"""

# ---------------------------------------------------------------------------
# Assemble and write the final HTML
# ---------------------------------------------------------------------------

def load_config(config_path):
    """Load playbook.json and set global configuration."""
    global TITLE, SUBTITLE, VERSION, DATE, OUT, COLORS, SIDEBAR_LABEL, META_ITEMS, SECTIONS_CONFIG, PLAYBOOK
    config_file = Path(config_path).resolve()
    PLAYBOOK = config_file.parent

    with open(config_file, encoding="utf-8") as f:
        cfg = json.load(f)

    TITLE = cfg.get("title", TITLE)
    SUBTITLE = cfg.get("subtitle", SUBTITLE)
    VERSION = cfg.get("version", VERSION)
    DATE = cfg.get("meta", {}).get("Generated", "")
    COLORS = cfg.get("colors", {})
    SIDEBAR_LABEL = cfg.get("sidebar_label", "User Guide")
    META_ITEMS = cfg.get("meta", {})
    SECTIONS_CONFIG = cfg.get("sections", [])

    out_rel = cfg.get("output", "../USER-GUIDE.html")
    OUT = (PLAYBOOK / out_rel).resolve()

    theme_rel = cfg.get("theme", "_framework.css")
    # theme path handled by read_css()

def build():
    all_secs = []
    for sec_cfg in SECTIONS_CONFIG:
        fname = sec_cfg["file"]
        group = sec_cfg["group"]
        secs = parse_generic_md(fname, group)
        all_secs.extend(secs)

    if not all_secs:
        print("ERROR: No sections parsed. Check playbook.json and source files.")
        sys.exit(1)

    sidebar_html, mobile_html = build_sidebar(all_secs)
    sections_html = "".join(render_section(s) for s in all_secs)

    all_ids   = [s["id"] for s in all_secs]
    ids_json  = "[" + ", ".join(f'"{i}"' for i in all_ids) + "]"

    fw_css = read_css()

    # Apply color overrides
    color_overrides = ""
    if COLORS:
        color_overrides = ":root {\n"
        color_map = {"primary": "--primary", "sidebar": "--sidebar-bg",
                     "header": "--header-bg", "accent": "--accent"}
        for key, var in color_map.items():
            if key in COLORS:
                color_overrides += f"  {var}: {COLORS[key]};\n"
        color_overrides += "}\n"

    # Build meta items HTML
    meta_html = ""
    for key, val in META_ITEMS.items():
        meta_html += f'<div class="meta-item"><strong>{esc(key)}</strong>{esc(val)}</div>\n'
    if VERSION:
        meta_html = f'<div class="meta-item"><strong>Version</strong>{esc(VERSION)}</div>\n' + meta_html

    JS = f"""
var sections = {ids_json};
function showSection(id) {{
    sections.forEach(function(s) {{
        var el = document.getElementById('section-' + s);
        if (el) el.style.display = 'none';
    }});
    var target = document.getElementById('section-' + id);
    if (target) target.style.display = 'block';
    document.querySelectorAll('#sidebar a, #mobile-nav a').forEach(function(a) {{
        a.classList.remove('active');
    }});
    document.querySelectorAll('#sidebar a[onclick], #mobile-nav a[onclick]').forEach(function(a) {{
        if (a.getAttribute('onclick') && a.getAttribute('onclick').indexOf("'" + id + "'") !== -1) {{
            a.classList.add('active');
        }}
    }});
    if (history.replaceState) history.replaceState(null, '', '#' + id);
    window.scrollTo(0, 0);
}}
window.showSection = showSection;
document.addEventListener('DOMContentLoaded', function() {{
    var hash = location.hash.replace('#', '');
    showSection(hash && sections.indexOf(hash) !== -1 ? hash : sections[0]);
}});
"""

    doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{esc(TITLE)}</title>
<style>
{fw_css}
{EXTRA_CSS}
{color_overrides}
</style>
</head>
<body>

<div id="top-band">
  <div id="report-header">
    <div class="title-block">
      <div class="report-title">{esc(TITLE)}</div>
      <div class="report-sub">{esc(SUBTITLE)}</div>
    </div>
    <div class="meta-items">
{meta_html}
    </div>
  </div>
  <div id="mobile-nav">
{mobile_html}
  </div>
</div>

<div id="app-layout">
  <div id="sidebar">
    <div id="sidebar-inner">
{sidebar_html}
    </div>
  </div>
  <div id="content-area">
{sections_html}
  </div>
</div>

<script>
{JS}
</script>
</body>
</html>
"""

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(doc, encoding="utf-8")
    kb = OUT.stat().st_size // 1024
    group_counts = {}
    for s in all_secs:
        group_counts[s["group"]] = group_counts.get(s["group"], 0) + 1
    groups_str = ", ".join(f"{g}: {c}" for g, c in group_counts.items())
    print(f"Wrote: {OUT}")
    print(f"Size:  {kb} KB")
    print(f"Sections: {len(all_secs)} ({groups_str})")

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Generate playbook HTML from Markdown sources")
    parser.add_argument("--config", required=True, help="Path to playbook.json config file")
    args = parser.parse_args()
    load_config(args.config)
    build()
