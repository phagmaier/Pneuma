# Pneuma

Tierra-inspired alife simulator in Zig.

## Code Map
- `src/soup.zig` — circular memory, ownership map, scavenge, template search
- `src/cpu.zig` — organism state, lineage tags, registers/stack growth, mutation, maintenance cost
- `src/op.zig` — opcode enum
- `src/scheduler.zig` — execution, energy economy, challenge system, ancestor loading, immigrant injection/reseed policy
- `src/main.zig` — startup, CLI experiment config, periodic logging
- `run_seed_sweep.sh` — parameter sweep runner
- `summarize_sweeps.sh` — sweep log summarizer

## Hard Invariants
- `orphan=0` and `frag=0` are required in healthy runs
- Soup addresses wrap with `Soup.wrap()`
- Reserved challenge slots are `0..3`
  - `0` = public challenge input
  - `1..3` = challenge trace slots
- Child reservations must be freed on parent death
- Reseeding / ancestor loading must only use genuinely free regions

## Stable Baseline
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
- `STORE` writes `AX` to challenge trace slot `1 + min(CX, 2)`
- Partial rewards remain enabled for near-miss stage 3/4 harvests

## Ancestors And Lineages
- Default ancestor: 44-instruction stage-2-capable self-replicator
  - lineage tag: `dflt`
  - used for initial seeding and pre-stage-3 low-pop reseeds
- Stage-3 immigrant ancestor: 47-instruction stage-3-capable self-replicator
  - lineage tag: `stg3`
  - injected once when stage 3 begins
  - used for low-pop reseeds during stage 3
- Stage-4 immigrant ancestor: 64-instruction self-replicator with explicit scratch-transcript production
  - lineage tag: `stg4`
  - injected once by the configurable stage-4 bridge experiment
  - can also be used for low-pop reseeds during stage 4

## Current Winning Stage-4 Bridge Family
- Strongest config family so far:
  - stage-4 injection at `tick:93000`
  - stage-4 immigrant energy `3000`
  - stage-4 low-pop reseeds use the stage-4 ancestor
- Main sweep result:
  - delayed injection at `93000` beats `88500`, `90000`, and transition injection on robustness
  - stage-4 low-pop reseeds beat stage-3 low-pop reseeds
  - immigrant energy mattered much less than timing and reseed policy
- Seed 3 dies before stage 4 across configs
  - treat that as a separate stage-3 robustness problem
  - do not let it drive the stage-4 bridge decision

## Current Read
- The bridge experiment worked well enough to establish a new default family
- The active bottleneck is no longer “can stage-4-capable behavior exist?”
- The active bottleneck is now transfer:
  - do `dflt` or `stg3` lineages ever produce stage-4 partial/full events?
  - if yes, when?
  - if no, stage-4 capability is staying inside `stg4`

## Logging And Diagnostics
- Periodic logs in `main.zig` already include:
  - `harv`, `ph`, `repl`
  - `hTry`, `tgt`, `s2`, `s3`, `s4r`, `s4f`
  - `st`, `tw`
  - lineage census: `lineages`, `harvestedBy`, `replBy`
  - ownership diagnostics
- Noteworthy harvest events are printed with lineage labels
- `summarize_sweeps.sh` currently summarizes total stage-4 partial/full events, not transfer by lineage
  - it now also reports lineage-specific stage-4 partial/full counts and first ticks

## What Failed
- Harder challenge pressure alone did not produce a Red Queen dynamic
- Stage-4 scratch-transcript requirement by itself did not evolve into use
- Earlier stage-3 scratch requirement made runs worse
- Graded rewards + observability alone did not solve the reachability problem

## What Worked Best So Far
- The stage-3-immigrant branch was the first branch to show clear stage-3 adaptation
- The stage-4 bridge branch found a robust surviving family:
  - healthy at `13k`
  - crosses into stage 3 with `s3 > 0`
  - reaches stage 4 with persistent stage-4 behavior on some seeds
- But the surviving strong runs still look immigrant-dominated
  - final lineage mixes like `[0,0,7]` and `[0,6,8]` suggest stage-4 behavior may be concentrated in `stg4`

## Next Step
- Freeze the new experiment baseline:
  - stage-4 injection at `93000`
  - stage-4 immigrant energy `3000`
  - stage-4 low-pop reseeds use the stage-4 ancestor
- Add transfer-focused reporting:
  - `dflt` stage-4 partials/fulls
  - `stg3` stage-4 partials/fulls
  - `stg4` stage-4 partials/fulls
  - first-seen tick by lineage if practical
- Re-run a smaller confirmation set on that single baseline across more seeds
- Use the results to decide the next design step:
  - if stage-4 events remain entirely `stg4`, make stage-4 witness production more evolvable from stage 3
  - if transfer appears, keep refining from this baseline

## Regression Targets
- `13k` — stage-2 boundary health
- `50k` — stage-3 entry / persistence
- `100k` — stage-4 behavior and transfer

For each run, check:
- population and replication
- `harv` / `ph`
- `s3`, `s4r`, `s4f`
- lineage counts at end and during stage 4
- whether any `dflt` or `stg3` lineage produces stage-4 partial/full events
- reseed dependence
- `orphan=0`, `frag=0`
