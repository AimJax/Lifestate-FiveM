# lifestate_jobs

Generic **Job Management** for the Qbox admin menu. One registry, one service game
menu, N jobs — the admin menu never grows a per-job code path, so hundreds of jobs
and professions stay navigable without touching this resource again.

```
/admin  ->  Job Management  ->  Give | Remove | View Player Jobs | Advanced provider actions
                    |
             lifestate_jobs (this resource)
                    |
        registry  ->  provider definition  ->  job backend
                    |
   Ojol (independent profession)        qbx:police, qbx:mechanic, ... (framework jobs)
```

## Two job types

| Type | Meaning | Example |
| --- | --- | --- |
| `profession` | **Independent** of the framework job. Holding it never changes the player's Qbox primary job, so a police officer or a mechanic can also be an Ojol driver. | `ojol` |
| `framework_job` | The Qbox **primary** job, managed through qbx_core's own API and grades. | `qbx:police` |

Framework jobs are auto-created as `qbx:<jobName>` from `qbx_core:GetJobs()`
(`server/frameworkjobs.lua`), re-synced on every catalog/inspect request and
whenever qbx_core restarts, so a runtime `CreateJob`/`RemoveJob` appears or
disappears with no code change. `config.defaultJob` (`unemployed`) is never
offered, and `blacklist`/`whitelist` can narrow the list.

## Provider contract

A job registers itself once — that is the whole integration:

```lua
exports.lifestate_jobs:RegisterProvider({
    id = 'ojol',                 -- unique; 'qbx:<job>' is reserved for the adapter
    label = 'Ojol',              -- what the menu shows
    type = 'profession',         -- 'profession' | 'framework_job' | your own
    order = 10,                  -- sort hint (framework jobs use 200)
    -- No `resource` field: ownership is resolved by lifestate_jobs from the
    -- invoking resource (see below), so it cannot be declared - or claimed.

    grades = { { level = 0, label = 'Driver' } },   -- optional, or a function
    give   = function(target, options) ... end,     -- optional
    remove = function(target, options) ... end,     -- optional
    inspect = function(target) ... end,             -- optional

    actions = {                  -- optional provider-specific authority actions
        { id = 'setCeo', label = 'Set CEO', confirm = true,
          handler = function(target, options, ctx) ... end },
    },
})
```

Rules the registry enforces (see `server/registry.lua`):

- a malformed definition is **rejected with a reason**, never registered;
- re-registering the same id from the same resource is an idempotent update, so a
  resource restart cannot duplicate a provider;
- a provider id can only be replaced by its owning resource (no hijacking);
- a provider needs at least one of `give`/`remove`, and one action's `handler`
  never leaves the server.

## Ownership and lifecycle

Ownership is resolved at the export boundary (`server/providerapi.lua`) from
`GetInvokingResource()` — the native that names the resource which actually made
the call, and which a caller cannot influence:

| Call | Owner |
| --- | --- |
| `exports.lifestate_jobs:RegisterProvider(def)` | the calling resource |
| `exports.lifestate_jobs:UnregisterProvider(id)` | only the current owner may |

A `resource` field in the definition is ignored (the real owner overwrites it), so
one resource cannot claim another's provider id — `id_conflict` — and there is no
overwrite argument to forge. The registry takes the owner as an explicit parameter
and refuses a registration without one (`owner_required`); framework-job providers
are registered internally by the adapter with the explicit owner `qbx_core`.

Cleanup is ownership-driven: when a resource stops, every provider it owned is
dropped (`onServerResourceStop` -> `registry.UnregisterByResource`), including the
ordered-id cache, so the menu can never hold a stale reference into a resource that
is gone. Stopping `lifestate_ojol` therefore removes the Ojol provider immediately;
stopping `qbx_core` removes the framework-job providers, which the adapter
repopulates on its next start or sync.

A handler returns `success, outcome, detail?`:

- `outcome` is a machine string (`registered`, `reactivated`, `removed`,
  `already_registered`, `not_registered`, `unchanged`, ...). The service turns
  the known ones into readable messages and treats `already_registered`,
  `not_registered` and `unchanged` as **successful no-ops** — a duplicate Give or
  a Remove of something absent is not an error.
- `detail.message` overrides the wording (used for job-specific refusals).

## Service and authorization

`server/service.lua` is the only door to a provider. (The registry is reached only
through `server/providerapi.lua`, which is what makes ownership unspoofable.) For
every entry point it:

1. authorizes the caller server-side (`ACE` from `config.perm`, plus admin duty
   via `qbx_core:IsOptin` when `config.requireOptin`),
2. resolves the client-supplied server id into a real player (`JobProviderTarget`
   with `source`, `citizenid`, `name` and the framework job context),
3. dispatches to the registered provider inside `pcall`, so one broken provider
   cannot break the menu, another provider or the request,
4. audits the outcome (`[lifestate_jobs] audit: ...`) — including every refusal.

`source` is always the real connection, never a client-supplied citizenid. The
menu being visible proves nothing: `RegisterNetEvent('lifestate_jobs:server:openMenu')`
re-checks authorization before it opens anything, and a forged trigger from a
non-admin is denied and audited.

## The admin menu hook

Deliberately tiny: the only qbx_adminmenu change is one option in the main menu
plus one branch that triggers the relay event. It is a third-party edit, so it is
recorded under [`patches/qbx_adminmenu/`](../../../../patches/qbx_adminmenu/README.md).

## Tests

`tests/` runs the real modules with qbx_core, ACE checks and the database stubbed
(see `.freebuff/luacheck/run_specs.mjs`, or any harness that can execute
`tests/run.lua`):

- `registry_spec.lua` — definition validation, explicit ownership, ordering, grades,
  owner-only unregistration and `UnregisterByResource` (including cache invalidation);
- `service_spec.lua` — authorization, target resolution, Give/Remove, provider
  isolation, the generated catalog, View Player Jobs and advanced actions;
- `provider_ownership_spec.lua` — the export boundary: impersonation attempts,
  forged overwrite attempts, owner-only unregister, and resource-stop cleanup;
- `frameworkjobs_spec.lua` — discovery/sync, live grade reads, the qbx_core
  stop/restart lifecycle, and the Qbox `SetJob` / `RemovePlayerFromJob` write paths.

Ojol's side of the contract (provider registration, Give/Remove/CEO semantics,
live phone-app refresh) is proven in
`resources/[lifestate]/lifestate_ojol/tests/jobsprovider_spec.lua`.

## Config

`config/server.lua`: `perm`, `requireOptin`, `defaultJob`, `frameworkJobs`
(`enabled`/`blacklist`/`whitelist`), `showCitizenId`, `listUnregisteredProfessions`,
`categoryThreshold` (above this many providers the picker groups by type first)
and the `audit` toggles.
