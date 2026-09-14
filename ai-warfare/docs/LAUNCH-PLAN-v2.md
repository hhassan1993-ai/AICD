# AI-Warfare YouTube Channel on FiveM — Launch Plan v2.0

**Owner:** Hisham | **Date:** 2026-09-14 | **Supersedes:** Squad plan v1.0
**Format:** Option A — AI armies commanded by human generals (FiveM / GTA V)
**Budget cap:** USD 500 (excl. existing PCs) | **Fixed roles:** caster + producer; rotate into commander occasionally
**Format progression:** Shorts → long-form edited → live

**Assumption (unanswered):** faction theme = **fictional, lore-friendly factions** built on vanilla GTA military assets. Rationale in §5. Change on request.

---

## 1. Concept & Positioning

**One-line pitch:** Two human generals, two AI armies, one city. Combined-arms war on the Los Santos sandbox, cast like a sport.

| Dimension | Vadact "All Out War" (reference) | This channel |
|---|---|---|
| Combatants | ~30 human community players | Scripted GTA AI peds + vehicles on both sides |
| Humans per session | 25–40 | **2–4** (commanders + caster) |
| Command layer | Voice only | Custom commander map UI with real orders and fog of war |
| Win conditions | Verbal, honor-system | Enforced by code; live scoreboard/tickets on the cast overlay |
| Narrative | Emergent banter | Commander strategy + emergent AI chaos + casting |
| Scale ceiling | Recruitment | Engine sync/entity limits |
| Repeatability | Depends on turnout | Fully schedulable, deterministic setup, no-show-proof |

**Differentiation thesis:** Unoccupied niche. GTA content is saturated with RP and human war events; nobody is producing **RTS-style human-vs-human strategy over AI armies in GTA**. The product is the commanders' decisions and the caster's narrative; the AI battle is the visual payload. Crossover TAM: GTA audience (very large) + RTS/wargame/AI-battle audience.

**Content pillars:** Battle Reports (long-form) · Highlight Shorts · War Room debriefs · Live Operations (Phase 3).

---

## 2. Product Definition — Session Format Spec

