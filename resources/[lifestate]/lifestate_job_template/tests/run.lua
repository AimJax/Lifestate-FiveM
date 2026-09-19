package.path = './?.lua;./?/init.lua;' .. package.path
local h = require 'tests.harness'
require 'tests.persistence_spec'
require 'tests.provider_spec'
h.finish()
