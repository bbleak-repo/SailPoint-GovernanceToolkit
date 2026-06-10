#!/usr/bin/env python3
"""
build-userguide.py
Generates docs/USER-GUIDE.html for the SailPoint ISC Governance Toolkit.

Inputs (source of truth):
    docs/playbook/00-foundations.md
    docs/playbook/cli-playbook.md
    docs/playbook/gui-playbook.md
    docs/playbook/_framework.css

Output:
    docs/USER-GUIDE.html  (single self-contained file, no external deps)

Usage:
    python docs/playbook/build-userguide.py
"""

import os, re, html as htmllib
from pathlib import Path

HERE    = Path(__file__).parent.resolve()
REPO    = HERE.parent.parent
PLAYBOOK = HERE
OUT     = REPO / "docs" / "USER-GUIDE.html"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
TITLE    = "SailPoint ISC Governance Toolkit — User Guide"
SUBTITLE = "Comprehensive reference: Foundations · CLI Playbook · GUI Playbook · Delta Certification"
VERSION  = "1.0.0"
DATE     = "2026-06-05"

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
    if any(x in text for x in ["⚠", "never commit", "safety", "passphrase", "scope note",
                                "scope:", "requires `retention", "wpf requires sta",
                                "windows only", "phase-2", "phase 2"]):
        return "callout-warning", "Important"
    if "source of truth" in text:
        return "callout-info", "Source of Truth"
    if any(x in text for x in ["tls:", "tls 1.2", "store the passphrase"]):
        return "callout-warning", "TLS / Security"
    if any(x in text for x in ["never commit", "security"]):
        return "callout-danger", "Security"
    if any(x in text for x in ["tip", "recommendation", "note"]):
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

def parse_foundations():
    lines = read_md("00-foundations.md")
    segs  = split_h2(lines)
    secs  = []
    for raw_title, body in segs:
        if not raw_title and not any(l.strip() for l in body):
            continue
        if not raw_title:
            sid   = "found-overview"
            nav   = "Overview"
            h2    = "Overview &amp; Audience"
        else:
            sid   = make_sid("found", raw_title)
            nav   = raw_title
            h2    = inline_md(raw_title)
        secs.append({"id": sid, "nav": nav, "h2": h2, "body": body, "group": "Foundations"})
    return secs

def parse_cli():
    lines = read_md("cli-playbook.md")
    segs  = split_h2(lines)
    secs  = []
    intro_body = []
    for raw_title, body in segs:
        if not raw_title:
            intro_body = list(body)
            continue
        # Merge the "Contents" TOC section into the overview
        if raw_title.strip().lower() == "contents":
            intro_body += ["", "### Contents"] + body
            continue
        sid = make_sid("cli", raw_title)
        nav = raw_title
        h2  = inline_md(raw_title)
        secs.append({"id": sid, "nav": nav, "h2": h2, "body": body, "group": "CLI Reference"})
    # Prepend overview
    secs.insert(0, {"id": "cli-overview", "nav": "Overview & Conventions",
                    "h2": "CLI Playbook &mdash; Overview &amp; Conventions",
                    "body": intro_body, "group": "CLI Reference"})
    return secs

def parse_gui():
    lines = read_md("gui-playbook.md")
    segs  = split_h2(lines)
    secs  = []
    intro_body = []
    for raw_title, body in segs:
        if not raw_title:
            intro_body = list(body)
            continue
        tl = raw_title.strip().lower()
        # Merge "Launching" and "Contents" into the overview
        if tl in ("launching", "contents"):
            # Add a sub-heading so the content is visible
            intro_body += ["", f"### {raw_title}"] + body
            continue
        sid = make_sid("gui", raw_title)
        nav = raw_title
        h2  = inline_md(raw_title)
        secs.append({"id": sid, "nav": nav, "h2": h2, "body": body, "group": "GUI Reference"})
    secs.insert(0, {"id": "gui-overview", "nav": "Launching & Conventions",
                    "h2": "GUI Playbook &mdash; Launching &amp; Conventions",
                    "body": intro_body, "group": "GUI Reference"})
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

# SDK Features sub-tab scroll links (gui-6 / gui-sdk-features-tab)
SDK_SUBTABS = [
    ("6.1", "Templates",     "6-1-templates"),
    ("6.2", "Cert Summaries","6-2-cert-summaries"),
    ("6.3", "Approvals",     "6-3-approvals"),
    ("6.4", "Work Items",    "6-4-work-items"),
    ("6.5", "Workflows",     "6-5-workflows"),
    ("6.6", "Filters",       "6-6-filters"),
]

