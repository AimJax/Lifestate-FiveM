return {
    location = vec4(462.22, -641.15, 28.45, 175.0),

    dispatcherLocation = vec4(450.91, -636.37, 28.52, 269.62),

    -- Dispatcher ped lifecycle tracing (client/dispatcher.lua). Set to false once
    -- the NPC is confirmed in game; failure logs are printed either way.
    dispatcherDebug = true,

    vehicleSpawnLocation = vec4(456.24, -637.95, 27.5, 222.2),

    -- Maximum CEO <-> target distance for /daftarojol and /pecatojol.
    -- Validated server-side against real player ped coordinates.
    maxRegistrationDistance = 3.0,

    -- Road snapping tolerances (metres, horizontal).
    -- The client resolves the nearest vehicle-path node (asphalt/dirt/gravel); the
    -- server re-validates the proposed pickup against the real ped position, so a
    -- client can never move its own pickup point somewhere else on the map.
    maxPickupSnapMeters = 75.0,
    maxDestinationSnapMeters = 150.0,

    -- Ride blip configuration (client side).
    blipSpritePickup = 280,
    blipColourPickup = 5,
    blipSpriteDestination = 501,
    blipColourDestination = 2,

    -- Live driver marker on the customer's map (server-streamed position).
    blipSpriteDriver = 470,
    blipColourDriver = 5,
}