| Element | Spec |
|---|---|
| Duration | 45–90 min per operation |
| Sides | 2 commanders (design supports N≥2) |
| Command model | Each commander at a **commander console** (NUI map): sees own units + enemy contacts spotted by own units; issues orders to squads/vehicles. Optional "embed" mode: commander drops into a body for a boots-level moment (great for content, costs situational awareness) |
| Orders (MVP) | Move to · Attack-move · Hold/defend area · Take cover · Mount/dismount vehicle · Vehicle drive-to · Retreat to rally · Air strafe run (Phase 2 dev) · Artillery fire mission (Phase 2 dev) |
| Force budgets | Point-buy draft before match (e.g., 300 pts: rifle squad 20, MG team 25, AT team 30, APC 60, tank 100, attack heli 120). Draft happens on camera = pre-match content |
| Win conditions | Coded: zone control tickets (AAS-style), HVT survival, timed objectives; scoreboard rendered on caster overlay |
| Fog of war | Server-side: enemy units revealed only within sight radius of own units/vehicles; caster sees all |
| Scarcity | Vehicles are one-life (Vadact's most effective tension rule); infantry reinforcement waves limited by ticket pool |
| Comms | Discord: commander A channel, commander B channel, caster channel — recorded separately |

Public **Ruleset v1.0** document (commander powers, draft rules, pauses, intervention policy) = league identity + community debate fuel.

---

## 3. Engineering Sprint — the mission engine (replaces "Sprint 0")

This is the plan's dominant cost, in your time. Rough estimate for an MVP: **6–10 weeks part-time** (est. 8–12 h/week). Estimate uncertainty is high; the ownership/sync issues in §3.3 are where time goes.

### 3.1 Stack
| Layer | Choice | Notes |
|---|---|---|
| Server | FXServer (self-hosted), **OneSync enabled** | Free. Required for server-side entity creation and >32 slots |
| Language | Lua for game-side resources; JS/TS for NUI | Lua has the widest FiveM example base |
| Commander UI | NUI (CEF, HTML/JS) — a map view (Leaflet or plain canvas over a GTA map tileset) with unit icons and order buttons | Runs inside the FiveM client, no external app |
| AI | Native GTA V ped AI via task natives (combat, go-to, guard, cover, enter vehicle, drive-to) + relationship groups for faction hostility + combat attribute tuning (accuracy, ranges, cover use) | No third-party bot mod — zero external dependency |
| Voice | Discord for commanders/caster; pma-voice only if embedded bodies need proximity chat | |
| Spectator | Custom free-cam resource (create cam, focus position) with cinematic presets | Small script |
| Overlay | NUI overlay on the caster client: tickets, zone states, unit counts, clock — captured by OBS | |

### 3.2 Resource architecture
```
[FXServer]
 ├─ mission-core (server, Lua)
 │    ├─ Faction & unit registry (squad → ped handles → owner client)
 │    ├─ Order queue + validation (per-commander permissions)
 │    ├─ Objective/ticket engine + win conditions
 │    ├─ Fog-of-war visibility calc → per-commander unit snapshots
 │    └─ Match state machine: lobby → draft → deploy → live → end
 ├─ mission-ai (client, Lua) — runs on EVERY client
 │    └─ For each ped/vehicle this client currently OWNS: apply the latest server order via task natives
 ├─ commander-ui (client + NUI) — commander map, orders, draft
 ├─ spectator-cam (client) — caster free-cam + cinematic presets
 └─ caster-overlay (client + NUI) — scoreboard/tickets/clock
```

### 3.3 Known technical risks (validate first)
| # | Risk | Detail | Validation |
|---|---|---|---|
| T1 | **Entity ownership migration** | OneSync migrates ped/vehicle ownership to the nearest client. Task natives execute only on the owner. Orders must be broadcast and applied by whichever client owns the entity at that moment; orders must be re-applied on ownership change or tasks drop | Build this first; test with commanders/caster moving around the map |
| T2 | **Entity pool limits** | GTA's ped pool is finite (commonly cited ~256 peds); whether FiveM pool-size increases cover the pools you need is **unverified**. Vehicles/objects have separate pools. Sync bandwidth grows with entities in combat | Empirical: scale bots until sync/FPS degrade on your hardware; record numbers |
| T3 | **AI legibility** | GTA peds use cover and engage but have no squad tactics or formations; large fights can look like a mob | Script formation offsets on move; small squads (4–6); vehicles/air/artillery for spectacle; strong team color coding |
| T4 | **Population interference** | Ambient traffic/peds/cops must be disabled or they pollute the battle | Standard population-density natives; test |
| T5 | **Player-owned-client load** | Every client (including commanders) runs AI tasking for owned entities; commander PCs need decent specs | Set minimum spec for commanders |
| T6 | **Vehicle AI** | Driving AI for convoys/armor is serviceable on roads, poor off-road; aircraft AI is limited | Design maps around roads and open ground; scripted strafe runs via waypoints rather than free dogfights |

### 3.4 Milestones
| M | Deliverable | Exit criterion |
|---|---|---|
| M1 | Server up, OneSync, population off, faction relationship groups, spawn N peds per side that fight autonomously | Two AI squads fight without intervention; ownership migration handled |
| M2 | Order pipeline: server order → owner-client task; 4 orders (move, attack-move, hold, retreat) | Commander issues orders from chat command; units comply within 2 s |
| M3 | Commander NUI map with own-unit icons, click-to-order, fog of war | Two commanders on separate PCs command their own side only |
| M4 | Objective/ticket engine + caster overlay + spectator cam | A full 45-min match runs end-to-end with a winner declared by code |
| M5 | Vehicles: APC/tank mount + drive-to; one-life rule | Combined-arms match recorded as pilot |
| M6 (Phase 2 dev) | Draft system, artillery/air strike orders, cinematic cam presets, replay-ish "event log" for editing | — |

Scope discipline: **ship M1–M5, start filming, then iterate.** Do not build the draft UI before the first video exists.

### 3.5 Development workflow (from HighwayTrooper, *I Used Claude AI to Build a FiveM Server…*, 2026-07-25)
Evidence: a Claude-based FiveM dev tool built a full QBCore/Qbox RP server (HUD, menus, multi-char, spawn, jobs, gangs, housing, XP, anti-cheat) in five staged prompts, each resource standalone, each validated by restarting the server and parsing console errors; bugs fixed in one round-trip each. Caveats: all of it is heavily documented RP boilerplate; the model repeatedly produced wrong world coordinates.

| Practice | Rule |
|---|---|
| Tooling | Claude Code against the server folder. Keep FiveM natives reference + OneSync docs in context |
| Loop | Plan in stages → one resource per prompt → `restart-and-check` script (start FXServer, capture console, grep errors) the model can run itself |
| Theme | One shared NUI theme/CSS file reused by commander UI, caster overlay, draft screen |
| Testing | Per-resource `/test_*` commands so each piece is verifiable without a full match |
| Coordinates | **Never model-generated.** Author spawn points, zones, camera presets, rally points via an in-game coord dumper; store as config |
| Framework | Standalone only. No QBCore/Qbox/ESX — no economy/needs systems, no extra load |
| Where it helps | M3 UI, M4 overlay, M6 draft: expect 2–3× faster than the base estimate |
| Where it doesn't | M1–M2 (ped tasking across ownership migration, fog of war): low training-data coverage; T1/T2 validations stand |

Revised MVP estimate: **5–8 weeks** part-time (was 6–10). Estimate remains uncertain.

---

## 4. Production Stack

### 4.1 Software (all free)
OBS Studio (game capture, multi-track audio) · DaVinci Resolve · Audacity · GIMP/Canva free · YouTube Audio Library / Pixabay (log every license) · Discord · YouTube Studio + vidIQ/TubeBuddy free tiers · Notion/Obsidian.

### 4.2 Hardware (≤ USD 500)
| Item | Purpose | Est. USD |
|---|---|---|
| Dynamic USB mic (Samson Q2U / ATR2100x / FIFINE AM8) | Casting voice — highest ROI item | 70–100 |
| Boom arm + pop filter | Consistency, plosives | 30–45 |
| 4 TB external HDD | Raw archive (multi-POV 1080p60 ≈ 30–60 GB/session) | 90–110 |
| 1 TB NVMe (if edit drive is tight) | Scratch | 60–80 |
| Contingency | Cables, acoustic foam, later key light | 100 |
| **Total** | | **≈ 350–435** |

Server hosting: self-host = USD 0. With only 2–4 humans connected, bandwidth is trivial versus a 30-player event. Move to a hosted FXServer (~USD 15–40/mo, to verify) only if Phase 3 uptime requires it.

**No EUP, no ripped vehicle packs** → no Element Club subscription, no recurring cost, no IP-rip exposure (§5).

### 4.3 Recording architecture
```
[FXServer — self-hosted]
   ├── Your PC (caster): spectator cam + overlay ── OBS ── T1 game audio / T2 caster mic / T3 Discord
   ├── Commander A PC: local OBS (NUI map + own mic)
   └── Commander B PC: local OBS (NUI map + own mic)
   Post-session: commanders upload via Drive/OneDrive link; sync via countdown/flash marker
```
Standard: 1080p60, NVENC/AMF ~20 Mbps, 48 kHz, separate audio tracks always. Commander map POVs are the "chess board" footage for the War Room segments.

Automation (your strength): PowerShell ingest — auto-rename POVs, ffmpeg proxies, per-episode folder scaffold. Also have `mission-core` write a **timestamped event log** (kills, captures, orders) → editing becomes searching a log, not scrubbing 90 min of footage.

---

## 5. Legal / Policy Constraints

| Constraint | Position | Action |
|---|---|---|
| Rockstar/Take-Two video content policy | GTA content is among the most monetized on YouTube; policy permits monetized videos with conditions (e.g., no cheats/exploits shown) — **verify current policy text** | Read and log before enabling monetization |
| Cfx.re / Rockstar FiveM terms (Rockstar acquired Cfx.re in 2023) | Server-side monetization only through approved route (Tebex); no assets from other Rockstar/Take-Two titles; no GTA Online interference. **Therefore: never sell in-game perks via YouTube memberships/Patreon.** Perks stay off-server (Discord roles, votes, early access, naming a squad) | Verify current PLA text |
| Add-on real-world military models (Abrams, MiG-29, etc.) | Many are ripped from other games — IP violation and a monetization risk | **Vanilla-first policy:** GTA has native military peds (marines, black-ops, mercenaries, SWAT) and vehicles (tank, APC, IFV-style, attack helis, jets, artillery/missile truck, transports, technicals). Fictional factions make vanilla assets look intentional rather than "wrong" |
| Vanilla-asset model = fictional factions | Also sidesteps real-conflict sensitivity that can hurt ad suitability | Default assumption in this plan |
| YouTube "inauthentic content" | AI-vs-AI raw footage could pattern-match mass-produced content | Human commanders + live casting + editing on every upload; never raw bot footage |
| Ad suitability | GTA violence is fine in gameplay context; gore/sexual content is not | Keep it a war show, not a GTA freak show |
| Music/SFX | Free-license libraries only, asset log per video | |
| Participant consent | Signed form: recording, publication, revenue-share statement | |
| AdSense in UAE | Confirm payout availability at signup | |
| Rockstar RP-server enforcement priorities (Nov 2022, reaffirmed post-acquisition): real-world brands/trademarks; commercial exploitation incl. sponsorships and in-game integrations; "making new games, stories, missions, or maps" | (ii) confirms vanilla/fictional assets; (iii) means **sponsors never appear on the server** — channel sponsorships only; (iv) is an unresolved ambiguity for a custom game mode — no published clarification found | Monitor; frame publicly as a modified server experience, not a standalone game; keep server and channel legally separate |
| Cfx.re guidance (Jan 2025): de-badging real-world vehicles does not protect a server; create unique vehicles/brands | Precedent for the assets plan tiering | Applied |
| GTA licensed radio/music | Content ID claims on uploads | Disable in-game radio/music at server level before recording |

---

## 6. Team & Roles

| Role | Who | Phase 1 compensation |
|---|---|---|
| Producer / caster / editor / engineer | You | Owner |
| Commanders (pool of 4–6) | Volunteers | Credit, Discord rank, later revenue share on featured episodes |
| Backup server admin (Phase 3) | Volunteer | Same |
| Optional: Lua/JS contributor | Volunteer from FiveM dev community | Credit; consider open-sourcing non-core parts to attract help |

Recruitment: FiveM dev/Cfx.re forums and Discord (for contributors), GTA milsim Discords, r/FiveM, r/GTAV, Arma Zeus / RTS communities (they already think like commanders). Pitch: "command an army in a YouTube war series." Commander PC minimum spec published up front (§3.3 T5).

---

## 7. Content Roadmap & Phase Gates

### Phase 0 — Engineering + Pilot (Weeks 1–10)
- M1–M5 (§3.4). Recruit commanders at M3 so they help test.
- 2 unrecorded rehearsals; 1 recorded pilot; cut 3 test Shorts.
- **Gate:** full match runs end-to-end; a stranger can tell who is winning from the footage.

### Phase 1 — Shorts (Months 3–5)
- 1 session/week → 3–5 Shorts/week (20–50 s: one hook, one payoff — a tank ambush, a last stand at a zone, a commander blunder shown on the map then on the ground).
- Pinned comment/description: "Full battles coming — subscribe + Discord."
- **Fact that shapes this phase:** Shorts-feed watch time does not count toward the 4,000 watch-hours threshold. Shorts buy subscribers and algorithm data only. Cap Phase 1 at ~3 months.
- **Gate to Phase 2:** 300–500 subs OR a Short >50k views OR month 5.

### Phase 2 — Long-form (Months 5–11)
- 1 Battle Report per 1–2 weeks (12–22 min) + 2–3 Shorts/week from the same session.
- Structure: briefing with map graphics → draft/plans in commanders' voices → battle in 3 acts (cast) → turning-point analysis using commander map POV → debrief + scoreboard + tease.
- Serialize: commander win/loss ladder, campaign map, seasons. Serialization drives watch hours.
- Dev in parallel: M6 features as content unlocks ("this season introduces artillery").
- **Gate to Phase 3:** 1,000+ subs, 20+ long-form videos, ≥40% avg retention, Discord 100+, pipeline stable.

### Phase 3 — Live (Month 11+)
- Monthly live op (2–3 h); chat votes on mission parameters or reinforcement drops (superchat driver, allowed since it's off-server value, not paid in-game advantage sold via the server).
- VOD → Battle Report + Shorts.

---

## 8. Channel Setup & Packaging

| Item | Spec |
|---|---|
| Naming | Options: *Bot Command*, *Silicon Frontlines*, *The Generals' Table*, *War Room: Los Santos*. Avoid "GTA" or "FiveM" as the leading word (trademark + search ambiguity); check handle availability across YouTube/Discord/X together |
| Title formula (long-form) | Stakes + specificity: "200 AI Soldiers, 2 Generals, 1 Bridge — Operation Nightfall" (Vadact's superlative-hook formula, retooled to strategy) |
| Thumbnails | Map-arrow graphics + one action frame + commander reaction cam if consented; faction colors |
| Descriptions | Mission brief format, ruleset link, Discord, chapters, asset/music credits |
| Metadata targets | "gta ai war", "ai vs ai battle", "fivem ai army", "gta rts", "commanding ai soldiers gta" |
| Playlists | Per season; per commander |

---

## 9. Per-Episode Workflow (steady-state Phase 2, with a full-time job)

| Step | Time |
|---|---|
| Mission design (objectives, force budgets, spawn layout in config) | 1.0 h |
| Session run + record | 1.5–2.0 h |
| Ingest, sync, pull key moments from the event log | 0.5–1.0 h |
| Shorts cut (3×) | 1.5 h |
| Long-form edit + narration pass | 5–7 h |
| Thumbnail + metadata + schedule | 1.0 h |
| **Total** | **≈ 11–13 h/week** (plus ongoing dev time until M6) |

Sustainability: fortnightly long-form fallback; volunteer editor at ~500 subs; template briefing/debrief graphics once.

---

## 10. Monetization & Profit Model

### 10.1 YPP thresholds (verify at application)
| Tier | Requirements | Unlocks |
|---|---|---|
| Fan-funding | 500 subs + 3 public uploads/90 d + (3,000 watch h/12 mo OR 3 M Shorts views/90 d) | Memberships, Super Thanks/Chat, Shopping |
| Full | 1,000 subs + (4,000 valid public watch h/12 mo OR 10 M Shorts views/90 d) | Ad revenue + Premium share |
Sources: YouTube official YPP eligibility pages (support.google.com/youtube/answer/72851; youtube.com/creators/partner-program), retrieved 2026-08-04.

### 10.2 Revenue streams
| Stream | Earliest | Notes |
|---|---|---|
| Super Thanks / memberships | Late Phase 1 | Perks off-server only: vote next mission, name a squad, extended debriefs |
| AdSense long-form | Phase 2 | Mid-rolls ≥8 min; GTA audience RPM is typically lower than milsim, but volume is far higher |
| Patreon / Ko-fi | Phase 2 | Mission-design docs, early access, ruleset input |
| Sponsorships | ~5k+ subs | **Channel-only.** Server hosts, peripherals, VPN, PC hardware via video integrations and descriptions; no sponsor presence inside the server (Rockstar RP policy prohibits in-game integrations/sponsorships). Media kit; niche channels close early |
| Open-source / dev angle | Phase 2+ | Publishing the framework (or parts) draws the FiveM dev community — contributors, credibility, and a possible future licensed "premium" version via Tebex (the compliant route) |
| Merch | After lore exists (faction insignia) | Print-on-demand |

### 10.3 Projection (order-of-magnitude; explicitly uncertain)
| Milestone | Timeline | Monthly revenue |
|---|---|---|
| Fan-funding tier | Month 6–9 | USD 10–50 |
| Full YPP via long-form hours | Month 10–16 | — |
| 50k long-form views/mo @ ~USD 1.5–4 RPM | Month 12–18 | USD 75–200 |
| + Patreon + 1 sponsorship/quarter | Month 14–20 | USD 250–700 |
| Break-even vs ~USD 450 capex | ~Month 14–18 | — |

Honest framing: Year 1 = build engine + audience. Upside = **format ownership** in an unoccupied niche, plus a reusable software asset with its own optional monetization path.

---

## 11. KPIs & Gates
| Metric | Phase 1 | Phase 2 |
|---|---|---|
| Shorts viewed vs swiped | >70% | — |
| Long-form avg retention | — | ≥40% |
| CTR | ≥4% | ≥5% |
| Subs | 500 by month 5–6 | 1,000 by month 10 |
| Discord members | 50 | 150 |
| Sessions without technical failure | ≥80% | ≥90% |

Kill/pivot review at month 6: if Shorts <1k views consistently, diagnose **legibility** (can a stranger read the battle?) before diagnosing the niche.

---

## 12. Risk Register
| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Engineering sprint overruns / never ships | High | Critical | Hard scope M1–M5; timebox 10 weeks; recruit a contributor; first video before M6 |
| R2 | Entity/sync limits cap scale below "big war" feel | Med | High | Company-scale fights (60–120 peds) framed tightly; vehicles/air for scale perception; camera work |
| R3 | AI looks dumb / fights illegible | Med–High | High | Small squads, formations, color coding, commander-map cutaways, casting explains intent |
| R4 | Ownership migration bugs mid-match | High (early) | Med | M1 hardening; commanders stay in console mode (no bodies near fights) in early seasons |
| R5 | FiveM/GTA update breaks natives or resources | Low–Med | Med | Pin server artifact version during a season; test on a staging server before updating |
| R6 | Policy (Rockstar/Cfx.re) conflict | Low | High | §5 verification; vanilla assets; no in-game paid perks |
| R7 | YouTube inauthentic-content flag | Low | High | Human casting/commanders in every upload |
| R8 | Time burnout (job + dev + 12 h/wk production) | High | High | Fortnightly cadence; volunteer editor; automation; dev freeze during content pushes |
| R9 | Commander no-shows | Med | Med | Pool of 4–6; only 2 needed; you can commander (rotating role) |

---

## 13. 90-Day Action Plan
| Week | Actions |
|---|---|
| 1 | FXServer + OneSync up; population off; faction relationship groups; first two AI squads fighting (M1 start) |
| 2 | Ownership-migration order pipeline (T1); chat-command orders (M2); document max stable ped count (T2) |
| 3 | Buy mic/boom/HDD; commander NUI map skeleton; fog-of-war snapshot API |
| 4 | M3 complete; recruit 3–4 commanders from FiveM/GTA milsim/RTS Discords; consent form; publish commander PC spec |
| 5 | Objective/ticket engine; caster overlay; spectator cam (M4) |
| 6 | Vehicles mount/drive-to; one-life rule (M5); ruleset v1.0; verify Rockstar + Cfx.re policies, AdSense/UAE |
| 7 | Two rehearsal sessions; fix top 5 bugs; channel name + handles + Discord created |
| 8 | Pilot session recorded; cut 3 Shorts; thumbnail/graphics templates; ingest automation scripts |
| 9–10 | First 6–8 Shorts published (3/wk); event-log-driven editing workflow tested |
| 11–12 | Weekly session cadence; 3–5 Shorts/wk; commander ladder started; review Phase 1 gate trajectory |
| 13 | Storyboard Battle Report #1; decide M6 feature for "season 1 finale" |

---

## 14. Verification Ledger (zero-hallucination compliance)
| Claim | Basis |
|---|---|
| YPP thresholds; Shorts-feed hours excluded | YouTube official docs, retrieved 2026-08-04 |
| Reference video facts (Vadact, 30 human players, no AI, no command UI) | External video-analysis tool output supplied by user, 2026-09-14; its inferences about vMenu/vehicle models treated as unverified |
| Rockstar acquired Cfx.re (FiveM) in 2023 | Knowledge; high confidence |
| OneSync ownership migration; task natives run on owning client | Knowledge of FiveM architecture; high confidence — validate in M1 |
| GTA ped pool ~256 and FiveM pool-increase coverage | **Unverified** — T2 empirical test |
| Vanilla GTA military peds/vehicles exist as listed | Knowledge; high confidence |
| EUP requires paid Element Club to stream | Knowledge; med-high — irrelevant under vanilla-first policy |
| Rockstar video policy / Cfx.re PLA specifics | **Unverified** — §5 action items |
| Dev effort 6–10 weeks; RPM/revenue ranges | Estimates, explicitly uncertain |
