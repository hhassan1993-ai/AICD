fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mission-core'
author 'ai-warfare'
description 'Server authority: unit registry, spawn, orders, ownership audit, /coords dump — ENGINE-SPEC v0.1 §4'
version '0.1.0'

dependency 'mission-shared'

shared_script '@mission-shared/config.lua'

server_script 'server.lua'

-- coords_dump.json is created/updated at runtime in this resource folder by
-- SaveResourceFile(); it is deliberately NOT listed in files{} (server-side only).
