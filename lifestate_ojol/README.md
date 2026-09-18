# lifestate_ojol

Ojol profession foundation for Lifestate Roleplay (Qbox).

## Phase 3A scope

- Independent driver registration (NOT the Qbox primary job): `ojol_drivers` table keyed by `citizenid`.
- Driver states: **registered** (persistent) / **online** (runtime) / **busy** (runtime, Phase 3B+).
- CEO-managed driver lifecycle: register, fire, promote, demote (server-authoritative commands).
- Pangkalan Ojek dispatcher with PCX160 bike spawn (requires registered + active + online).
- Company account foundation (`ojol_company`), 10% platform fee split helpers.
- NPWD Ojol Driver app (clock in/out, rank, rating, profile photo placeholder).
- Lifestate App Store (separate NPWD app) with per-character install state in `lifestate_phone_apps`.

## Phase 3B scope (player-to-player rides)

- Customer NPWD app (`npwd_lifestate_ojol_customer`) + driver ride UI in `npwd_lifestate_ojol`.
- Road-snapped pickup, waypoint destination, server-computed fare, cash/transfer payment selection.
- Progressive-radius matching (2 km -> 4 km -> 7 km -> 12 km), fastest accept wins.
- Server-authoritative ride state machine, cancellations, hidden driver/customer cooldown.
- Ride history persisted in `ojol_rides`; live state stays in server memory.

Payment transfer, pickup confirmation and rating submission remain Phase 3C. Phase 3B records
cancellation compensation *eligibility* but moves no money.

## Ride architecture

| Module | Responsibility |
| --- | --- |
| `server/rides.lua` | Ride lifecycle: create, assign, cancel, terminal states, persistence, client views. |
| `server/matching.lua` | Eligibility, offers, search-radius tiers, declines, pair cooldowns. |
| `server/fares.lua` | Integer-Rupiah fare/distance math and the 90/10 split. |
| `server/vehicles.lua` | Server-authoritative work-bike ownership. |
| `server/drivers.lua` | Driver registry, runtime online/busy state, rank lifecycle. |
| `server/company.lua` | Company balance and fare split helpers. |
| `server/database.lua` | Schema bootstrap plus every query. |

Rides and matching are decoupled through server events (`rideSearching`, `rideAssigned`,
`rideClosed`, `driverAvailabilityChanged`), so `matching` requires `rides` and never the reverse.

Runtime registries: `rides.ActiveRides`, `rides.CustomerActiveRide`, `rides.DriverActiveRide`,
`matching.DriverOffers`, `matching.RideOffers`, `matching.Cooldowns`. The database only records
creation, acceptance and the final outcome.

### Ride states

`SEARCHING -> ACCEPTED -> DRIVER_ENROUTE -> DRIVER_ARRIVED -> PASSENGER_ONBOARD ->
ENROUTE_DESTINATION -> COMPLETED`, plus `CANCELLED_CUSTOMER`, `CANCELLED_DRIVER` and `FAILED`.
Every change goes through `rides.SetStatus`, which enforces a strict transition table, so no client
or code path can jump straight to a terminal state.

## Server callbacks (NPWD apps)

| Callback | Used by |
| --- | --- |
| `lifestate_ojol:server:getDriverState` / `setDriverDuty` | Driver app (clock in/out). |
| `lifestate_ojol:server:getRideQuote` | Customer app fare preview. |
| `lifestate_ojol:server:createRideRequest` / `cancelCustomerRide` / `getCustomerRideState` | Customer app. |
| `lifestate_ojol:server:acceptRideOffer` / `rejectRideOffer` / `cancelDriverRide` / `getDriverRideState` | Driver app. |

Server-pushed client events: `driverStateChanged`, `driverOfferChanged`, `driverRideChanged`,
`customerRideChanged`, `dutyChanged`, `driverRevoked`, `phoneAppsChanged`.

## Dispatcher ped

`client/dispatcher.lua` owns the Pangkalan Ojek ped (model, placement, invincibility, clipboard
scenario, ox_target entry); `client/main.lua` only injects what "Ambil Motor" does.

