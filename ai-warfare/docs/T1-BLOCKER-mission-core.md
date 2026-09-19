# T1 blocker — every spawned unit is culled before it is ever ordered

**Date:** 2026-09-19
**Reported by:** infrastructure side (server bring-up), for the owner of `resources/[mission]/`
**Status:** Confirmed on real hardware. **No mission Lua was modified.**
**Affects:** `resources/[mission]/mission-core/server.lua`
**Impact:** M1 cannot be demonstrated at all. T1 and T2 are both blocked.

---

## Summary

On a healthy, licensed FXServer with OneSync enabled, `test_m1` spawns all 10
peds successfully and then destroys its own registry entry for every one of
them within the same frame, before a single order is issued. `mo_engage`
consequently operates on nothing:

```
mo_engage: attack-move issued to 0 squad(s), 0 unit(s)
```

This is a defect in `mission-core/server.lua`, not a server, config or
environment problem. The surrounding infrastructure has been verified working
(see *Environment* below). As written, the spawn path cannot succeed on any
machine.

---

## Observed behaviour

Verbatim server console output from `test_m1` (FXServer build 35245):

```
[mission-core] [test_m1] clearing
[mission-core] cleared 0 mission entities
[mission-core] [test_m1] spawning A and B
[mission-core] unit 65534 (A/1 slot 0) removed from registry: dead or missing at order time
[mission-core] unit 65533 (A/1 slot 1) removed from registry: dead or missing at order time
[mission-core] unit 65532 (A/1 slot 2) removed from registry: dead or missing at order time
[mission-core] unit 65531 (A/1 slot 3) removed from registry: dead or missing at order time
[mission-core] unit 65530 (A/1 slot 4) removed from registry: dead or missing at order time
[mission-core] spawned squad A/1 — 5/5 peds at (1700.00, 3250.00, 41.00 h=200.0)
[mission-core] unit 65529 (B/1 slot 0) removed from registry: dead or missing at order time
...
[mission-core] spawned squad B/1 — 5/5 peds at (1580.00, 3120.00, 41.00 h=20.0)
[mission-core] [test_m1] engage
[mission-core] mo_engage: attack-move issued to 0 squad(s), 0 unit(s)
[mission-core] [test_m1] running for 90 s — walk the caster >300 m away to force ownership migration
[mission-core] [test_m1] 90 s elapsed, dumping status
[mission-core] --- status ---------------------------------------------------------
[mission-core] no squads registered
[mission-core] --------------------------------------------------------------------
```

Note the ordering: the `removed from registry` lines appear **before** the
`spawned squad A/1 — 5/5 peds` summary, because the culling happens inside the
spawn loop itself.

---

## What is already proven to work

Do not spend time re-checking these.

| Item | Result |
|---|---|
| `CreatePed(4, hash, x, y, z, h, true, true)` | **Correct.** 10/10 peds created, `5/5` for each squad. |
| `DoesEntityExist` immediately after creation | **True** — the `CreatePed failed` branch at line 243 never fires. |
| Ped models (`s_m_y_marine_01/03`, `s_m_y_blackops_01/02`) | Valid, all resolve. |
| `Config.Spawns` / `Config.Factions` / `SquadSize` | Loaded correctly, coordinates reached. |
| OneSync | `onesync_enabled: true` via `/info.json`. |
| License / resources / map | Server authenticates, 9 resources running, gametype+map paired. |

**This resolves the open `-- VERIFY:` at
[`server.lua:238`](../resources/[mission]/mission-core/server.lua)** — the
server-side `CREATE_PED` signature *does* take a leading `pedType`, and the
current call is right. That row can be marked confirmed in the README.

---

## Root cause

`spawnSquad` issues the initial order in the **same frame** as the ped is
created.

1. `server.lua:241` — `CreatePed(...)` returns a valid handle.
2. `server.lua:243` — `DoesEntityExist(ped)` returns **true**, so the unit is
   registered into `units[netId]`.
3. `server.lua:275` — `setUnitOrder(netId, 'hold')` is called **inline, same
   frame**.
4. `server.lua:155` — `setUnitOrder` calls `entityAlive(u.ped)`.
5. `server.lua:109` — `entityAlive` is:

   ```lua
   local function entityAlive(ped)
       if type(ped) ~= 'number' or ped == 0 then return false end
       if not DoesEntityExist(ped) then return false end
       return GetEntityHealth(ped) > 0
   end
   ```

   This returns **false**, so `server.lua:156` calls
   `forgetUnit(netId, 'dead or missing at order time')`.

A server-created ped is not fully queryable in its creation frame. Step 2 and
step 5 disagree about the very same entity microseconds apart, so whichever of
`DoesEntityExist` or `GetEntityHealth` is at fault, the read is simply too
early.

### The audit loop has the same flaw

Even if the inline order at line 275 were removed, the ownership audit would
delete the units about one second later. `server.lua:549`:

```lua
elseif GetEntityHealth(u.ped) <= 0 then
    stale[#stale + 1] = { netId, 'health <= 0' }
```

So there are **two independent call sites** that equate "health is 0" with
"this ped is dead". Both need addressing, or the fix will appear to work and
then silently regress a second later.

---

## Hypothesis tested and ruled out

**Ruled out: OneSync client scope.**

The initial theory was that the peds never instantiate because no client is
near them — the squads spawn in Sandy Shores at `(1700, 3250)` / `(1580, 3120)`
while `fivem-map-skater` scatters players across 60 map-wide spawn points,
typically kilometres away.

