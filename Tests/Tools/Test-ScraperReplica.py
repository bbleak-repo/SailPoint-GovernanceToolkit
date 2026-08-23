#!/usr/bin/env python3
"""Python replica of the scraper parsing pipelines, used as a harness-independent
cross-check when no PowerShell runtime is available (e.g. Linux analysis containers).

Replicates, line-for-line in intent, the extraction logic of:
  - Scripts/Invoke-SPPendingReviewerScrape.ps1  (Get-PendingReviewers and its filters:
    header-based reviewer-column resolution, V4d subhead fallback, placeholder/N-A
    name rejection)
  - Scripts/Invoke-SPDecisionScrape.ps1         (Get-RevokedItems / Get-NewScopeItems,
    cross-snapshot dedupe, Decision Date bucketing, Get-ApprovedTotal)

IMPORTANT: this file does not test the PowerShell scripts themselves -- it re-implements
their regex pipeline so results can be compared against known-good numbers. If you
change the parsing rules in the .ps1 files, update this replica to match.

Usage:
  python3 Tests/Tools/Test-ScraperReplica.py                    # self-tests only
  python3 Tests/Tools/Test-ScraperReplica.py <report-folder>    # + scrape a real folder

With a folder argument it prints per-reviewer pending counts and deduped decision
totals for every daily-evidence-v4b-*.html / Daily-Attestation-Evidence-Report-*.html
file found, so output can be diffed against the PowerShell dashboards.
"""

import glob
import os
import re
import sys
from collections import Counter
from datetime import datetime

# ---------------------------------------------------------------------------
# Shared helpers (mirror ConvertTo-Safe / Remove-HtmlTags semantics)
# ---------------------------------------------------------------------------

def clean(s):
    """Strip tags, collapse whitespace (mirrors Remove-HtmlTags)."""
    s = re.sub(r"<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", s).strip()


# ---------------------------------------------------------------------------
# Pending reviewer scrape (Invoke-SPPendingReviewerScrape.ps1)
# ---------------------------------------------------------------------------

def name_real(n):
    """Mirror Test-ReviewerNameReal: reject blanks, placeholders, N/A, long notes."""
    if not n or len(n) > 120:
        return False
    if re.match(r"(?i)^\(?unassigned\)?$", n):
        return False
    if re.match(r"(?i)^(n/?a|none|-+)$", n):
        return False
    if re.match(r"(?i)^no\b.*\b(undecided|decisions?|items?|reviewers?|approvals?)\b", n):
        return False
    return True


def get_pending_reviewers(html):
    """Mirror Get-PendingReviewers: distinct reviewer names from Pending/Undecided
    collapsibles, resolving the reviewer column from table headers and falling back
    to V4d-style subhead divs when tables carry no Reviewer column."""
    names = set()
    blocks = re.findall(r"<details\b[^>]*>(.*?)</details>", html, re.S) or [html]
    for block in blocks:
        sm = re.search(r"<summary\b[^>]*>(.*?)</summary>", block, re.S)
        text = clean(sm.group(1)) if sm else ""
        if not re.search(r"(?i)pending|undecided", text):
            continue
        if re.search(r"(?i)\b(completed|reassigned|approved|revoked)\b", text):
            continue
        tables = re.findall(r"<table\b[^>]*>(.*?)</table>", block, re.S)
        if not tables:
            continue
        need_subhead = False
        for t in tables:
            headers = re.findall(r"<th\b[^>]*>(.*?)</th>", t, re.S)
            idx = 0
            if headers:
                idx = next(
                    (i for i, h in enumerate(headers) if re.search(r"(?i)reviewer", clean(h))),
                    -1,
                )
                if idx < 0:
                    need_subhead = True
                    continue
            for row in re.findall(r"<tr\b[^>]*>(.*?)</tr>", t, re.S):
                if "<th" in row:
                    continue
                cells = re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", row, re.S)
                if len(cells) <= idx:
                    continue
                n = clean(cells[idx])
                if name_real(n):
                    names.add(n)
        if need_subhead:
            for sh in re.findall(
                r"<div\b[^>]*class=['\"][^'\"]*subhead[^'\"]*['\"][^>]*>(.*?)</div>", block, re.S
            ):
                n = clean(re.sub(r"<span\b[^>]*>.*?</span>", " ", sh, flags=re.S))
                if name_real(n):
                    names.add(n)
    return names