`Ensure()` is idempotent and self-healing. A ped handle is only trusted when the entity exists,
is alive **and** still carries the loaded model - a ped created before the model streamed exists
but is invisible, and treating that as success is what used to lose the NPC for the whole session.
It is re-ensured on resource start, on `QBCore:Client:OnPlayerLoaded`, when `ox_target` restarts, and
thereafter by a single 15 s watchdog (the only way to notice a local deletion - there is no
entity-deletion event). No per-frame loops.

### Two traps that keep this ped invisible

1. **`type(vec4(...))` is `'vector4'`, never `'table'`.** Validating the config with
   `type(coords) ~= 'table'` rejects the real `dispatcherLocation` and aborts every spawn attempt.
   Coordinate containers are therefore validated by field (`x`/`y`/`z`/`w`), which accepts vectors,
   userdata and plain tables alike. This install proves the rule in ox_lib's `points`/`zones`,
   `qbx_teleports`, `qbx_core` and in `client/customer.lua` here.
2. **`lib.requestModel` returns the model hash and RAISES on timeout** (ox_lib
   `streamingRequest` -> `waitFor` -> `return error(...)`); it never returns `nil`. `not <hash>` is
   always false, so the return value is not a usable success signal, and an uncaught error would
   kill the ensure/watchdog thread for good. It runs under `pcall` and the outcome is confirmed with
   `HasModelLoaded`.

The ped is created at exactly the configured coordinates: no `z` offset and no ground correction.

### Diagnosing it

`dispatcherDebug` in `config/shared.lua` (default `true`) prints the lifecycle trace: module
`Start()`, each trigger, watchdog arm/first tick, and ped creation with handle, model and the live
coords read back from the entity. Set it to `false` once the NPC is confirmed in game - failures are
logged either way, once per distinct reason.

Two admin-only commands exist for live checks (`IsPlayerAceAllowed(..., 'admin')`):
`/ojoldebugped` prints started/handle/exists/model/dead/target/position/configured/ticks and the last
failure, and `/ojolrespawnped` deletes and re-creates the ped once. Both are client-local and can be
removed once the dispatcher is trusted.

## Lifestate App Store

The Ojol apps are **installable, never preinstalled**. Two facts drive the home screen:

| | Meaning |
| --- | --- |
| installed | persistent, per character (`lifestate_phone_apps`) |
| eligible | server predicate; the Driver app also needs an active driver registration |

An app is visible when it is installed **and** eligible. Firing a driver therefore hides the Driver
app immediately (eligibility drops, and the install row is cleared so a rehire restores the right to
install, not the installation). The App Store itself is always present.

NPWD 3.15.1-beta.2 has no per-player app registration: the UI renders the home grid from
`config.apps` in `npwd/config.json`, fetched on mount, and offers no registration API or installed-app
hook. `server/phoneapps.lua` therefore returns that same config with a per-character `apps` list, and
`client/phoneapps.lua` hands it to NPWD's own export:

```lua
exports.npwd:sendNPWDMessage('PHONE', 'npwd:setPhoneConfig', config)
```

That replaces the config atom the phone renders from, so an uninstalled app is neither shown nor
routed - it is not CSS-hidden. NPWD core is untouched; the export and the message shape were verified
against this install's `dist` bundles. Visibility is re-applied on character load, when `npwd`
restarts, when the phone opens, and whenever the server pushes `phoneAppsChanged`.

`npwd/config.json` lists only `npwd_qbx_mail`, `npwd_qbx_garages` and `npwd_lifestate_app_store`;
managed ids are also stripped out of the base list at runtime, so config.json cannot re-preinstall
them. Driver eligibility is enforced in `phoneapps.IsEligible` - never from the client.

## Cancellation rules

- Customer cancels: free (Rp0) while searching or before the driver has made meaningful progress.
  Eligibility for the Rp5.000 company-paid driver compensation needs >= 30 s since acceptance **and**
  >= 150 m of movement towards the pickup. The transfer runs only after the cancellation is durably
  recorded, and the ride's money ledger makes it once-only.
- Driver cancels before pickup: the ride reopens unchanged (same id, pickup, destination, fare and
  payment method) and rematching starts; the driver takes the cancel statistic and a hidden 5-minute
  cooldown against that customer. Cooldowns expire lazily - no cleanup loop.
- Disconnect and firing both reuse the driver-release path, so a customer's request is never stranded.

### Cancellation reasons

