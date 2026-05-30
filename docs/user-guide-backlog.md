# Tabbed HTML User Guide -- Backlog (UG-01 to UG-10)

**Created:** 2026-05-30
**Purpose:** Professional tabbed HTML user guide + reusable framework
**Reference design:** attorney-complete-report.html (sidebar nav, sticky header, mobile tabs)

---

## How to Use This File

Agent loop: `UG-01 -> UG-02 -> UG-03 -> UG-04 -> UG-05 -> UG-06 -> UG-07 -> UG-08 -> UG-09 -> UG-10`

---

## Two Deliverables

1. **Reusable framework** at `/Users/xand/Documents/Projects/.claude-frameworks/tabbed-report/`
   - Python generator builds self-contained HTML from section content files
   - Themes, sidebar nav, mobile-responsive, print-friendly
   - Reusable by CyberArk, Okta, or any future project

2. **SailPoint User Guide** at `USER-GUIDE.html` in the toolkit root
   - 4 major tabs with sub-sections
   - Professional presentation matching the toolkit's color scheme
   - Included in the user handoff zip

---

## Design Reference (from attorney-complete-report.html)

**Layout pattern:**
```
+-------------------------------------------+
| Sticky Header (title, version, meta)      |
+--------+----------------------------------+
| Sidebar| Content Area                     |
| Nav    |                                  |
| (1)    | Section content with             |
| (2)    | tables, code blocks,             |
| (3)    | examples, parameters             |
| (4)    |                                  |
|        |                                  |
+--------+----------------------------------+
```

**Key CSS/JS patterns to replicate:**
- CSS variables for theming (`--primary`, `--sidebar-bg`, `--text`)
- `showSection(id)` JS function: hide all sections, show target, update active states
- Sidebar with numbered section links + active indicator (left border)
- Mobile: sidebar hidden, horizontal scrolling tab bar shown
- Print: all sections visible, sidebar hidden, page breaks between sections
- Self-contained (no external CSS, JS, fonts, or images)

**SailPoint color scheme:**
```css
:root {
    --primary:    #336699;   /* blue -- headers, active state */
    --success:    #339933;   /* green -- pass, approved */
    --danger:     #CC3333;   /* red -- fail, revoked */
    --warning:    #FF8800;   /* orange -- pending, warn */
    --sidebar-bg: #1e2a3a;   /* dark blue-gray sidebar */
    --header-bg:  #2c3e50;   /* dark header */
    --accent:     #5B9BD5;   /* light blue accent */
    --text:       #2c3e50;   /* body text */
    --bg:         #f7f8fa;   /* page background */
    --surface:    #ffffff;   /* content card background */
}
```

---

## Phase Summary

| ID | Feature | Depends On | Status |
|----|---------|------------|--------|
| UG-01 | Framework Shell Template (HTML+CSS+JS) | none | DONE |
| UG-02 | Framework Python Generator | UG-01 | DONE |
| UG-03 | Framework Themes (light + dark) | UG-01 | DONE |
| UG-04 | Getting Started Section Content | none | DONE |
| UG-05 | Campaign Audit Section Content | none | DONE |
| UG-06 | Delta Certification Section Content | none | DONE |
| UG-07 | Disconnected Apps Section Content | none | PENDING |
| UG-08 | Generate SailPoint USER-GUIDE.html | UG-02 to UG-07 | PENDING |
| UG-09 | Update README/QUICKSTART References | UG-08 | PENDING |
| UG-10 | Add to Handoff Zip + Validation | UG-09 | PENDING |

---

## UG-01: Framework Shell Template

- **Status:** `DONE`
- **Commit:** (committed on feature/user-guide)
- **Depends On:** none

**Description:**
Create the HTML shell template for the tabbed report framework. This is the outer
structure: sticky header, sidebar navigation, content area, mobile tab bar, and the
JavaScript for section switching.

**Files to Create at `/Users/xand/Documents/Projects/.claude-frameworks/tabbed-report/`:**
- `templates/shell.html` -- main HTML structure with placeholders
- `README.md` -- framework documentation

**Shell template structure:**
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{TITLE}}</title>
    <style>{{THEME_CSS}}</style>
