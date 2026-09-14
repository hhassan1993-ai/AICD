# Mission Engine — M1/M2 Technical Spec (v0.1)

Scope: Launch Plan v2.0 §3, milestones M1 (autonomous AI squads, ownership migration handled)
and M2 (server order → owner-client task; move / attack-move / hold / retreat via chat commands).
Standalone resources only. No framework. Lua 5.4 (FXServer runtime). Coordinates in config are
**placeholders** until replaced with `/coords` dumper output (§3.5: never model-generated).

## 1. Ownership-migration design (risk T1)

OneSync migrates ped ownership to the nearest client; task natives only act on the owner.
Orders therefore live in **entity state bags**, not in RPC calls:

```
server: Entity(ped).state:set('mo', { seq=<int>, t='amove', x=,y=,z=, sq=<squadId>, f=<faction>, slot=<n> }, true)
client (mission-ai, every 500 ms):
  for each mission ped this client owns (NetworkHasControlOfEntity):
     st = Entity(ped).state.mo
     if st and applied[netId] ~= st.seq then apply(ped, st); applied[netId] = st.seq end
     supervise(ped, st)   -- e.g. amove: re-engage if enemy within radius, else resume goto
```

Effects: new owner after migration sees `applied[netId] == nil` → re-applies the current order.
No server round-trip on migration. `seq` increments per new order so a repeated order re-applies.
Server also sets `Entity(ped).state.mu = { f, sq, slot }` once at spawn (unit identity).

## 2. Resources

```
ai-warfare/resources/[mission]/
  mission-shared/   config.lua (factions, squads, spawn points, tuning) — shared_script
  mission-core/     server.lua — registry, spawn, orders, ownership audit, /coords dump
  mission-ai/       client.lua — owner-side tasking, relationship groups, combat attrs, ground snap
  population-ctl/   client.lua — ambient peds/traffic/cops/dispatch off, radio off
```
Each has `fxmanifest.lua` (`fx_version 'cerulean'`, `game 'gta5'`, `lua54 'yes'`).

## 3. mission-shared/config.lua

```lua
Config = {}
Config.Factions = {
  A = { name='Coastal Republic', group='MO_FACTION_A', color=1,  models={'s_m_y_marine_01','s_m_y_marine_03'},  weapons={'WEAPON_CARBINERIFLE','WEAPON_ASSAULTRIFLE'} },
  B = { name='Blackline Syndicate', group='MO_FACTION_B', color=6, models={'s_m_y_blackops_01','s_m_y_blackops_02'}, weapons={'WEAPON_ASSAULTRIFLE','WEAPON_SPECIALCARBINE'} },
}
Config.SquadSize = 5
Config.Combat = { accuracy=35, seeRange=120.0, hearRange=120.0, engageRadius=80.0 }
Config.Tick = { clientMs=500, serverAuditMs=1000 }
-- PLACEHOLDER coordinates (unverified). Replace with /coords dumper output before first session.
Config.Spawns = { A = vector4(1700.0, 3250.0, 41.0, 200.0), B = vector4(1580.0, 3120.0, 41.0, 20.0) }
Config.FormationOffset = 2.5  -- metres between squad members (line abreast, slot-indexed)
```

## 4. mission-core (server)

State: `units[netId] = { ped=entity, f='A', sq=1, slot=n, order={...}, seq=n }`, `squads[f][sq] = {netIds}`.

Natives (server-side, OneSync): `CreatePed(pedType, model, x, y, z, heading, true, true)` (server-side
CREATE_PED takes a leading `pedType`; 4 = CIVMALE), `GiveWeaponToPed`,
`SetPedArmour`, `NetworkGetNetworkIdFromEntity`, `NetworkGetEntityOwner`, `DoesEntityExist`,
`GetEntityCoords`, `DeleteEntity`, `Entity(e).state`.

Commands (all `RegisterCommand(name, fn, true)` restricted; add `add_ace group.admin command.mo_* allow`):
- `/mo_spawn <A|B> [count]` — spawn one squad of `count` (default Config.SquadSize) at faction spawn, formation slots; sets `mu` and initial order `hold`.
- `/mo_engage` — every squad gets `t='amove'` toward the other faction's spawn (M1 exit: they fight).
- `/mo_move <f> <sq> <x> <y> <z>` · `/mo_amove ...` · `/mo_hold <f> <sq>` · `/mo_retreat <f> <sq>` (retreat = move to faction spawn, `t='retreat'`).
- `/mo_status` — per squad: alive count, owner client of each ped (prints migration evidence for T1 test).
- `/mo_clear` — delete all mission entities.
- `/coords` — client sends its coords+heading; server appends `{label, x, y, z, h}` to `resources/[mission]/mission-core/coords_dump.json` (SaveResourceFile). This is the coord dumper of §3.5.