# ---------------------------------------------------------------------------
# Decision scrape (Invoke-SPDecisionScrape.ps1)
# ---------------------------------------------------------------------------

def get_decision_items(html, kind):
    """Mirror Get-RevokedItems ('rev') / Get-NewScopeItems ('ns').
    Returns tuples: (identity, access, source, reviewer, decision_date_raw)."""
    out = []
    for b in re.finditer(r"<details\b[^>]*>(.*?)</details>", html, re.S):
        c = b.group(1)
        sm = re.search(r"<summary\b[^>]*>(.*?)</summary>", c, re.S)
        if not sm:
            continue
        tag, text = sm.group(0), clean(sm.group(1))
        if kind == "rev":
            if not re.search(r"(?i)\brevoked\b", text):
                continue
            if "s-red" not in tag and not re.search(r"(?i)\bitems?\b", text):
                continue
            if re.search(r"(?i)\b(completed|approved)\b", text):
                continue
        else:
            if not re.search(r"(?i)(new\s+scope|approved\s+access)", text) or "s-green" not in tag:
                continue
        for t in re.findall(r"<table\b[^>]*>(.*?)</table>", c, re.S):
            for row in re.findall(r"<tr\b[^>]*>(.*?)</tr>", t, re.S):
                if "<th" in row:
                    continue
                cells = [clean(x) for x in re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", row, re.S)]
                if kind == "rev":
                    # V4b: Identity|Account|AccessName|Source|Reviewer|DecisionDate|Justification|Remediation
                    if len(cells) < 5 or not cells[0]:
                        continue
                    dd = cells[5] if len(cells) >= 6 else ""
                    out.append((cells[0], cells[2], cells[3], cells[4], dd))
                else:
                    # V4b: Identity|AccessName|Source|Reviewer|DecisionDate|Privileged
                    if len(cells) < 4 or not cells[0]:
                        continue
                    dd = cells[4] if len(cells) >= 5 else ""
                    out.append((cells[0], cells[1], cells[2], cells[3], dd))
    return out


def get_approved_total(html):
    """Mirror Get-ApprovedTotal: sum the Approved column of the campaign summary
    table (header row contains 'Campaign' and an exact 'Approved' column). Returns
    -1 when absent. The value is a campaign-to-date level, not a daily increment."""
    for t in re.findall(r"<table\b[^>]*>(.*?)</table>", html, re.S):
        headers = [clean(h) for h in re.findall(r"<th\b[^>]*>(.*?)</th>", t, re.S)]
        if not headers or not re.search(r"(?i)campaign", "|".join(headers)):
            continue
        ap = next((i for i, h in enumerate(headers) if re.match(r"(?i)^approved$", h)), -1)
        if ap < 0:
            continue
        total, found = 0, False
        for row in re.findall(r"<tr\b[^>]*>(.*?)</tr>", t, re.S):
            if "<th" in row:
                continue
            cells = [clean(x) for x in re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", row, re.S)]
            if len(cells) <= ap:
                continue
            txt = re.sub(r"[,\s]", "", cells[ap])
            if txt.isdigit():
                total += int(txt)
                found = True
        if found:
            return total
    return -1


def bucket_day(decision_date_raw, report_day):
    """Mirror Resolve-DecisionDay: the item's own Decision Date wins; report day is
    the fallback for '-'/'N/A'/unparseable cells."""
    try:
        return datetime.strptime(decision_date_raw[:10], "%Y-%m-%d").strftime("%Y-%m-%d")
    except ValueError:
        return report_day


def dedupe_decisions(report_list):
    """Mirror the main aggregation: registers are cumulative campaign snapshots, so
    de-duplicate by identity|access|source|reviewer|decision-date across the window
    (first sighting wins) and bucket by decision day.

    report_list: [(html, report_day_yyyy_mm_dd)] in chronological order.
    Returns (revoked_days, newscope_days) -- lists of yyyy-MM-dd bucket labels."""
    seen_r, seen_n, rev, ns = set(), set(), [], []
    for html, rday in report_list:
        for it in get_decision_items(html, "rev"):
            k = "|".join(it).lower()
            if k in seen_r:
                continue
            seen_r.add(k)
            rev.append(bucket_day(it[4], rday))
        for it in get_decision_items(html, "ns"):
            k = "|".join(it).lower()
            if k in seen_n:
                continue
            seen_n.add(k)
            ns.append(bucket_day(it[4], rday))
    return rev, ns


# ---------------------------------------------------------------------------
# Report-date resolution (mirror Resolve-ReportDate, filename part only)
# ---------------------------------------------------------------------------

def resolve_report_day(path):
    base = os.path.splitext(os.path.basename(path))[0]
    base = re.sub(r"(?i)^Daily-Attestation-Evidence-Report[-_ ]*", "", base)
    base = re.sub(r"(?i)^daily-evidence(-v\d\w*)?[-_ ]*", "", base)
    base = base.strip("-_ ")
    m = re.match(r"(\d{4})-?(\d{2})-?(\d{2})", base)
    if m:
        return "-".join(m.groups())
    return datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d")


# ---------------------------------------------------------------------------
# Self-tests (synthetic fixtures for the cases the fixes were written for)
# ---------------------------------------------------------------------------

def self_test():
    failures = []

    def check(label, got, want):
        ok = got == want
        print(("PASS" if ok else "FAIL") + f"  {label}: got {got!r}" + ("" if ok else f", want {want!r}"))
        if not ok:
            failures.append(label)

    # V4b ACTIVE layout: Reviewer column first, placeholder row filtered
    v4b = (
        "<details><summary>Undecided (2)</summary>"
        "<table><thead><tr><th>Reviewer</th><th>Email</th><th>Certs Assigned</th>"
        "<th>Decisions Made</th><th>Sign-Off Date</th><th>Phase</th></tr></thead>"
        "<tbody><tr><td>Alice Smith</td><td>a@x.com</td><td>1</td><td>0</td><td>-</td><td>ACTIVE</td></tr>"
        "<tr><td>N/A</td><td></td><td>1</td><td>0</td><td>-</td><td>ACTIVE</td></tr>"
        "<tr><td colspan='6'>No undecided reviewers.</td></tr></tbody></table></details>"
    )
    check("v4b active + N/A + placeholder", sorted(get_pending_reviewers(v4b)), ["Alice Smith"])

    # V4d layout: item tables (no Reviewer column), reviewer names in subhead divs
    v4d = (
        "<details><summary>Persistently Undecided / Never Attested (3)</summary>"
        "<div class='subhead'>Bob Jones <span class='badge badge-red'>2</span></div>"
        "<table><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th>Current State</th></tr></thead>"
        "<tbody><tr><td>Victim One</td><td>AD_Admins</td><td>AD</td><td>Undecided</td></tr></tbody></table>"
        "<div class='subhead'>Carol Wu <span class='badge badge-red'>1</span></div>"
        "<table><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th>Current State</th></tr></thead>"
        "<tbody><tr><td>Victim Two</td><td>SAP_Fin</td><td>SAP</td><td>Undecided</td></tr></tbody></table>"
        "</details>"
    )
    check("v4d subhead fallback (no identity poisoning)", sorted(get_pending_reviewers(v4d)), ["Bob Jones", "Carol Wu"])

    # V4e layout: Reviewer column present; hyphenated empty-state row filtered
    v4e = (
        "<details><summary>Persistently Undecided / Never Attested by Reviewer (0)</summary>"
        "<table><thead><tr><th>Reviewer</th><th>Email</th><th>Never Attested</th><th>Items Never Decided</th></tr></thead>"
        "<tbody><tr><td colspan='4'>No persistently-undecided items in this window.</td></tr></tbody></table></details>"
    )
    check("v4e empty-state placeholder filtered", sorted(get_pending_reviewers(v4e)), [])

    # Cumulative snapshots: day-2/day-3 reports re-list earlier decisions;
    # dedupe + decision-date bucketing must count each item once, on its real day
    def mk(rows):
        body = "".join(
            f"<tr><td>{i}</td><td>acct</td><td>{a}</td><td>Src</td><td>Rev</td><td>{d} 12:00</td><td>j</td></tr>"
            for i, a, d in rows
        )
        return (
            f"<details><summary class='s-red'>Revoked ({len(rows)} items)</summary>"
            "<table><thead><tr><th>Identity</th><th>Account</th><th>Access Name</th><th>Source</th>"
            "<th>Reviewer</th><th>Decision Date</th><th>Justification</th></tr></thead>"
            f"<tbody>{body}</tbody></table></details>"
        )

    d1 = [("u1", "app1", "2026-08-01")]
    d2 = d1 + [("u2", "app2", "2026-08-02"), ("u3", "app3", "2026-08-02")]
    d3 = d2 + [("u4", "app4", "2026-08-04")]
    rev, _ = dedupe_decisions([(mk(d1), "2026-08-01"), (mk(d2), "2026-08-02"), (mk(d3), "2026-08-04")])
    check("cumulative dedupe buckets", dict(sorted(Counter(rev).items())),
          {"2026-08-01": 1, "2026-08-02": 2, "2026-08-04": 1})

    # Approved total from a campaign summary table (comma-formatted numbers)
    camp = (
        "<table><thead><tr><th>Campaign</th><th>Status</th><th>Total Items</th><th>Approved</th>"
        "<th>Revoked</th><th>Undecided</th></tr></thead>"
        "<tbody><tr><td>C1</td><td>ACTIVE</td><td>10,000</td><td>8,441</td><td>500</td><td>1,059</td></tr>"
        "<tr><td>C2</td><td>ACTIVE</td><td>12,000</td><td>10,000</td><td>800</td><td>1,200</td></tr></tbody></table>"
    )
    check("approved total (multi-campaign sum)", get_approved_total(camp), 18441)
    check("approved total absent -> -1", get_approved_total("<p>no tables</p>"), -1)

    print()
    if failures:
        print(f"{len(failures)} self-test(s) FAILED")
        return 1
    print("All self-tests passed.")
    return 0


# ---------------------------------------------------------------------------
# Folder scrape mode
# ---------------------------------------------------------------------------

def scrape_folder(folder):
    patterns = ["daily-evidence-v4b-*.html", "Daily-Attestation-Evidence-Report-*.html"]
    files = sorted({p for pat in patterns for p in glob.glob(os.path.join(folder, pat))})
    if not files:
        print(f"No report files matching {patterns} in {folder}")
        return 1
    print(f"{len(files)} report file(s) in {folder}\n")

    pending_counts = Counter()
    report_list = []
    approved_snapshots = []
    for path in files:
        html = open(path, encoding="utf-8", errors="replace").read()
        rday = resolve_report_day(path)
        for n in get_pending_reviewers(html):
            pending_counts[n] += 1
        report_list.append((html, rday))
        ap = get_approved_total(html)
        if ap >= 0:
            approved_snapshots.append((rday, ap))

    print("Pending reviewers (files seen pending in):")
    for n, c in pending_counts.most_common():
        print(f"  {c:3d}  {n}")

    rev, ns = dedupe_decisions(report_list)
    # Axis mirrors the PowerShell scraper: decision days PLUS report days, so a quiet
    # report day shows as a zero row instead of vanishing.
    report_days = {rday for _, rday in report_list}
    days = sorted(set(rev) | set(ns) | report_days)
    rc, nc = Counter(rev), Counter(ns)
    print(f"\nDeduped decisions: {len(rev)} revoked, {len(ns)} new scope, "
          f"{len(set(rev) | set(ns))} decision day(s), {len(days)} axis day(s)")
    for d in days:
        print(f"  {d}  revoked={rc.get(d, 0):5d}  newscope={nc.get(d, 0):5d}")
    if approved_snapshots:
        first, last = approved_snapshots[0], approved_snapshots[-1]
        print(f"\nApproved campaign-to-date: {last[1]:,} on {last[0]} "
              f"(window start {first[1]:,} on {first[0]}, delta {last[1] - first[1]:+,})")
    return 0


if __name__ == "__main__":
    rc = self_test()
    if len(sys.argv) > 1:
        print()
        rc = max(rc, scrape_folder(sys.argv[1]))
    sys.exit(rc)
