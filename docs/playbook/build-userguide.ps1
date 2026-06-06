# build-userguide.ps1
# Generates docs/USER-GUIDE.html from the three playbook Markdown source files.
# Usage: .\docs\playbook\build-userguide.ps1
# Requires: Python 3 with no extra packages (uses stdlib only)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
$builder   = Join-Path $scriptDir "build-userguide.py"
python $builder --repo $repoRoot
