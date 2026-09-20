# LS One — custom NPWD phone shell (source of truth)

This directory is the tracked, reproducible source of the Lifestate "LS One"
phone shell. The live NPWD frontend (`resources/[npwd]/npwd/dist/html`) is
git-ignored build output; it is produced from here, never edited by hand.

## Baseline

- Upstream: `https://github.com/project-error/npwd.git`
- Pinned commit: `f536882972b66742e8619559b9f7407fffb91942`
  (`chore: bump manifest version to nightly 3.15.1-beta.2`, 2025-03-27) —
  byte-identical to the previously installed NPWD 3.15.1-beta.2.
- `ls-one-shell.patch`: the ONLY source delta vs that commit (4 files).
  Apply with `git apply` from the upstream checkout root and verify with
  `git status --short` (exactly those 4 files modified, nothing else).

## What the patch changes (visual shell only)

1. `apps/phone/src/Phone.css` — CSS graphite frame on `.PhoneFrame`
   (replaces the Samsung PNG via `background-image: none !important`),
   7px punch-hole camera (`::before`), 26px earpiece slit (`::after`),
   3px red power-button tick, 12px uniform bezels, 44px display radius.
2. `apps/phone/src/os/navigation-bar/components/Navigation.tsx` — transparent
   bar, centered 44x4 home pill; back/close keep identical handlers.
3. `apps/phone/src/os/new-notifications/components/NotificationBar.tsx` —
   time + notification icons left-aligned (top center stays clear for the
   camera), 20px side padding. Drawer/toggle behavior untouched.
4. `apps/phone/src/apps/home/components/Home.tsx` — grid margins only
   (`mt-7 px-2`).

No server code, no app IDs, no NUI endpoints, no federation IDs, no gameplay.

## Rebuild & deploy

Run from the repo root (Windows, PowerShell):

```powershell
.\patches\npwd\ls-one\rebuild-lsone.ps1
```

The script (no dependency on any Temp leftovers):

1. checks `node`, `pnpm`, `git` are present,
2. clones the pinned baseline into a fresh work dir (default:
   `$env:LOCALAPPDATA\Temp\npwd-lsone-build`, override with `-WorkDir`;
   reuses it if it already holds the pinned commit),
3. applies `ls-one-shell.patch` (aborts unless exactly 4 files change),
4. `pnpm install` (approves only the postinstalls the build needs),
5. builds `@npwd/keyos` then `@npwd/nui` (`vite build --mode game`),
6. re-applies the production bundle patches onto the fresh build and
   verifies each replacement occurs exactly once:
   - `disabledApps` support (see `../index-ebf41f23.js.patch`; the app-array
     identifier differs per build — the script asserts the fragments it
     writes about),
   - goBack route-aware fallback + chunk rename to
     `__federation_shared_react-router-dom-lifestate-backfix.js` with all
     references updated (see `../goBack-fallback.patch`),
7. replaces `resources/[npwd]/npwd/dist/html` with the fresh output
   (`dist/game` server code is never touched),
8. verifies the LS One markers + both production patches in the deployed
   bundle.

The script never touches server-side NPWD state, app IDs, the database, or
federation configuration beyond the documented chunk rename.

## After an upstream NPWD update

1. Point `NPWD_PIN` in the script at the new release commit.
2. Re-apply `ls-one-shell.patch` (resolve hunks against the new sources).
3. Re-derive the minified identifiers for the two bundle patches using the
   re-apply guides in `../index-ebf41f23.js.patch` and
   `../goBack-fallback.patch`.
4. Rebuild, restart `npwd`, verify live before blaming anything else.
