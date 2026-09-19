# Lifestate Independent Profession Template

This disabled resource is a starter, not a playable job. Copy it to a new uniquely named resource before editing. It stays inert under `ensure [lifestate]` because `config/shared.lua` has `enabled = false`.

## Create Job #2

1. Copy this directory and rename the resource and database table.
2. Change `providerId`, `label`, export names, and the three matching functions in `server/adminapi.lua`.
3. Keep `operations` as strings. Never pass Lua functions through `exports.lifestate_jobs:RegisterProvider(...)`.
4. Add the profession's trusted server logic and tests, then set `enabled = true`.
5. Start the copied resource. Job Management discovers it automatically; do not edit `qbx_adminmenu` or `lifestate_jobs/client/main.lua`.

`lifestate_jobs` derives provider ownership from `GetInvokingResource()`. A provider must not claim its own owner.
The template depends on `lifestate_jobs` and re-registers its metadata if that registry resource restarts.

## State model

Persistent rows own registration, soft active/inactive state, level, registration time, and history/statistics. Removal sets `active = 0`; rehire updates the same row, preserving history. Startup reload accepts database booleans `1`, `true`, and `"1"` as true; `0`, `false`, `"0"`, and `nil` are false.

Online/duty, busy, active task, and source mappings are runtime-only. They reset on resource/server restart. Each real profession must explicitly decide whether an interrupted task is recovered or failed.

Run template tests from this directory with `fengari tests/run.lua` (or the project's equivalent Lua runner).
