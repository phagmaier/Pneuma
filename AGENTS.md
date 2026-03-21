# Pneuma

Tierra-inspired alife simulator in Zig.

## Code Map
- `src/soup.zig` — circular memory, ownership map, scavenge, template search
- `src/cpu.zig` — organism state, registers/stack growth, mutation, maintenance cost
- `src/op.zig` — opcode enum
- `src/scheduler.zig` — execution, energy economy, challenge system, ancestor loading
- `src/main.zig` — startup, seeding, logging

## Hard Invariants
- `orphan=0` and `frag=0` are required in healthy runs
- Soup addresses wrap with `Soup.wrap()`
- Reserved challenge slots are `0..3`
  - `0` = public challenge input
  - `1..3` = challenge trace slots
- Child reservations must be freed on parent death
- Reseeding / ancestor loading must only use genuinely free regions

## Current Baseline
- Keep the reproduction-coupled energy model
  - `HARVEST` gives survival energy plus reproduction reserve
  - `COPY` into reserved child memory consumes reproduction reserve
  - `DIVIDE` also consumes reproduction reserve
- Keep transcript-based harvest validation
  - Stage 1: `AX == target`
  - Stage 2: `AX == target`, `BX == input`
  - Stage 3: `AX == target`, `BX == input`, `CX == first intermediate`
  - Stage 4: `AX == target`, `BX == first intermediate`, `CX == second intermediate`, plus scratch transcript in `mem[1..3]`
- Challenge ladder
  - Stage 1: `inc`
  - Stage 2: `or1`
  - Stage 3: `shl -> or1`
  - Stage 4: `shl -> inc -> or1`
- Epoch boundaries
  - Stage 2 starts at `10k`
  - Stage 3 starts at `50k`
  - Stage 4 starts at `90k`

## Important Current Code State
- `STORE` exists and writes `AX` to challenge trace slot `1 + min(CX, 2)`
- Logging in `main.zig` includes:
  - `harv`, `ph`, `repl`
  - `hTry`, `tgt`, `s2`, `s3`, `s4r`, `s4f`
  - `st`, `tw`
  - ownership diagnostics
- `scheduler.zig` currently also contains the active experiment branch:
  - partial rewards for near-miss stage 3/4 harvests
  - a stage-3-capable immigrant ancestor
  - original stage-2 ancestor still used for initial seeding and pre-stage-3 reseeds

## Ancestors
- Default ancestor: 44-instruction stage-2-capable self-replicator
- Experimental immigrant ancestor: 47-instruction stage-3-capable self-replicator
  - only injected once stage 3 begins
  - also used for low-pop reseeds during stage 3+

## What Failed
- Harder challenge pressure alone did not produce a Red Queen dynamic
- Stage-4 scratch-transcript requirement by itself did not evolve into use
- Earlier stage-3 scratch requirement made runs worse
- Graded rewards + observability alone did not solve the reachability problem

## What Worked Best So Far
- The stage-3-immigrant branch is the first branch to produce clear stage-3 adaptation
- Observed on that branch:
  - `13k` remains healthy
  - `50k` crosses into stage 3 with `s3 > 0`
  - `100k` sustains 47-instruction stage-3-capable lineages through roughly `60k–90k`
  - repeated stage-3 harvests occur
- But it is still not a Red Queen:
  - stage 4 still shuts the regime down
  - `s4r` and `s4f` stay at `0`
  - harvest falls back to `0` after the stage-4 transition

## Current Read
- The main bottleneck is no longer “can stage 3 computation exist?”
- The active bottleneck is “how do stage-3-capable lineages bridge into stage 4?”

## Next Step
Run a stage-4 bridge experiment from the stage-3-immigrant branch.

Best next options:
1. Seed a minimally stage-4-capable immigrant only when stage 4 begins
2. Make stage-4 scratch witness production more evolvable from the stage-3-capable lineage

Recommended first:
- Option 1
- It tests the shortest remaining gap directly and cleanly

## Regression Targets
- `13k` — stage-2 boundary health
- `50k` — stage-3 entry / persistence
- `100k` — stage-4 behavior

For each run, check:
- population and replication
- `harv` / `ph`
- `s3`, `s4r`, `s4f`
- `st`, `tw`
- reseed dependence
- `orphan=0`, `frag=0`
