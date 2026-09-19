package.path = './?.lua;./?/init.lua;' .. package.path

local h = require 'tests.harness'
require 'tests.matching_spec'
require 'tests.payment_spec'
require 'tests.payment_retry_spec'
require 'tests.lifecycle_spec'
require 'tests.rating_spec'
require 'tests.concurrency_spec'
require 'tests.accept_cas_spec'
require 'tests.roadsnap_spec'
require 'tests.jobsprovider_spec'
require 'tests.driver_hydration_spec'
require 'tests.schema_migration_spec'
require 'tests.scale_spec'
-- The specs below stub host modules (MariaDB access, the driver registry, NPWD's
-- config file) and must therefore load last: package.preload wins over the real
-- file, so anything running after them would get the stub instead of production.
require 'tests.phone_apps_spec'
require 'tests.dispatcher_spec'
h.finish()
