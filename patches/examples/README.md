# Configuration examples (sanitized)

These templates document the shape of configuration files that live on the
server but are **not** tracked here, because the real ones contain endpoints,
keys or admin data.

| File | Mirrors | Secrets removed |
| --- | --- | --- |
| `npwd.config.example.json` | `resources/[npwd]/npwd/config.json` | image/audio upload endpoints and any auth headers replaced with placeholders |

The Lifestate-relevant parts are exactly two:

- `"apps"` — external NPWD apps. Managed ids (`npwd_lifestate_ojol`,
  `npwd_lifestate_ojol_customer`, and the four NPWD built-in ids) must NOT be
  listed here; the App Store re-adds them per character from install state.
- `"disabledApps"` — NPWD's own disable switch (works only with the patch
  recorded in `../npwd/`). A fresh character starts with the browser and the
  four optional built-ins hidden; the App Store drives the rest per character.
