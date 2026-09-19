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

Recorded in [`goBack-fallback.patch`](goBack-fallback.patch): the phone's
bottom-right back chevron, the Backspace handler and every app's header back
button all call the hash history's `goBack`, which upstream implements as a
bare `history.go(-1)` with no fallback — it does nothing when the router has
no previous in-app entry.

**v1 (superseded, failed live):** added a depth guard using the history's
internal keys array (`A.indexOf(F.location.key)`) and kept the chunk's original
hashed filename. It never fixed the phone in FiveM because (a) CEF served the
cached old asset under the same filename and (b) the keys-array depth
assumption did not hold for live navigation. Do not re-introduce either.

**v2 (current):** route-aware goBack — at `/` no-op; app root (1 path segment)
→ router push(`/`); nested (2+ segments) → `go(-1)` with a one-shot 120 ms
unchanged-route fallback to home (covers direct-open nested routes with no
usable history).

**Cache-busting (mandatory part of the patch):** the patched chunk is renamed
`__federation_shared_react-router-dom-lifestate-backfix.js` and the single
reference to the old filename in each of
`dist/html/assets/index-ebf41f23.js` and
`dist/html/assets/__federation_fn_import.js` is updated. Never patch a hashed
bundle chunk in place — CEF will keep serving the stale cached asset even
after `restart npwd`.

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
