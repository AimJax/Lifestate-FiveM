# Lifestate Ojol Phase 3C Repair Design

Date: 2026-09-16
Status: Approved architecture; implementation pending
Scope: Repair only the confirmed Phase 3C audit defects

## Goals and boundaries

Make lifecycle mutations mutually exclusive per ride; make payment and compensation progress durable and diagnosable; restore terminal cleanup, availability, blips, rating recovery, and offer authorization; preserve Phase 3A/3B behavior and current public interfaces where possible.

No Phase 3D/App Store work, automatic reconciliation worker, destructive table recreation, unrelated UI redesign, or GitHub push.

## Lifecycle lock

`server/rides.lua` remains the sole ride-state owner. A synchronous `RideLocks[rideId]` guard covers completion, both cancellations, after-pickup reopen, disconnect, and firing.

- A held lock returns `ride_busy`; callers never wait.
- The guarded callback runs through protected execution.
- Every success, validation failure, dependency failure, and exception releases the lock.
- Internal mutation helpers assume the caller owns the lock, avoiding nested acquisition.
- Each operation re-reads ride state and actor ownership after acquiring the lock.

## Idempotent terminalization

One function owns terminal transitions; callers never pre-set a terminal status. It conditionally persists the final result, applies one-time completion statistics transactionally, sets runtime state, notifies customer and former driver, stops timers/search, retracts offers, clears mappings/busy state, removes the live ride, and republishes the former driver's online availability.

A persisted terminalization marker/result prevents repeated cleanup, statistics, payment, or notifications. Re-entry returns the existing result safely.

## Offer authorization

`matching.AcceptOffer` requires `DriverOffers[citizenid][rideId] == true`, a still-searching ride, and current eligibility: connected, registered, online, free, not the customer, off cooldown, and within the active search-tier radius. A supplied known ride ID without an offer returns `not_offered`.

## Durable money ledger

Add one ledger row per stable action identity:

- `ride:<rideId>:fare`
- `ride:<rideId>:compensation`

The ledger records ride/action, overall status (`pending`, `processing`, `paid`, `rolled_back`, `failed`, `needs_reconciliation`), method and locked amounts, customer/driver/company step states, rollback states, current or failed step, reason, and timestamps.

For each external wallet/company operation:

1. Persist `<step>_processing` before the call.
2. Execute the operation once.
3. Persist `<step>_applied` after confirmed success.
4. If restart finds a step in `processing`, mark the ledger `needs_reconciliation`; never replay it automatically.

Reconciliation logs include ride ID, ledger ID, failed step, and reason, but no unnecessary private identifiers.

## Rollback and idempotency

Fare order remains customer debit, driver credit, company credit. Confirmed failure reverses applied steps in reverse order, persisting rollback intent and confirmation and checking every return value.

- Fully confirmed rollback becomes `rolled_back` and payment returns to retryable `pending`.
- Any failed or ambiguous rollback becomes `needs_reconciliation` and blocks retries.
- A paid ledger returns success without moving money again.
- Failures before/after paid confirmation use the same verified rollback or quarantine path.

This cannot remove the external-wallet/SQL crash window, but it makes ambiguity explicit and non-replayable.

## Compensation

Compensation uses the same ledger pattern. Company debit and driver bank credit are separate durable steps. Driver statistics increment only after confirmed delivery. Confirmed driver-credit failure triggers verified company rollback; ambiguous delivery or rollback becomes `needs_reconciliation`. Offline credit is accepted only when Qbox confirms success. Replays of a paid ledger return safely.

## After-pickup recovery

The transition model explicitly permits a locked after-pickup reopen into `SEARCHING`.

Manual driver cancellation charges no fare, increments `cancelled_after_pickup` once, creates the five-minute pair cooldown, releases/notifies the old driver, obtains a road-snapped pickup from the connected customer client, validates that snap against the real server ped and configured radius, preserves destination/payment method, recalculates remaining quote, persists, and restarts matching.

Disconnect/firing uses the same reopen without voluntary statistics or cooldown. If a safe snap cannot be obtained, the ride follows an explicit failure terminal path rather than accepting raw coordinates.

## Customer cancellation

Customer cancellation is allowed before and after pickup while unpaid. Customer charge and normal fare payout remain zero; compensation eligibility is evaluated server-side; common terminalization performs cleanup. Customer disconnect uses the same semantics.

## Rating and reopen recovery

Rating uses one DB transaction: verify completed ownership, insert the one-per-ride rating, and update `rating_sum`/`rating_count`. Duplicate primary key returns `already_rated`; aggregate failure rolls back the insert.

A read-only callback returns the customer's latest completed unrated ride reconstructed from persistence. The customer app requests it when no live ride exists, preserving the rating screen across phone reopen without keeping completed rides active.

## Client cleanup

Every terminal/reassignment path notifies both affected parties before discarding ownership. The former driver receives terminal or cleared active state; the customer receives unassigned `SEARCHING` during rematch or terminal state during closure. The customer marker clears for absent, terminal, or unassigned-searching state. Existing resource-stop cleanup remains. NPWD shell layouts remain unchanged.

## Company balance

Remove the mutable balance cache. Keep atomic SQL increments and query the authoritative low-frequency balance after changes.

## Backward-safe migrations

Runtime bootstrap remains authoritative and additive/compatible only: no drops, truncation, or table recreation. Existing Phase 3C fields remain. Add terminalization metadata, the durable ledger and indexes, and fields needed for completed-unrated recovery. Preserve the signed `BIGINT` migration and synchronize `sql/ojol.sql`.

Startup quarantines step-level `processing` ledgers as `needs_reconciliation`, logs the required identifiers/reason, and performs no wallet retry.

## Test strategy

A deterministic Lua harness loads the real production modules with controlled FiveM, Qbox, timer, client-event, and MySQL boundaries. Each regression is written and observed failing before production changes.

Coverage includes offered/non-offered/two-driver acceptance; successful and repeated completion; completion races with customer/driver cancellation, disconnect, and firing; cash/bank failures before and after every money step, rollback, and DB confirmation; after-pickup manual/disconnect rematching; after-pickup customer cancellation; compensation failure/replay; rating duplicate/aggregate rollback; completed-unrated reopen; all blip cleanup paths; and concurrent company balance adjustments.

Frontend builds, generated chunks, and callable federation configs are verified after the Lua suite. Changed Phase 3A/3B paths are included in regression coverage.

## Known operational limitation

An external wallet call interrupted between execution and SQL confirmation is inherently ambiguous without Qbox-native idempotency. Such rows are quarantined for manual/admin reconciliation and never automatically retried. Reconciliation tooling itself is intentionally deferred.