Every release carries a closed, explicit origin, because statistics semantics depend on it:

| Origin | Set by | `cancelled_*` stat | Pair cooldown |
| --- | --- | --- | --- |
| `manual_driver_cancel` | the driver's own cancel action | **increments** | **created** |
| `driver_disconnect` | `playerDropped` (crash, timeout, alt-F4) | no | no |
| `driver_fired` | `driverFired` (CEO action) | no | no |
| `server_failure` | `RecoverOnStartup` after a stop/restart | no | no |

Only a voluntary cancellation may affect a driver's performance record or matchmaking, so an outage
or a drop never counts against them. Rematching is identical for every origin: the customer's request
reopens on the same ride and the driver is freed (`rides.DriverCancel(..., origin)`, with
`matching` re-checking the origin before it creates a cooldown).

## Consistency, locking and retry guarantees

Three rules keep the runtime and the database from ever disagreeing, and keep a failed money
operation retryable instead of stuck.

**One lifecycle lock per ride.** Acceptance, cancellation and completion all run through
`rides.WithRideLock`. There is no separate accept lock, so an accept can never land while a
cancellation owns the ride (it is refused with `ride_busy`) and two accepts can never both win.
Every precondition is re-checked inside the lock.

**Persistence first, runtime second.** Anything that changes who owns a ride writes the database
before it touches runtime state:

- acceptance persists the winning driver first, as a database-side compare-and-set: `db.AcceptRide`
  only matches a still-`SEARCHING`, still-unassigned row. A failed write aborts the accept with
  `database_error`; a CAS that matches nothing (`affectedRows = 0`) is *never* treated as a
  successful repeat - the persisted row is re-read and the accept is refused with
  `order_already_taken` (adopting the terminal row) or `stale_assignment`. Neither path assigns a
  driver, sets `busy`, starts a location stream or fires `rideAssigned`;
- a driver release persists the reopen (plain, or recalculated after an after-pickup abandon) first;
  a refused write aborts the cancel and changes nothing - no statistic, no cooldown, no rematch;
- when a write that should have moved the row instead affects nothing, the persisted status is
  re-read and adopted (`rides.AdoptPersistedTerminalState`), so a row the database considers closed
  is never left alive in memory.

**Money ledgers are retry-safe.** A payment attempt that failed cleanly (nothing moved) or was fully
rolled back is returned to a runnable state by `db.ResetMoneyLedgerForRetry` before the next
attempt, so a customer who tops up can complete the same ride. The reset is a single guarded
statement and refuses - quarantining the ledger as `needs_reconciliation` instead - whenever any
step is still `processing` (the write was lost and money may have moved) or a forward step is
`applied` without its rollback confirmed. `payments.ResetFareLedgerForRetry` /
`ResetCompensationLedgerForRetry` expose it. Replays never double-charge: the ledger's affected-rows
count is the idempotency guard, and a ride only becomes `COMPLETED` once its fare ledger is `paid`.

**The road-snap round trip is bounded.** Resolving an after-pickup recovery pickup needs a client
(the road-node natives exist only there), so `server/roadsnap.lua` issues a one-shot request with a
deadline (`serverConfig.roadSnapTimeoutMs`) and a single promise. It settles on exactly one of the
answer, the deadline (`road_snap_timeout`) or the customer dropping (`customer_offline`), so the
ride's lifecycle lock can never be held longer than that: an unresponsive client can delay one ride
but never wedge it. The answer is only ever a *candidate* - the point must be finite and inside the
map, and within `config.shared.maxPickupSnapMeters` of the position the server itself reads for that
ped, re-read after the round trip. There is deliberately **no fallback to the raw ped coordinate**: a
recovery that cannot obtain a trustworthy road point closes the ride as `FAILED` rather than
restarting it from an untrusted position. Late, duplicate and spoofed answers are ignored (a settled
request leaves the pending table, the reply must come from the source it was sent to, and its
request id must still be in flight); in-flight requests are dropped on `playerDropped` and at
resource stop.

**A completion result is confirmed against storage.** `db.FinalizeRide` for `COMPLETED` runs in a SQL
transaction, and a committed transaction is not the same thing as a moved row: both statements carry
the `status NOT IN (terminal)` guard, so a ride somebody else already closed commits while affecting
nothing. The persisted status is therefore read back and the call reports `0` unless the row really
is `COMPLETED` - otherwise the caller would finalize the runtime ride while storage says the customer
cancelled. An identical repeat (the row is already `COMPLETED`) still reports `1`, so re-entry stays
idempotent.

