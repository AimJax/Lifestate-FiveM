# NPWD patch — `disabledApps` support

## Why this file differs from upstream

Resource: `[npwd]/npwd` (NPWD 3.15.1-beta.2, installed from upstream release).

Upstream NPWD builds its built-in app list from a hard-coded array (`Lle`) in
the compiled UI bundle, and the `isDisabled` flag that hides an app from both
the home grid **and** the router is fed only by a hard-coded `disable` key on
each entry. NPWD's own `disabledApps` config key exists in its default config
schema (`disabledApps: []` in the defaults object, and the key is present in
`config.json`) but is read by nothing in this build — `grep -c disabledApps`
returns exactly one occurrence per bundle, and that occurrence is the defaults
literal.

The Lifestate App Store (`resources/[npwd-apps]/npwd_lifestate_app_store`)
needs that key to work: it hides/unlaunches Matchmaker (`MATCH`), IRC
(`DARKCHAT`), Social (`TWITTER`) and Marketplace (`MARKETPLACE`) per character
through `lifestate_phone_apps` install state, pushed via
`exports.npwd:sendNPWDMessage('PHONE', 'npwd:setPhoneConfig', config)`.

## The patch (three lines, one file)

File: `dist/html/assets/index-ebf41f23.js`

```js
// 1. read the key (inside Cn(), beside the icon-set read):
//    shipped:   i=Vg().iconSet.value,t=p6(()=>Lle.map(s=>{
//    patched:   i=Vg().iconSet.value,npwdDis=Ve(wi.resourceConfig)?.disabledApps||[],t=p6(()=>Lle.map(s=>{

// 2. grid icon hidden for a disabled app (first isDisabled site):
//    shipped:   isDisabled:s.disable}:{
//    patched:   isDisabled:s.disable||npwdDis.includes(s.id)}:{

// 3. route skipped for a disabled app + memo re-derives on config change
//    (second isDisabled site; the memo dependency list):
//    shipped:   isDisabled:s.disable}}),[e,i,a])
//    patched:   isDisabled:s.disable||npwdDis.includes(s.id)}}),[e,i,a,npwdDis])
```

An app with `isDisabled` is skipped by both the home grid and the router, so a
disabled built-in is genuinely unlaunchable rather than CSS-hidden.

## Second patch — goBack fallback (phone Back button)

Recorded in [`goBack-fallback.patch`](goBack-fallback.patch): the phone's top
back arrow, the Backspace handler and every app's header back button all call
the hash history's `goBack`, which upstream implements as a bare
`history.go(-1)` with no fallback — it does nothing when the router has no
previous in-app entry. The patch adds a depth guard: previous entry exists →
`go(-1)`; at the session's first entry but not `/` → go home (`#/`); already at
home → no-op. One function, every app fixed.

## Re-applying after an NPWD update

1. Replace `[npwd]/npwd` with the new upstream release.
2. Edit `config.json`: set `"disabledApps"` to
   `["BROWSER", "MATCH", "DARKCHAT", "TWITTER", "MARKETPLACE"]`.
3. Locate the built-in app array in the new bundle
   (`grep -o 'nameLocale:"APPS_' dist/html/assets/*.js`) and apply the three
   changes above, adjusted to the new minified identifiers:
   - read `resourceConfig?.disabledApps` next to the existing config read,
   - OR it into both `isDisabled` sites,
   - add it to the surrounding `useMemo` dependency list.
4. Restart `npwd`. If the built-ins reappear on a fresh character, the patch
   did not land — check `patches/` first, not the App Store resource.
