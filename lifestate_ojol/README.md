# lifestate_ojol

Ojol profession foundation for Lifestate Roleplay (Qbox).

## Phase 3A scope

- Independent driver registration (NOT the Qbox primary job): `ojol_drivers` table keyed by `citizenid`.
- Driver states: **registered** (persistent) / **online** (runtime) / **busy** (runtime, Phase 3B+).
- CEO-managed driver lifecycle: register, fire, promote, demote (server-authoritative commands).
- Pangkalan Ojek dispatcher with PCX160 bike spawn (requires registered + active + online).
- Company account foundation (`ojol_company`), 10% platform fee split helpers.
- NPWD Ojol Driver app (clock in/out, rank, rating, profile photo placeholder).
- App Store persistence schema (`lifestate_phone_apps`, unused yet).

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
`customerRideChanged`, `dutyChanged`, `driverRevoked`.

## Cancellation rules

- Customer cancels: free (Rp0) while searching or before the driver has made meaningful progress.
  Eligibility for the Rp5.000 company-paid driver compensation needs >= 30 s since acceptance **and**
  >= 150 m of movement towards the pickup. The flag is stored on the ride; the transfer is Phase 3C.
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

## Database

Tables are created automatically on resource start (idempotent). Reference schema: `sql/ojol.sql`.

- `ojol_drivers` - persistent registration + ride statistics (PK: `citizenid`).
- `ojol_company` - single-row company balance in integer Rupiah (PK: `id`).
- `ojol_rides` - finalized ride history (PK: `ride_id`; indexes on customer, driver, status, created_at).
- `lifestate_phone_apps` - per-player installed app state for the future App Store (PK: `citizenid`, `app_id`).

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
