return {
    -- PCX160 bike spawn authorization (server-side only)
    allowedVehicles = {
        {
            model = `pcx160`
        }
    },

    -- Fare constants. Integer Rupiah only; the customer never supplies a fare.
    -- GTA map distances are compressed vs real-world trips, so pricing is set
    -- for map scale: fare = max(20000, 12000 + 8000 * distanceKm).
    baseFare = 12000,         -- Rp12.000 base fare
    perKilometer = 8000,      -- Rp8.000 per kilometer
    minimumFare = 20000,      -- Rp20.000 minimum fare
    platformFeePercent = 10,  -- company keeps 10% of every fare

    -- Route distance modelling.
    -- FiveM has no server-side road pathfinding, so the fare distance is the
    -- map distance (pickup -> destination) multiplied by this documented factor.
    -- Deterministic, cheap, and identical for every client.
    roadDistanceMultiplier = 1.3,

    -- Customer-cancellation compensation (Rp5.000 from the company).
    -- Compensation only becomes *eligible* in Phase 3B; the actual transfer is
    -- Phase 3C (no money moves before ride completion exists).
    cancelCustomerFee = 0,                  -- customer pays nothing on cancel
    cancelDriverCompensation = 5000,        -- eligible driver gets Rp5.000 from company
    cancelCompensationAfterSeconds = 30,    -- min seconds after acceptance
    cancelCompensationMinMovementMeters = 150, -- driver must have closed 150m toward pickup

    -- Hidden per (driver, customer) cooldown after a driver cancels a ride.
    -- Server-side only; during cooldown that customer's orders are not offered
    -- to that driver. No timer is ever shown to a player.
    cancelPairCooldownSeconds = 300,

    -- Ride request validation
    minRideDistanceMeters = 150,        -- reject trivially-identical trips
    maxRideDistanceMeters = 25000,      -- sanity bound on a locked fare distance

    -- Progressive matching radius. Tier 1 is used when the request is created,
    -- then the radius expands every `tierExpansionMs` while still SEARCHING.
    -- Tiers are milliseconds-free: plain metres, evaluated in order.
    searchRadiusTiers = { 2000, 4000, 7000, 20000 },
    tierExpansionMs = 10000,

    -- Lightweight anti-spam limits for ride actions (milliseconds, per player).
    createRideCooldownMs = 3000,
    acceptRideCooldownMs = 750,
    cancelRideCooldownMs = 1500,
    tripActionCooldownMs = 1500,

    -- Phase 3C in-trip radii (metres). All proximity is computed from the real
    -- server-side peds; clients never supply coordinates for these checks.
    arrivalRadiusMeters = 30,       -- driver -> pickup at SAYA SUDAH SAMPAI
    boardingRadiusMeters = 8,       -- fallback customer proximity at boarding
    destinationRadiusMeters = 40,   -- driver -> destination at SELESAIKAN

    -- Customer's live driver marker: one re-arming timer per assigned ride,
    -- destroyed immediately when the ride stops being active.
    driverLocationStreamMs = 2500,

    -- Bound on the client round trip that resolves an after-pickup recovery
    -- pickup (road nodes exist only on the client). The ride's lifecycle lock is
    -- only ever held for at most this long, so an unresponsive client can delay
    -- that one ride - never wedge it. On expiry the recovery fails safely
    -- instead of falling back to untrusted coordinates.
    roadSnapTimeoutMs = 3000,
}