Ownership audit (every `serverAuditMs`): for each unit, drop dead/missing (`DoesEntityExist` false or `GetEntityHealth<=0` → remove from registry, log). Log owner changes: `[T1] unit <netId> owner <old> -> <new>`.

## 5. mission-ai (client)

On resource start and every 500 ms:
1. Ensure relationship groups exist once: `AddRelationshipGroup(name)` for each faction; `SetRelationshipBetweenGroups(5, A, B)` and `(5, B, A)`; `(1, A, PLAYER)`/(1, PLAYER, A)` and same for B (peds respect players — commanders/caster in console mode are not targets; use `GetHashKey('PLAYER')`).
2. Enumerate peds (`GetGamePool('CPed')`), keep those with `Entity(ped).state.mu` and `NetworkHasControlOfEntity(ped)`.
3. `initPed(ped)` once per netId: `SetPedRelationshipGroupHash`, `SetPedAccuracy`, `SetPedSeeingRange/HearingRange`, `SetPedCombatAbility(ped, 1)`, `SetPedCombatRange(ped, 1)`, `SetPedCombatMovement(ped, 2)`, `SetPedCombatAttributes(ped, 0, true)` (cover) `(5,true)` always fight `(46,true)` `(58,true)` (no flee — enum values to verify in-game), `SetPedFleeAttributes(ped, 0, false)`, `SetBlockingOfNonTemporaryEvents(ped, false)`, `SetPedDropsWeaponsWhenDead(ped,false)`, `SetPedCanRagdoll` default. Ground snap: `GetGroundZFor_3dCoord` → `SetEntityCoords` if |dz| > 1.5.
4. `apply(ped, st)`:
   - `hold`: `TaskCombatHatedTargetsAroundPed(ped, engageRadius, 0)` then `TaskStandGuard`-style: use `TaskGuardCurrentPosition(ped, 15.0, 15.0, true)`.
   - `move`: `TaskGoToCoordAnyMeans(ped, x+ox, y+oy, z, 2.0, 0, false, 786603, 0.0)` where `(ox,oy)` = formation offset from `mu.slot`.
   - `amove`: same goto; supervise() each tick: if `GetClosestHostile` (scan enemy-faction peds within engageRadius via pool + `mu.f`) → `TaskCombatPed(ped, target, 0, 16)`; when no hostile within radius and ped not in combat (`IsPedInCombat` false) and distance to goal > 3 → re-issue goto. Track per-ped `mode` ('moving'|'fighting') to avoid re-tasking every tick.
   - `retreat`: goto faction spawn with `SetPedCombatAttributes(ped,5,false)` temporarily; restore on next order.
5. Fog of war / visibility snapshots: **out of scope (M3)**.

## 6. population-ctl (client)

Per frame: `SetVehicleDensityMultiplierThisFrame(0.0)`, `SetPedDensityMultiplierThisFrame(0.0)`, `SetRandomVehicleDensityMultiplierThisFrame(0.0)`, `SetParkedVehicleDensityMultiplierThisFrame(0.0)`, `SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)`, `SetPlayerWantedLevel(PlayerId(),0,false)`+`SetPlayerWantedLevelNow`.
Once: `SetGarbageTrucks(false)`, `SetRandomBoats(false)`, `SetCreateRandomCops(false)`, `SetCreateRandomCopsNotOnScenarios(false)`, `SetCreateRandomCopsOnScenarios(false)`, `EnableDispatchService(i,false)` for i=1..15, `SetMaxWantedLevel(0)`, `SetAudioFlag('DisableFlightMusic', true)`, `SetUserRadioControlEnabled(false)` + `SetRadioToStationName('OFF')` on vehicle entry (§5: licensed radio → Content ID).

## 7. Test commands (§3.5 "per-resource /test_* commands")
- `/test_m1` (server): `mo_clear` → spawn A and B → `mo_engage` → after 90 s print `/mo_status`; exit criterion is both sides taking losses with the caster having walked >300 m away (forces migration) and units still fighting.
- `/test_pool <n>` (server): spawns `n` peds of faction A at spawn in a grid, prints server-side count every 10 s — T2 measurement helper. Caster records client FPS and `resmon`.

## 8. Validation without a game client (this container)
`luac5.4 -p` on every `.lua`; `scripts/lint-lua.sh` wraps it. Runtime validation happens on the
self-hosted FXServer via `scripts/restart-and-check.ps1` (§3.5 loop).
