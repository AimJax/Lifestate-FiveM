# Phase 3C Repair Implementation Plan

Date: 2026-09-17
Design: `docs/superpowers/specs/2026-09-16-phase-3c-repair-design.md`
Execution: test-first in the live `[lifestate]` checkout; no server.cfg, NPWD federation, PCX, Phase 3D, or GitHub push changes.

## Invariants

- One non-waiting lifecycle lock per ride; every exit releases it.
- `TerminalizeRide(..., COMPLETED)` independently requires a durable fare ledger in `paid` state.
- Ledger IDs are stable: `ride:<rideId>:fare` and `ride:<rideId>:compensation`.
- A wallet step is persisted as `processing` before its call and `applied` after confirmed success.
- A recovered `processing` step is ambiguous: quarantine as `needs_reconciliation`; never retry it automatically.
- If every required fare step is durably `applied`, only the DB-only `paid` finalization may be retried. Wallets are never replayed or rolled back merely because that final update failed.
- Terminalization re-entry returns the stored result and repeats no cleanup, stats, money, or notifications.
- Schema changes are additive and safe for the current live tables.

## Task 1: Add a production-module Lua test harness

Files:
- Add `lifestate_ojol/tests/harness.lua`
- Add `lifestate_ojol/tests/run.lua`

Steps:
1. Obtain a temporary Lua 5.4-compatible runner outside the resource if no installed runner exists; do not add a runtime dependency to the server resource.
2. Build a small assertion runner that clears `package.loaded`, injects controlled `package.preload` modules, and stubs FiveM globals, Qbox players, events, timers, and MySQL await calls.
3. Load the real `server.*` modules rather than copied logic.
4. Run the empty harness and retain one command that executes the whole suite.

## Task 2: Lock lifecycle operations and authorize offers

Files:
- Modify `lifestate_ojol/server/rides.lua`
- Modify `lifestate_ojol/server/matching.lua`
- Add `lifestate_ojol/tests/lifecycle_spec.lua`

Failing tests first:
- a driver without `DriverOffers[driver][rideId]` receives `not_offered`;
- an offered driver outside the current tier radius is rejected;
- only one of two offered drivers can accept;
- concurrent completion/cancel/drop/fire attempts return `ride_busy` or the existing terminal result;
- the lock releases after dependency failure and thrown error.

Implementation:
- Add `RideLocks` and one protected, non-waiting `WithRideLock(rideId, fn)` entry point.
- Move completion, customer/driver cancellation, disconnect, and firing mutations behind the lock without nested acquisition.
- Require the stored offer and pass `currentRadius(rideId)` to the existing eligibility function.

## Task 3: Add the backward-safe durable ledger

Files:
- Modify `lifestate_ojol/server/database.lua`
- Modify `lifestate_ojol/sql/ojol.sql`
- Add `lifestate_ojol/tests/database_spec.lua`

Failing tests first:
- schema bootstrap creates the ledger with no drop/truncate/recreate;
- stable ledger insertion is idempotent;
- conditional step/status transitions reject stale states;
- rating insert plus aggregate update is one transaction;
- startup recovery quarantines ambiguous `processing` steps and exposes all-`applied` fare rows for DB-only finalization.

Implementation:
- Add `ojol_money_ledger` keyed by `ledger_id`, with ride/action, locked amounts/method, overall status, per-step states, rollback states, failed step/reason, and timestamps.
- Add terminal metadata to `ojol_rides` only where missing and make finalization conditional/idempotent.
- Add focused DB functions: ensure/fetch ledger, conditional step update, mark reconciliation, mark paid, fetch completed-unrated, transactional rating, fetch terminal result.
- Log reconciliation with only ride ID, ledger ID, failed step, and reason.

## Task 4: Make fare payment crash-visible and idempotent

Files:
- Modify `lifestate_ojol/server/payments.lua`
- Modify `lifestate_ojol/server/rides.lua`
- Add `lifestate_ojol/tests/payment_spec.lua`

Failing tests first, for both cash and bank where relevant:
- failure before customer debit;
- crash/failure after customer debit but before durable confirmation;
- failure after driver credit;
- failure after company credit;
- failure during each reverse operation;
- failure immediately before and after overall DB confirmation;
- repeat calls never duplicate debit/credit/company movement;
- all steps `applied` plus failed `paid` update performs no rollback and is quarantined for DB-only finalization;
- a recovered `processing` step is quarantined and never replayed.

Implementation:
- Replace the ride-row payment claim with the stable fare ledger.
- Persist each step intent/result and verify every compensating call.
- Roll back confirmed partial failures in reverse order; quarantine any ambiguous or failed rollback.
- When all required steps are `applied`, retry only `MarkLedgerPaid`; never touch wallets.
- Make `TryCompleteRide` call payment, then call terminalization; make terminalization itself re-fetch and require ledger `paid`.