</head>
<body>
    <!-- Sticky header -->
    <div id="top-band">
        <div id="report-header">
            <div class="title-block">
                <div class="report-title">{{TITLE}}</div>
                <div class="report-sub">{{SUBTITLE}}</div>
            </div>
            <div class="meta-items">{{HEADER_META}}</div>
        </div>
        <!-- Mobile tab bar (hidden on desktop) -->
        <div id="mobile-nav">{{MOBILE_TABS}}</div>
    </div>

    <!-- Layout: sidebar + content -->
    <div id="app-layout">
        <div id="sidebar">
            <div id="sidebar-inner">
                <div class="sidebar-label">{{SIDEBAR_LABEL}}</div>
                {{SIDEBAR_LINKS}}
            </div>
        </div>
        <div id="content-area">
            {{SECTIONS}}
        </div>
    </div>

    <script>
    var sections = [{{SECTION_IDS}}];
    function showSection(id) {
        sections.forEach(function(s) {
            var el = document.getElementById('section-' + s);
            if (el) el.style.display = 'none';
        });
        var target = document.getElementById('section-' + id);
        if (target) target.style.display = 'block';
        document.querySelectorAll('#sidebar a, #mobile-nav a').forEach(function(a) {
            a.classList.remove('active');
        });
        document.querySelectorAll('#sidebar a[href="#' + id + '"], #mobile-nav a[href="#' + id + '"]').forEach(function(a) {
            a.classList.add('active');
        });
        if (history.replaceState) history.replaceState(null, '', '#' + id);
        window.scrollTo(0, 0);
    }
    window.showSection = showSection;

    // Show first section or hash target on load
    document.addEventListener('DOMContentLoaded', function() {
        var hash = location.hash.replace('#', '');
        showSection(hash && sections.indexOf(hash) !== -1 ? hash : sections[0]);
    });
    </script>
</body>
</html>
```

**CSS requirements (embedded in shell):**
- Sidebar: fixed width (220px), sticky, dark background, scrollable
- Header: sticky top, flex layout, responsive
- Content: flex-grow, padded, max-width for readability
- Mobile: @media (max-width: 768px) hides sidebar, shows mobile-nav
- Print: @media print hides sidebar/nav, shows all sections, page breaks

**Acceptance Criteria:**
- Shell HTML is valid (no parse errors)
- Placeholders clearly marked with {{PLACEHOLDER}} syntax
- Section switching JS works (show/hide sections, update active state)
- Mobile responsive (sidebar hides, tab bar shows)
- Print friendly (all sections visible)

---

## UG-02: Framework Python Generator

- **Status:** `DONE`
- **Commit:** (committed on feature/user-guide)
- **Depends On:** UG-01

**Description:**
Python script that takes section content files (HTML or Markdown) and the shell
template, and produces a single self-contained HTML file.

**File to Create:** `.claude-frameworks/tabbed-report/generate-report.py`

**Usage:**
```bash
python generate-report.py \
    --title "SailPoint Governance Toolkit" \
    --subtitle "User Guide v1.0" \
    --sections sections/ \
    --theme themes/light.css \
    --output USER-GUIDE.html \
    --sidebar-label "User Guide"
```

**Section file format** (each section is a separate file):
```
sections/
    01-getting-started.html    (or .md)
    02-campaign-audit.html
    03-delta-certification.html
    04-disconnected-apps.html
```

Each section file has a frontmatter header:
```html
<!-- section: getting-started -->
<!-- title: Getting Started -->
<!-- icon: 1 -->