That was tested directly. `fivem-map-skater/map.lua` was temporarily replaced
with a **single** spawn point at `(1650, 3200, 41)` — 70 m from squad A, 110 m
from squad B — and the client was confirmed connected (`players: 1/8`) and in
scope before running `test_m1`.

**The output was byte-identical.** Client proximity makes no difference, which
eliminates scope/instantiation as the cause and leaves the same-frame read.

*(That map override is a disposable diagnostic: `fivem-map-skater` is
gitignored and restored by `scripts/get-server.ps1`. It should be reverted.)*

---

## Suggested fix

All three are in `mission-core/server.lua`. Directions only — deliberately not
implemented, since this resource is owned by the Lua side.

1. **Do not order a ped in its creation frame.** `spawnSquad:213` should
   register units first and apply the initial `hold` after at least one frame,
   or set the order directly on the state bag without routing through the
   aliveness gate — the ped was just created and `DoesEntityExist` already
   passed at line 243.

2. **Do not treat "never yet alive" as "dead".** Give each unit a
   `seenAlive` flag. `entityAlive:109` and the audit at `server.lua:549`
   should only cull on `health <= 0` *after* the unit has been observed alive
   at least once. Pair it with a bounded grace (a few audit ticks) so a ped
   that genuinely never instantiates is still reaped rather than leaking.

3. **Fix the misleading status message.** `mo_status:446` prints
   `no squads registered`, but both squads *were* registered — `forEachSquad`
   at `server.lua:200` skips empty buckets (`if #bucket > 0`), so a total unit
   wipe is indistinguishable from nothing ever having been created. Reporting
   "2 squads registered, 0 units alive" would have pointed straight at this.

---

## Reproduction

1. Start the server with a live console: `scripts\run-server-console.cmd`
2. Connect a FiveM client to `127.0.0.1:30120`.
3. Type `test_m1` at the `cfx>` prompt (server console bypasses ACE).
4. Observe the `removed from registry` lines during spawn, and
   `0 squad(s), 0 unit(s)` at engage.

Reproduces every time, with and without a client in scope.

---

## Environment

- FXServer Windows build **35245** (latest recommended, 2026-09-19)
- Windows 11, PowerShell 5.1
- `onesync on` (verified `onesync_enabled: true`)
- License authenticated
- Resources running: `mapmanager`, `spawnmanager`, `basic-gamemode`,
  `fivem-map-skater`, `mission-shared`, `mission-core`, `mission-ai`,
  `population-ctl`, `hardcap`
- `restart-and-check.ps1` reports **PASS** with a clean log — the server is
  healthy; this failure is invisible to it because nothing is logged at
  `error` level.

---

## Note for whoever picks this up

`mission-core` reports everything through Lua `print()` to the **server
console** and never messages the client, so none of the above is visible
in-game or in the F8 client console. Use `scripts\run-server-console.cmd`;
`restart-and-check.ps1` redirects stdout to a block-buffered file that does not
flush until the server exits, so it cannot be used to watch a live session.

---

## Resolution (2026-09-19, commit `595201c`)

Fixed in `mission-core/server.lua`, `mission-shared/config.lua`, and the offline
harness. All three suggested directions were taken.

Before fixing anything, the harness was corrected to model reality: a
server-created ped now starts un-instantiated, reading health 0 and absent from
the ped pool, with a switch controlling whether `DoesEntityExist` is true or
false beforehand. Against the unfixed code this **reproduced the production
console output byte-for-byte**, five `removed from registry: dead or missing at
order time` lines followed by `0 squad(s), 0 unit(s)`. Seven pre-existing tests
went red at the same time, which is the measure of how wrong the mock had been.

| Change | Where |
|---|---|
| Initial `hold` publishes without any liveness gate | `publishOrder`, split out of `setUnitOrder` |
| A unit is culled for being dead only once seen alive | `setUnitOrder`, and the audit's health branch |
| Non-existence culls only past the grace window | audit |
| `Config.SpawnGraceMs` (15000) then reaps, via the corpse path, logging that no client ever instantiated it | config + audit |
| Audit retries a missing order (`u.order == nil`) | audit |
| `mo_status` lists empty buckets and prints totals; per-unit "waiting for a client to instantiate it" | `forEachSquad(fn, includeEmpty)` |
| Spawn counts created / registered / ordered / alive separately | `spawnSquad` |

Tests 15 to 20 cover it. Reverting the `seenAlive` gate turns 15 and 18 red;
reverting the audit guard turns 16 and 17 red; reverting the grace window,
the empty-bucket listing, the spawn counter and the self-heal each turn one
red. One honest gap: with the `seenAlive` gate in place, removing the
gate-free initial publish alone reddens nothing. It is kept as redundant
defence because ordering a ped in its creation frame should never consult
liveness in the first place.

### Still assumed, not proven — check these on the next live run

The fix rests on four claims about real FiveM that no data here settles. Each
would show up differently in the console, so they are worth knowing before the
next session.

| Assumption | How it would fail visibly |
|---|---|
| A non-zero `CreatePed` handle means success even when `DoesEntityExist` is false | `CreatePed failed` warnings at spawn |
| `NetworkGetNetworkIdFromEntity` returns a usable id before instantiation | `no network id for freshly created ped` warnings, peds deleted at spawn |
| A state-bag write succeeds on a not-yet-instantiated entity | `state bag write failed`, then `re-applied hold` from the audit a second later; harmless if the retry lands |
| 15000 ms is a safe upper bound for a client to scope in | units culled with `never became alive within 15000 ms`; raise `Config.SpawnGraceMs` |

The third is already self-healing by design. The second is the one that would
still block M1, and it would be obvious in the spawn output.
