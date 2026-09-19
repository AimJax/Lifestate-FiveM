package.path = './?.lua;./?/init.lua;' .. package.path

local h = require 'tests.harness'

-- The job-management modules are exercised directly; every host dependency
-- (qbx_core exports, ACE checks, the config) is stubbed by the specs so the
-- assertions are about OUR logic: registry validation, authorization, target
-- resolution, provider isolation and framework-adapter behaviour.
require 'tests.registry_spec'
require 'tests.service_spec'
require 'tests.provider_ownership_spec'
require 'tests.frameworkjobs_spec'

h.finish()