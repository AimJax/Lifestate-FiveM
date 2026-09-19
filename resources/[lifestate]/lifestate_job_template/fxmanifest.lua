fx_version 'cerulean'
game 'gta5'

description 'Lifestate independent profession template (disabled starter)'
version '1.0.0'

shared_scripts { '@ox_lib/init.lua' }
client_scripts { 'client/main.lua' }
server_scripts { '@oxmysql/lib/MySQL.lua', 'server/main.lua' }

dependencies { 'ox_lib', 'oxmysql', 'lifestate_jobs' }
lua54 'yes'
