fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mission-ai'
author 'ai-warfare'
description 'Owner-side tasking: relationship groups, combat attributes, ground snap, order application — ENGINE-SPEC v0.1 §5'
version '0.1.0'

dependency 'mission-shared'

shared_script '@mission-shared/config.lua'

client_script 'client.lua'
