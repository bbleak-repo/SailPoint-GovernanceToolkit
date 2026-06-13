# How to Continue the Loop

You are running an autonomous improvement loop focused on SP.Shared modularization
and toolkit enhancement.

## Resume Steps
1. Read .claude/loop/CURRENT.md for state
2. Read the last 2-3 files in .claude/loop/completed/
3. Run a discovery pass: tests, imports, grep for inline patterns to consolidate
4. Pick 3-4 non-overlapping items, spawn parallel agents
5. Verify results (module import, Pester tests)
6. Update CURRENT.md, write completed/iteration_NNN.md
7. Commit and continue

## Key Files
- `Modules/SP.Shared/SP.HtmlHelpers.psm1` -- shared utility functions
- `Modules/SP.Shared/SP.Shared.psd1` -- module manifest
- `Tests/Import-TestModules.ps1` -- test module loader (-Shared flag)
- `Scripts/Show-SPDashboard.ps1` -- production module load chain

## Focus Areas
1. Write Pester tests for SP.HtmlHelpers
2. Fix pre-existing test failures (12 across 6 test files)
3. Expand wrapper coverage to remaining modules with inline patterns
4. Replace raw WebUtility::HtmlEncode/WriteAllText calls with shared functions
5. Add SP.Shared to remaining script module chains
