# 0001: Zero-secret Android signing

- **Status:** accepted (Q12)
- **Date:** 2026-10-13

## Context

Monkey's Paw distributes Android APKs through GitHub Releases (Q13).
The signer must be stable before the first release so later APKs can
upgrade an installed copy. This follows HalloMiao's
`docs/decisions/0002-zero-secret-signing.md`.

## Decision

Generate a fresh `android/app/debug.keystore` for this repository and commit
it once. The alias is `androiddebugkey`; the store and key passwords are
both the standard, non-secret `android`. This public key signs both debug
and minified release APKs. CI needs no signing secrets or key import.
`.gitignore` allows exactly this keystore and ignores other keystores.

The certificate SHA-256 fingerprint is:

```text
76:A1:9D:F6:8D:56:27:89:F6:EA:99:0B:23:23:28:75:B7:0A:98:C9:99:6B:A8:1E:79:4C:CA:B0:63:ED:D7:65
```

Both variants use `ch.lkmc.monkeyspaw`, so they replace one another rather
than coexist. The public signing key permits anyone with a clone to build
an APK that can upgrade an existing install.

## Consequences

- The signature proves no publisher identity because the key is public.
  Sideload trust rests on the GitHub Release provenance.
- Switching to a private release key later breaks upgrades for installed
  copies and requires uninstall/reinstall. That is a product decision to
  record in a new ADR before changing the key.
- Store distribution would require revisiting this signing model.