Road-snapped recovery points are still proposed by the customer's client (CfxLua exposes road nodes
only on the client) but must be sane and within `maxPickupSnapMeters` of the position the server
itself sees for that ped. There is deliberately no fallback to the raw ped coordinate: if no
trustworthy road point exists, the recovery fails and the ride is closed instead.

## Database

Tables are created automatically on resource start (idempotent). Reference schema: `sql/ojol.sql`.

- `ojol_drivers` - persistent registration + ride statistics (PK: `citizenid`).
- `ojol_company` - single-row company balance in integer Rupiah (PK: `id`). Negative balances are
  allowed by design: owed compensation is paid rather than blocked (signed `BIGINT` migration).
- `ojol_rides` - finalized ride history (PK: `ride_id`; indexes on customer, driver, status, created_at).
- `ojol_ratings` - one rating per completed ride (PK: `ride_id`).
- `ojol_money_ledger` - durable per-ride fare/compensation ledger (PK: `ledger_id`; indexes on
  `ride_id`, `status`). `status` is `pending` / `processing` / `failed` / `rolled_back` / `paid` /
  `needs_reconciliation`.
- `lifestate_phone_apps` - per-character installed app state for the App Store (PK: `citizenid`, `app_id`).

Live ride state is never written per tick; only creation, acceptance and the terminal outcome.

## CEO management commands (temporary, V1)

| Command | Description |
| --- | --- |
| `/daftarojol [serverId]` | Register a nearby player as Ojol driver (max 3 m, server-validated). |
| `/pecatojol [serverId]` | Fire a nearby registered driver (soft deactivation, see below). |
| `/promoteojol [serverId]` | Promote: driver -> senior_driver -> supervisor. |
| `/demoteojol [serverId]` | Demote: supervisor -> senior_driver -> driver. |

CEO rank itself is assigned admin-side via `exports.lifestate_ojol:assignCEO(citizenid, reason)`.

## Fire / rehire semantics

Firing is a **soft deactivation**, never a delete:

- `/pecatojol` sets `active = 0` on the existing row. Profile photo, registration info, rank history,
  ratings, ride statistics and earnings are all preserved permanently.
- Runtime authorization is revoked immediately (online, busy/available, tracked work bike), and
  `lifestate_ojol:server:driverFired` fires so future ride/offer code can invalidate pending state.
- `RegisterDriver` reactivates the same row for a former driver (`reactivated` outcome) instead of
  creating a new identity. Rank resets to `driver` on rehire; an existing `ceo` record is never lowered.

## Bike ownership (server-authoritative)

`server/vehicles.lua` guarantees **at most one valid Ojol bike per driver**, keyed by `citizenid`
(never by connection source), so invoking the spawn callback directly or repeatedly cannot produce a
second bike. Spawns are denied while a tracked bike is alive; stale tracking (deleted or destroyed
entity) is cleared in place, letting the driver receive a replacement. Ownership is stamped onto the
entity as a state bag, so a one-shot startup scan re-adopts bikes that survive a resource restart and
destroys duplicates. Cleanup happens on fire, `playerDropped` and restart - no polling loops.

The client-side guard remains for UX only; the server is the authority.

## Exports

```lua
-- Server: CEO/admin management
local ok, err = exports.lifestate_ojol:assignCEO(citizenid, reason)

-- Client: waypoint + road-snapped ride endpoints (used by the customer app)
local locations = exports.lifestate_ojol:GetSnappedRideLocations()
-- -> { success = true, pickup = vec3, pickupHeading = number, destination = vec3 }
-- -> { success = false, reason = 'no_waypoint' | 'destination_not_on_road' | ... }

-- Server events
TriggerEvent('lifestate_ojol:server:driverFired', citizenid) -- fired when a driver is fired

-- Company economy (server/company.lua): AddCompanyFunds, RemoveCompanyFunds,
-- GetCompanyBalance, SplitFare
```

## Dependencies

`qbx_core`, `ox_lib`, `oxmysql`, `ox_target`
