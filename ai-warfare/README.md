# ai-warfare

Self-hosted FXServer infrastructure for the AI-army mission engine described
in Launch Plan v2.0 §3, milestones **M1** (autonomous AI squads with
ownership-migration handled via OneSync entity state bags) and **M2**
(server-issued orders — move / attack-move / hold / retreat — driven by
admin chat commands). This repo holds the server config, setup/launch
scripts, and test docs; the Lua resources themselves live under
`resources/[mission]/` and are maintained separately (see
`docs/ENGINE-SPEC.md`).

## Windows quick start

1. `.\scripts\get-server.ps1` — downloads the latest recommended FXServer
   Windows artifact into `server/artifact/` and clones `cfx-server-data`
   into `server/data/`, copying the standard resource set into `resources/`.
2. `$env:FIVEM_LICENSE_KEY = "<your key>"` — get a free key at
   [portal.cfx.re](https://portal.cfx.re) (Keymaster). Never commit it.
3. `.\scripts\restart-and-check.ps1` — starts FXServer for 45s (default),
   captures the log, greps it for error signatures, prints PASS/FAIL.
4. Open the FiveM client and connect to `127.0.0.1:30120`.
5. In the in-game console / chat, run `/test_m1`.

## Working-directory / `+exec` layout

FXServer only scans **one** `resources/` folder, relative to its working
directory. This repo keeps that folder at the **repo root**
(`ai-warfare/resources/`), containing both `resources/[mission]/` (the Lua
worker's resources, never modified by anything here) and the standard
cfx-server-data resources (`mapmanager`, `chat`, `spawnmanager`,
`sessionmanager`, `basic-gamemode`, `hardcap`), which `get-server.ps1`
copies in from the `server/data/` clone. FXServer is launched with its
working directory set to the repo root and `server.cfg` loaded via
`+exec server/server.cfg`; `sv_licenseKey` is passed as a `+set` on the
command line *after* `+exec` so it overrides the placeholder in the cfg
file without ever writing the real key to disk. See the header comments in
`server/server.cfg` and `scripts/restart-and-check.ps1` for the same
rationale in more detail.

## Command reference (ENGINE-SPEC.md §4, §7)

| Command | Side | Description |
|---|---|---|
| `/mo_spawn <A\|B> [count]` | server | Spawn one squad (default `Config.SquadSize`) at the faction spawn, formation slots, initial order `hold`. |
| `/mo_engage` | server | Every squad gets order `amove` toward the opposing faction's spawn. |
| `/mo_move <f> <sq> <x> <y> <z>` | server | Move a squad to a coordinate (no combat). |
| `/mo_amove <f> <sq> <x> <y> <z>` | server | Attack-move a squad to a coordinate. |
| `/mo_hold <f> <sq>` | server | Squad holds position, engages hostiles in range. |
| `/mo_retreat <f> <sq>` | server | Squad returns to its faction spawn, combat suppressed en route. |
| `/mo_status` | server | Per-squad alive count and owning client of each ped (T1 migration evidence). |
| `/mo_clear` | server | Delete all mission entities. |
| `/coords` | client→server | Dump caster coords+heading to `coords_dump.json` (the coord dumper). |
| `/test_m1` | server | `mo_clear` → spawn A+B → `mo_engage` → after 90s print `/mo_status`. |
| `/test_pool <n>` | server | Spawn `n` faction-A peds in a grid; print count every 10s (T2 helper). |

All commands are admin-restricted via `add_ace` in `server/server.cfg`;
grant yourself admin with `add_principal identifier.fivem:<you> group.admin`.

## T1 test procedure — ownership migration

1. `/mo_clear`, then `/mo_spawn A` and `/mo_spawn B`, then `/mo_engage`.
2. As the caster, physically walk (or noclip) **more than 300 m** away from
   the fight, so OneSync migrates ped ownership to a nearer client (or back
   to the server if no client is close — confirm at least one migration).
3. Run `/mo_status` before and after moving away; confirm the owner client
   listed for at least one unit **changes**, and that units keep fighting
   (alive counts still dropping on both sides, not frozen) after migration.
4. Pass criterion: both sides take losses, an owner change is visible in
   `/mo_status`, and units do not stop acting after the handoff.

## T2 test procedure — pool / performance

1. For `n` in `50, 100, 150, 200, 250, 300`: run `/test_pool <n>`.
2. After each step settles, record: client FPS, F8 `resmon` output, and
   server console `status` output.
3. Write results into `docs/T2-results.md` (template provided) — one row
   per step, noting any stutter/rubber-banding and where FPS drops sharply.

## Verified vs. unverified

| Item | Status |
|---|---|
| Lua syntax of every `.lua` under `resources/` (`luac5.4 -p`, `scripts/lint-lua.sh`) | **Verified** in this container |
| `runtime.fivem.net` artifact-listing HTML structure that `get-server.ps1` parses | Unverified — container has no network path to `runtime.fivem.net` |
| `get-server.ps1` download/extract/clone flow | Unverified — never executed (Windows + network required) |
| `server/server.cfg` values and `ensure` order | Unverified against a running FXServer |
| `restart-and-check.ps1` / `.sh` process start/stop, log capture, grep logic | Unverified — never run against a real `FXServer.exe` / `run.sh` |
| Mission resource logic (`mission-core`, `mission-ai`, `population-ctl`) | Owned by a different worker; out of scope here |
| T1 / T2 pass/fail outcomes | Unverified — require the actual PC, client, and game session |

Everything above "unverified" must be exercised on the owner's Windows PC
before being trusted; that is the entire purpose of `restart-and-check.ps1`
and the T1/T2 procedures in this README.