## Task 5: Make terminalization idempotent

Files:
- Modify `lifestate_ojol/server/rides.lua`
- Modify `lifestate_ojol/server/database.lua`
- Extend `lifestate_ojol/tests/lifecycle_spec.lua`

Failing tests first:
- successful completion persists once, increments stats once, clears both mappings, publishes both client states, and frees the driver;
- repeated completion returns the same final result without payment, stats, cleanup, or notification repetition;
- `COMPLETED` fails when fare ledger is not `paid`;
- cancellation/drop/fire races cannot overwrite a terminal result.

Implementation:
- Replace the pre-set-status/`closeRide` split with one `TerminalizeRide` owner.
- Persist the terminal result first with a conditional DB update, then perform one-time runtime cleanup and notifications.
- Return the stored terminal result on re-entry.

## Task 6: Repair compensation accounting

Files:
- Modify `lifestate_ojol/server/payments.lua`
- Modify `lifestate_ojol/server/rides.lua`
- Extend `lifestate_ojol/tests/payment_spec.lua`

Failing tests first:
- failure before company debit;
- failure after company debit and before durable confirmation;
- failure after driver credit;
- failure during company rollback;
- failure before/after overall DB confirmation;
- compensation stats increment only after a paid ledger;
- replay never duplicates movement.

Implementation:
- Use the stable compensation ledger and the same processing/applied/rollback rules.
- Verify online/offline Qbox credit return values.
- Increment compensation statistics only in the durable paid-finalization path.

## Task 7: Repair after-pickup recovery and cancellation

Files:
- Modify `lifestate_ojol/server/rides.lua`
- Modify `lifestate_ojol/client/customer.lua`
- Modify `lifestate_ojol/server/main.lua`
- Extend `lifestate_ojol/tests/lifecycle_spec.lua`

Failing tests first:
- voluntary after-pickup driver cancellation adds one stat and pair cooldown, requests a road snap, validates it, recalculates, and rematches;
- disconnect/firing rematches without voluntary stat/cooldown;
- unsafe or missing snap follows the explicit failure terminal path;
- customer cancellation after pickup charges no fare and uses normal compensation eligibility.

Implementation:
- Permit `ENROUTE_DESTINATION -> SEARCHING` only through the locked recovery path.
- Add a customer callback/event for the existing road-snap helper, then validate its distance from the server-observed ped.
- Preserve destination/payment method and restart matching with the recalculated quote.

## Task 8: Make rating atomic and recover completed-unrated rides

Files:
- Modify `lifestate_ojol/server/database.lua`
- Modify `lifestate_ojol/server/rides.lua`
- Modify `lifestate_ojol/server/main.lua`
- Modify `npwd_lifestate_ojol_customer/client/client.lua`
- Modify the customer NPWD source component that loads ride state
- Add `lifestate_ojol/tests/rating_spec.lua`

Failing tests first:
- duplicate rating returns `already_rated`;
- aggregate failure rolls back the rating insert;
- a completed unrated ride is returned after the live ride has been detached;
- an already-rated or foreign ride is not returned.

Implementation:
- Use one MySQL transaction for insert plus aggregate.
- Add the read-only completed-unrated callback and bridge it through the existing customer NUI request flow.

## Task 9: Repair client cleanup and authoritative company balance

Files:
- Modify `lifestate_ojol/client/customer.lua`
- Modify `lifestate_ojol/client/driver.lua` only if its existing nil handler is insufficient
- Modify `lifestate_ojol/server/company.lua`
- Extend lifecycle and payment tests

Failing tests first:
- customer driver blip clears for nil, terminal, and unassigned `SEARCHING` views;
- former driver receives cleared state on terminalization/reassignment;
- concurrent company adjustments return the DB-authoritative balance without a stale mutable cache.

Implementation:
- Extend the existing cleanup predicates and notifications.
- Remove the mutable company balance cache; retain atomic SQL adjustment and read authoritative balance on low-frequency requests.

## Task 10: Regression and artifact verification

Files:
- Rebuild only NPWD resources whose source changed.

Steps:
1. Run the complete Lua production-module suite, including every required failure injection.
2. Run syntax/load checks over all changed Lua modules.
3. Build changed NPWD resources with their existing Vite/federation setup.
4. Verify generated `remoteEntry.js` remains federation-generated and each config default export remains callable.
5. Re-read every changed production file, schema file, and generated artifact.
6. Inspect the final diff for unrelated changes and secrets.
7. Report tests, builds, changed files, migrations, reconciliation behavior, and any live-server validation still requiring the user. Do not push to GitHub.