def build_sidebar(all_secs):
    parts   = []
    mobile  = []
    counter = 0
    cur_grp = None
    sdk_sid = None  # will be set when we hit the SDK section

    for sec in all_secs:
        grp = sec["group"]
        if grp != cur_grp:
            parts.append(f'<div class="sidebar-group-label">{esc(grp)}</div>\n')
            cur_grp = grp
        counter += 1
        sid = sec["id"]
        parts.append(nav_link(sid, sec["nav"], counter))
        mobile.append(mobile_link(sid, sec["nav"]))

        # Inject the SDK sub-tab scroll links ONLY under the GUI SDK Features
        # tab. The 6.1-6.6 sub-tabs (Templates ... Filters) are a GUI concept and
        # their anchors (6-1-templates ...) live only in the GUI section's body.
        # The CLI "6. SDK features" section (cli-sdk-features) documents 3 scripts
        # by name and has none of those anchors, so injecting the sub-links there
        # produced dead links to a different (hidden) section -- match the GUI id
        # exactly rather than the loose substring "sdk-features".
        if sid == "gui-sdk-features-tab":
            sdk_sid = sid
            for stnum, stname, stanchor in SDK_SUBTABS:
                parts.append(
                    f'<a href="javascript:void(0)" class="sidebar-sub" '
                    f'onclick="showSection(\'{sid}\'); '
                    f'setTimeout(function(){{var e=document.getElementById(\'{stanchor}\');'
                    f'if(e)e.scrollIntoView({{behavior:\'smooth\'}});}},80); return false;">'
                    f'<span class="sidebar-num">{stnum}</span>'
                    f'<span>{esc(stname)}</span></a>\n'
                )

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

def parse_delta_cert():
    lines = read_md("delta-cert-playbook.md")
    segs  = split_h2(lines)
    secs  = []
    intro_body = []
    for raw_title, body in segs:
        if not raw_title:
            intro_body = list(body)
            continue
        sid = make_sid("dc", raw_title)
        nav = raw_title
        h2  = inline_md(raw_title)
        secs.append({"id": sid, "nav": nav, "h2": h2, "body": body, "group": "Delta Certification"})
    secs.insert(0, {"id": "dc-overview", "nav": "Overview & Purpose",
                    "h2": "Delta Certification — Overview &amp; Purpose",
                    "body": intro_body, "group": "Delta Certification"})
    return secs

def build():
    found = parse_foundations()
    cli   = parse_cli()
    gui   = parse_gui()
    dc    = parse_delta_cert()
    all_secs = found + cli + gui + dc

    sidebar_html, mobile_html = build_sidebar(all_secs)
    sections_html = "".join(render_section(s) for s in all_secs)

    all_ids   = [s["id"] for s in all_secs]
    ids_json  = "[" + ", ".join(f'"{i}"' for i in all_ids) + "]"

    fw_css = read_css()

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
    // Match links by onclick content containing the id
    document.querySelectorAll('#sidebar a[onclick], #mobile-nav a[onclick]').forEach(function(a) {{
        if (a.getAttribute('onclick') && a.getAttribute('onclick').indexOf("'" + id + "'") !== -1
                && !a.classList.contains('sidebar-sub')) {{
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
</style>
</head>
<body>

<!-- ═══ Sticky header ═══════════════════════════════════════════════════════ -->
<div id="top-band">
  <div id="report-header">
    <div class="title-block">
      <div class="report-title">{esc(TITLE)}</div>
      <div class="report-sub">{esc(SUBTITLE)}</div>
    </div>
    <div class="meta-items">
      <div class="meta-item"><strong>Version</strong>{VERSION}</div>
      <div class="meta-item"><strong>Date</strong>{DATE}</div>
      <div class="meta-item"><strong>Platform</strong>PowerShell 5.1 &middot; WPF GUI</div>
    </div>
  </div>
  <!-- Mobile tab bar (hidden on desktop) -->
  <div id="mobile-nav">
{mobile_html}
  </div>
</div>

<!-- ═══ Layout: sidebar + content ══════════════════════════════════════════ -->
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

    OUT.write_text(doc, encoding="utf-8")
    # Also refresh the repo-root copy. The canonical generator output lives in docs/, but
    # build-dist.ps1 packages the repo-root USER-GUIDE.html into the user zip -- writing both
    # here keeps them in sync so the shipped guide never goes stale behind a playbook edit.
    ROOT_OUT = REPO / "USER-GUIDE.html"
    ROOT_OUT.write_text(doc, encoding="utf-8")
    kb = OUT.stat().st_size // 1024
    print(f"Wrote: {OUT}")
    print(f"Wrote: {ROOT_OUT}")
    print(f"Size:  {kb} KB")
    print(f"Sections: {len(all_secs)}  "
          f"(Foundations: {len(found)}, CLI: {len(cli)}, GUI: {len(gui)})")
    ids_str = "\n  ".join(all_ids)
    print(f"Section IDs:\n  {ids_str}")

if __name__ == "__main__":
    build()
