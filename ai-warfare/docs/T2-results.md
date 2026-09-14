# T2 Pool Test Results

Template for recording `/test_pool <n>` results (ENGINE-SPEC.md §7, T2 risk:
client/server performance at increasing ped counts). Run on the actual
Windows host with a connected FiveM client; fill in one row per step.

Steps: n = 50, 100, 150, 200, 250, 300.

For each step:
1. Run `/test_pool <n>` on the server console (or as an admin in-game).
2. Let it settle, then record client FPS (F8 console `resmon`, or in-game
   FPS counter) and the `resmon` frame time / resource cost.
3. Run `status` on the server console and record server-side tick/frame
   info if shown, plus any warnings.
4. Note any client-visible symptoms (stutter, rubber-banding, ped pop-in).

| n   | Client FPS (avg) | Client resmon (ms, top offenders) | Server `status` notes | Symptoms | Timestamp |
|-----|-------------------|-------------------------------------|------------------------|----------|-----------|
| 50  |                   |                                      |                         |          |           |
| 100 |                   |                                      |                         |          |           |
| 150 |                   |                                      |                         |          |           |
| 200 |                   |                                      |                         |          |           |
| 250 |                   |                                      |                         |          |           |
| 300 |                   |                                      |                         |          |           |

## Notes

(Add any observations about where FPS drops off sharply, whether the drop is
client-bound or server-bound, and recommended ped-count ceiling for M1/M2.)