<h2>Prerequisites</h2>
<p>...</p>
```

**Generator flow:**
1. Read shell template
2. Read theme CSS
3. Read and sort section files by filename prefix (01-, 02-, etc.)
4. Parse frontmatter (section ID, title, icon/number)
5. If Markdown: convert to HTML (using Python `markdown` lib or simple regex)
6. Build sidebar links from section list
7. Build mobile tab links
8. Substitute all placeholders in shell template
9. Write single self-contained HTML file

**Dependencies:** Python 3.9+ only. Optional: `markdown` library for .md files.
If markdown lib not installed, only .html section files are supported.

**Acceptance Criteria:**
- Generates valid self-contained HTML from section files + shell + theme
- Section ordering follows filename prefix (01-, 02-, etc.)
- Markdown conversion works if `markdown` library installed
- HTML section files work without any dependencies
- Output file opens correctly in Chrome/Edge/Firefox

---

## UG-03: Framework Themes

- **Status:** `DONE`
- **Commit:** (committed on feature/user-guide)
- **Depends On:** UG-01

**Description:**
Create two CSS theme files for the tabbed report framework.

**Files to Create:**
- `.claude-frameworks/tabbed-report/themes/light.css` -- professional light theme
- `.claude-frameworks/tabbed-report/themes/dark.css` -- dark mode theme

**Light theme** (SailPoint color scheme):
- Sidebar: #1e2a3a (dark blue-gray)
- Header: #2c3e50 with #5B9BD5 accent border
- Active tab: #336699 left border + highlight
- Content: white cards on #f7f8fa background
- Code blocks: #f5f6f8 background, monospace
- Tables: alternating #f9f9f9 rows, #34495e headers

**Dark theme:**
- Sidebar: #141820
- Header: #1a1f2e with #5B9BD5 accent
- Content: #1e2230 cards on #141820 background
- Text: #e0e0e0
- Tables: alternating #252a38 rows

**Acceptance Criteria:**
- Both themes render correctly with the shell template
- CSS variables used consistently (easy to create new themes)
- Print styles override both themes to white background + black text
- No external font references (system fonts only)

---

## UG-04: Getting Started Section Content

- **Status:** `DONE`
- **Commit:** c48b848 (feature/user-guide)
- **Depends On:** none

**Description:**
Write the "Getting Started" section content for the SailPoint User Guide.
This is the first tab users see.

**File to Create:** `docs/user-guide-sections/01-getting-started.html`

**Sub-sections:**
1. **What This Toolkit Does** -- one-paragraph summary
2. **Prerequisites** -- PS 5.1, ISC tenant, PAT scopes (6 read-only), network access
3. **Installation** -- extract zip, navigate, verify files
4. **Configuration** -- settings.json walkthrough (credentials, API URL, safety guards)
5. **First Run** -- `Test-SPConnectivity.ps1` with expected output
6. **Your First Audit** -- `Invoke-SPCampaignAudit.ps1 -Status COMPLETED -WhatIf`
7. **GUI Overview** -- 5-tab description, screenshot reference
8. **Safety Defaults** -- MaxCampaignsPerRun, RequireWhatIfOnProd, AllowCompleteCampaign
9. **Troubleshooting** -- common errors and fixes table

**Acceptance Criteria:**
- A new user can go from zip to first audit in 15 minutes using this section
- All CLI examples use correct parameter names
- PAT scope count is 6 (including sp:search:read)

---

## UG-05: Campaign Audit Section Content

- **Status:** `DONE`
- **Commit:** (committed on feature/user-guide)
- **Depends On:** none

**Description:**
Write the "Campaign Audit" section covering the full audit workflow.

**File to Create:** `docs/user-guide-sections/02-campaign-audit.html`

**Sub-sections:**
1. **Campaign Audit Overview** -- what it produces, report types
2. **CLI Reference: Invoke-SPCampaignAudit.ps1** -- ALL parameters in a table
3. **Leadership Rollup Reports** -- depth levels, per-level generation, org tree
4. **Detail Levels** -- Summary vs Detailed vs Verbose with HTML5 details/summary
5. **Compliance Features** -- 18 mandatory fields, anti-rubber-stamping, risk indicators
6. **Campaign Search** -- Invoke-SPCampaignSearch.ps1 with all search modes
7. **Report Distribution** -- Invoke-SPReportDistribution.ps1, preview + send
8. **Band Classification** -- A-E bands, org chart supplement
9. **Example Workflows** -- quarterly audit, annual compliance, ad-hoc investigation

---

## UG-06: Delta Certification Section Content

- **Status:** `DONE`
- **Commit:** (committed on feature/user-guide)
- **Depends On:** none

**Description:**
Write the "Delta Certification" section covering daily AD access change detection.

**File to Create:** `docs/user-guide-sections/03-delta-certification.html`

**Sub-sections:**
1. **Delta Cert Overview** -- what it does, GRANT_ACCESS event detection
2. **CLI Reference: Invoke-SPADDeltaCert.ps1** -- ALL parameters
3. **Reviewer Modes** -- Manager vs SourceOwner campaigns
4. **Campaign Cleanup** -- auto-complete stale campaigns
5. **Escalation** -- stale cert detection, org tree walk, reassignment
6. **Delta Reports** -- Invoke-SPDeltaReport.ps1, daily changes summary
7. **Daily Orchestrator** -- Invoke-SPDailyOrchestrator.ps1, full workflow
8. **Weekly Digest** -- Invoke-SPWeeklyDigest.ps1
9. **Scheduling** -- Windows Task Scheduler / cron setup

---

## UG-07: Disconnected Apps Section Content

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** none

**Description:**
Write the "Disconnected Apps" section covering flat file onboarding for apps
without ISC connectors.

**File to Create:** `docs/user-guide-sections/04-disconnected-apps.html`

**Sub-sections:**
1. **Disconnected App Overview** -- why flat files, the CSV template approach
2. **CSV Templates** -- v2 column definitions (accounts + entitlements)
3. **Onboarding a New App** -- step-by-step with Invoke-SPDisconnectedAppRegistry.ps1
4. **Single App Processing** -- Invoke-SPDisconnectedAppCert.ps1
5. **Batch Processing** -- Invoke-SPDisconnectedAppBatch.ps1 for 20+ apps
6. **Delta Detection** -- how file comparison works (today vs yesterday)
7. **Remediation Tracking** -- revocation verification via next-day CSV
8. **Decision Collection** -- harvesting campaign outcomes
9. **SLA Tracking + Delivery Monitoring** -- 30-day history, compliance scoring
10. **App Team Dashboard** -- self-service HTML status page
11. **Cross-App Analytics** -- identity risk, entitlement catalog
12. **Org Chart + Report Distribution** -- supplement CSV, band classification, preview

---

## UG-08: Generate SailPoint USER-GUIDE.html

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** UG-02 to UG-07

**Description:**
Run the framework generator to produce the final `USER-GUIDE.html` file from the
4 section files + light theme.

```bash
cd /Users/xand/Documents/Projects/.claude-frameworks/tabbed-report
python generate-report.py \
    --title "SailPoint Governance Toolkit" \
    --subtitle "User Guide v1.0 -- Comprehensive Reference" \
    --sections /path/to/toolkit/docs/user-guide-sections/ \
    --theme themes/light.css \
    --output /path/to/toolkit/USER-GUIDE.html \
    --sidebar-label "User Guide" \
    --meta "Version:1.0" "Generated:2026-05-30"
