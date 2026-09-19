# Lifestate FiveM — server side

This repository holds every **custom** Lifestate resource and configuration the
project actively modifies, so the server-side codebase can be audited as a
whole. It is deliberately *not* a mirror of the Qbox server: framework code
(Qbox, ox, NPWD, cfx-default, voice) stays untracked.

## What is tracked

| Path | What it is |
| --- | --- |
| `resources/[lifestate]/lifestate_ojol` | Ojol player ride system (driver registration, matching, rides, payments, App Store backend, dispatcher NPC, admin job API, tests) |
| `resources/[lifestate]/lifestate_jobs` | Generic admin Job Management (provider registry, generic service, Qbox primary-job adapter, tests) |
| `resources/[lifestate]/lifestate_pcx160` | PCX160 bike asset stream for Ojol drivers |
| `resources/[npwd-apps]/npwd_lifestate_ojol` | NPWD Driver app (external federation app) |
| `resources/[npwd-apps]/npwd_lifestate_ojol_customer` | NPWD Customer app (external federation app) |
| `resources/[npwd-apps]/npwd_lifestate_app_store` | NPWD Lifestate App Store (external federation app) |
| `patches/npwd/` | The NPWD bundle patch, with an explanation of exactly what changed |
| `patches/qbx_adminmenu/` | The 5-line admin-menu hook that opens Job Management |
| `patches/examples/` | Sanitized templates of configuration that lives on the server only |

## What is deliberately NOT tracked

- `server.cfg`, `permissions.cfg`, `ox.cfg`, `voice.cfg`, `misc.cfg` and any
  other server configuration — they contain endpoints, keys and admin data.
  `patches/examples/` holds sanitized templates instead.
- Framework/third-party resources: `[qbx]`, `[ox]`, `[npwd]` (except the
  patched file recorded under `patches/npwd/`), `[cfx-default]`, `[standalone]`,
  `[assets]`, `[voice]`.
- `cache/`, logs, crash dumps, database dumps, `node_modules`, editor state.

## Repository layout note

The repository root is `Qbox_A6CBDB.base` (the live server root). The previous
repository — rooted at `resources/[lifestate]` — was grafted into this one as
`resources/[lifestate]` via a subtree-style merge, so the full commit history of
the old `Lifestate-FiveM` repository is preserved and reachable
(`git log --follow resources/[lifestate]`).

## Job Management

Admin job/profession management is generic: `/admin` -> **Job Management** ->
Give / Remove / View Player Jobs / Advanced provider actions. The section, the
registry and every mutation live in `resources/[lifestate]/lifestate_jobs`; a job
becomes available to it with a single `RegisterProvider` call, so future jobs
need no admin-menu change. Ojol registers itself as the first **independent
profession** (it never touches the player's Qbox primary job), and every Qbox job
is exposed automatically as a `framework_job` through qbx_core's own API. See
`resources/[lifestate]/lifestate_jobs/README.md`.

The only third-party edit this needs is the entry point in `qbx_adminmenu`,
recorded under `patches/qbx_adminmenu/`.

## The NPWD patch

NPWD 3.15.1-beta.2 hard-codes its built-in app list and ignores its own
`disabledApps` config key. The Lifestate App Store needs that key to work (it
hides/unlaunches Matchmaker, IRC, Social and Marketplace per character). The
smallest possible patch — three lines in one bundle file — is recorded under
`patches/npwd/` together with the exact upstream context, so it can be
re-applied after any NPWD update. See `patches/npwd/README.md`.
