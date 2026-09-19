local config = require 'config.shared'
if not config.enabled then
    print('[lifestate_job_template] disabled starter; copy and rename it before enabling')
    return
end
local db = require 'server.database'
local profession = require 'server.profession'
require 'server.adminapi'
local provider = require 'server.jobsprovider'
db.EnsureSchema()
profession.Load()
provider.Start()