```

**Acceptance Criteria:**
- Single self-contained HTML file, no external dependencies
- All 4 sections render with correct sidebar navigation
- Tab switching works in Chrome, Edge, Firefox
- Mobile layout works (sidebar hidden, horizontal tabs)
- Print layout shows all sections
- File size < 500KB (no embedded images)
- Opens directly from the filesystem (file:// protocol)

---

## UG-09: Update README/QUICKSTART References

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** UG-08

**Description:**
Add references to USER-GUIDE.html in README.md and QUICKSTART.md.

**README.md changes:**
- Near top: "For the comprehensive interactive guide, open [USER-GUIDE.html](USER-GUIDE.html) in your browser."
- In architecture tree: add `USER-GUIDE.html` under root files

**QUICKSTART.md changes:**
- Add note: "For detailed reference with searchable tabs, see USER-GUIDE.html"

---

## UG-10: Add to Handoff Zip + Validation

- **Status:** `PENDING`
- **Commit:** --
- **Depends On:** UG-09

**Description:**
Include USER-GUIDE.html in the user handoff zip. Validate the HTML is well-formed.

**Validation:**
- HTML parseable by Python html.parser (no unclosed tags)
- All internal links (#section-id) resolve to existing section IDs
- No external URLs referenced (fully offline)
- File size check (< 500KB)

**Acceptance Criteria:**
- USER-GUIDE.html included in handoff zip
- Opens correctly after extracting the zip
- All tab navigation works from the extracted location
