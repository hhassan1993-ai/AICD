fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'population-ctl'
author 'ai-warfare'
description 'Suppresses ambient peds/traffic/cops/dispatch and licensed radio — ENGINE-SPEC v0.1 §6'
version '0.1.0'

-- Config is referenced for consistency with the rest of the mission tree.
-- No `dependency` line: population-ctl reads nothing from Config today and must
-- keep working standalone for a bare performance (T2) test.
shared_script '@mission-shared/config.lua'

client_script 'client.lua'
