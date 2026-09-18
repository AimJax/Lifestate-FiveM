fx_version 'cerulean'
game 'gta5'

description 'Lifestate App Store for NPWD'
version '1.0.0'
repository 'https://github.com/Lifestate-Project/npwd_lifestate_app_store'

client_script 'client/client.lua'

shared_script '@ox_lib/init.lua'

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/**/*',
    'locales/*.json'
}

lua54 'yes'
use_experimental_fxv2_oal 'yes'
provide 'npwd_lifestate_app_store'
