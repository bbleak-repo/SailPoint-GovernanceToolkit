# Round 16
**Started:** 2026-05-30 19:58:49

**QH-17 complete.** Added two new functions to `SP.Vault.psm1`:

- **`Update-SPVaultCredential`** -- Updates ClientId and/or ClientSecret for an existing vault key in-place. At least one field required; unchanged fields preserved. Returns `@{Success; Data=@{UpdatedFields}; Error}`.

- **`Update-SPVaultPassphrase`** -- Decrypts vault with current passphrase, re-encrypts with a new one (fresh salt + IV). Enforces 12-char minimum, verifies read-back. Returns `@{Success; Data=@{KeyCount}; Error}`.

Both exported from `SP.Vault.psm1` and `SP.Core.psd1`. Committed and pushed to `feature/quality-hardening`.

**Completed:** 2026-05-30 20:01:04
**Status:** SUCCESS
