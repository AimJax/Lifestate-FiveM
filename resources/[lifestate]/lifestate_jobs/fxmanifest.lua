fx_version 'cerulean'
game 'gta5'

description 'Lifestate Job Management (generic admin job/profession registry)'
repository 'https://github.com/AimJax/Lifestate-FiveM'
version '0.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua'
}

client_scripts {
    'client/main.lua'
}

-- No database layer on purpose: this resource only dispatches to providers, and
-- each provider (for example lifestate_ojol) owns its own persistence.
server_scripts {
    'server/main.lua'
}

dependencies {
    'qbx_core',
    'ox_lib'
}

lua54 'yes'
use_experimental_fxv2_oal 'yes'
