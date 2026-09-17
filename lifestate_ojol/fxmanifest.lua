fx_version 'cerulean'
game 'gta5'

description 'Lifestate Ojol Profession Foundation'
repository 'https://github.com/AimJax/Lifestate-FiveM'
version '0.3.0'

ox_lib 'locale'

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua'
}

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua',
    'client/customer.lua',
    'client/driver.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

files {
    'locales/*.json',
    'config/client.lua',
    'config/shared.lua'
}

dependencies {
    'qbx_core',
    'ox_lib',
    'oxmysql',
    'ox_target'
}

lua54 'yes'
use_experimental_fxv2_oal 'yes'
