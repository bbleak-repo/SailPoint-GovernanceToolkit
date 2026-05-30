# Round 2
**Started:** 2026-05-29 23:54:53

**OC-02 complete.** Added `Show-SPOrgTree` to `SP.DeltaCertQueries.psm1` (lines 1585-1775).

**What it does:**
- Finds root nodes (no manager in tree) and renders each subtree recursively
- ASCII box-drawing: `+--` branches, `|` vertical continuation (PS 5.1 compatible, no unicode)
- `-MaxChildrenShown 5` (default) truncates with `(N more)` indicator; `-Full` shows all
- `-ShowBands` displays band letter per node (supplement `Band` property > auto-detect from depth: 0=E, 1=D, 2=C, 3=B, 4+=A)
- Nodes with `Title` property (from supplement merge) show it in parens
- Summary footer: count per level (VPs, Directors, Managers, ICs) + depth + unmanaged count
- Sorted: highest level first, then alphabetically

**Completed:** 2026-05-30 00:01:59
**Status:** SUCCESS
