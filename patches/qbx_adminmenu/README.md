# qbx_adminmenu patch — the Job Management entry point

## Why this file differs from upstream

Resource: `resources/[qbx]/qbx_adminmenu` (upstream Qbox release, unmodified
otherwise).

The generic Job Management system lives entirely in
`resources/[lifestate]/lifestate_jobs`. The admin menu only needs an entry point
for it: one option in the main menu and one branch that asks the server to open
the section. Everything else — the menu itself, the registry, the provider
contract and every mutation — is owned by `lifestate_jobs`.

Two alternatives were rejected:

- **Copying the menu** would fork the admin menu's styling and behaviour and
  would have to be re-merged on every upstream update.
- **Adding the section to `qbx_adminmenu` itself** would put Ojol/job logic into
  a third-party resource and make every future job an edit there.

So the hook is 5 added lines in one file, and no other file (client or server) is
touched. The permission check is deliberately **not** here: the client option only
triggers `lifestate_jobs:server:openMenu`, and `lifestate_jobs` authorizes the
caller server-side before it opens anything, so a forged client trigger is denied.

## Exact change

File: `client/main.lua` — within the `qbx_adminmenu_main_menu` registration.

In the `options` list, after the Pending Reports entry:

```lua
        -- Lifestate: generic job/profession management (lifestate_jobs owns the
        -- menu, the registry and every mutation; this is the only hook).
        {label = 'Job Management', description = 'Give, remove and inspect player jobs and professions', icon = 'fas fa-briefcase', args = {'qbx_adminmenu_jobs_menu'}}
```

In that menu's select callback, before the final `else`:

```lua
    elseif args[1] == 'qbx_adminmenu_jobs_menu' then
        TriggerServerEvent('lifestate_jobs:server:openMenu')
```

That is the whole patch (`patches/qbx_adminmenu/client-main.patch`).

## Re-applying after an upstream update

1. Open `resources/[qbx]/qbx_adminmenu/client/main.lua`.
2. Re-add the two snippets above: the option inside the
   `qbx_adminmenu_main_menu` `options` table, and the `elseif` branch inside its
   `onSelect` callback.
3. No server-side file, `config/server.lua` entry, locale file or manifest change
   is required.

`lifestate_jobs` registers its own ox_lib menu and section, so a missing hook
degrades to "the entry point is gone" — nothing else in the admin menu changes,
and the `/admin` command keeps working exactly as upstream.

## Verification

`.freebuff/luacheck/negative_check.mjs` fails if the hook is missing, and
`lifestate_jobs/tests/service_spec.lua` proves that the relay event is denied for
a non-admin even if the client event is forged.
