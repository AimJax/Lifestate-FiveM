package.path = './?.lua;./?/init.lua;' .. package.path

local h = require 'tests.harness'
require 'tests.matching_spec'
require 'tests.payment_spec'
require 'tests.payment_retry_spec'
require 'tests.lifecycle_spec'
require 'tests.rating_spec'
require 'tests.concurrency_spec'
h.finish()
