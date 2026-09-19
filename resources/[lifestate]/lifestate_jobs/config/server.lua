---@class JobAdminConfig
return {
    -- ACE permission required for EVERY job-management read and mutation.
    -- Server-side only: the menu being visible proves nothing.
    -- The Qbox admin menu uses 'mod' to open /admin and 'admin' for player-data
    -- mutations, so job changes match the stricter of the two.
    perm = 'admin',

    -- Mirror /admin: mutations also require admin duty (/optin). Note that
    -- qbx_core's IsOptin itself checks the 'admin' ACE, so keep perm = 'admin'
    -- when this is enabled.
    requireOptin = true,

    -- Qbox primary job a framework job is reset to by "Remove".
    -- Must exist in qbx_core/shared/jobs.lua.
    defaultJob = 'unemployed',

    ---Which Qbox primary jobs the generic framework adapter exposes.
    ---@class JobAdminFrameworkConfig
    frameworkJobs = {
        enabled = true,
        -- Job names that are never offered (the default job is always excluded).
        blacklist = {},
        -- When set, only these job names are offered. nil = every job except the
        -- blacklist / default job, which is what makes new Qbox jobs appear in the
        -- admin menu with no code change.
        whitelist = nil,
    },

    -- Never expose the internal citizenid to the client unless debugging.
    -- (It is still written to the server-side audit line, see `audit` below.)
    showCitizenId = false,

    -- Show professions the target does NOT have as "not registered" rows in
    -- View Player Jobs (read-only, useful for admins).
    listUnregisteredProfessions = true,

    -- Above this many registered providers the picker groups by type first.
    categoryThreshold = 25,

    ---Server-side audit trail (console / txAdmin log). Never log identifiers.
    audit = {
        -- Include the target's citizenid: it is the durable key for a job record
        -- (server ids are recycled), and it is not a credential.
        citizenId = true,
        -- Include the owning resource of the provider that handled the action.
        resource = true,
    },
}
