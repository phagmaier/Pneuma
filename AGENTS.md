# Pneuma

Tierra-inspired alife simulator in Zig.

## Files
- `src/soup.zig` — circular memory buffer (131,072 u32 slots), ownership map, scavenge array, template search
- `src/cpu.zig` — organism state (registers, stack, energy), push/pop, pull/inject/merge, mutation
- `src/op.zig` — opcode enum, 34 ops (0x00–0x21 including COPY and LOAD)
- `src/scheduler.zig` — Scheduler struct, execute() dispatch, tick loop, challenge system, ancestor loading
- `src/main.zig` — entry point, seeds 5 ancestor organisms, logging

## What's implemented
Everything in the core simulation is functional and self-sustaining:
- Soup: circular buffer, ownership map, claim/free, template search (ADRF/ADRB/SCAN)
- CPU: 4 registers (expandable to 8), stack depth 8 (expandable to 64), push/pop, grow/shrink
- All 34 opcodes dispatched in scheduler.execute()
- Energy system: per-instruction costs, maintenance, death + scavenge, passive income, harvest-fed reproduction reserve
- Mutation system: point (1/2000), insertion (1/5000), deletion (1/5000) on COPY and PULL; cosmic rays every 3 ticks
- Challenge system: epoch-based targets, HARVEST reward split between survival energy and reproduction reserve, T_CHALLENGE timer (1500 ticks)
- Tick loop: shuffle -> execute -> energy deduction -> death -> maintenance -> passive deposits -> cosmic ray -> challenge
- Ancestor: 41-instruction self-replicator with ZERO+LOAD+HARVEST routine, loaded at 5 addresses with 3000 energy each
- Logging: per-500-tick stats (pop, energy, size, births, deaths, harvests, reseeds), genome dump every 10K ticks
- Re-seeding: fresh ancestor every 2000 ticks when pop < 10

### Since the last major revision
- Ownership invariants were tightened:
  - Address `0` is reserved for the published challenge input
  - Child reservations are freed on parent death
  - `MAL` no longer allows a CPU to stack multiple outstanding child reservations
  - Reseeding/ancestor loading only occurs into genuinely free regions
- Diagnostics were added to logging:
  - `own`, `reserved`, `orphan`, `frag`
  - `orphan=0` and `frag=0` are now expected invariants in healthy runs
- Challenge system was reworked:
  - Soup publishes a public challenge input at address `0`
  - Harvest rewards a derived internal target, not the raw soup value
  - Challenge recipes are now curated by stage rather than fully random
  - Current ladder:
    - Stage 1: `inc`
    - Stage 2: `or1`
    - Stage 3: `shl -> or1`
    - Stage 4: `shl -> inc -> or1`
- Ancestor updated:
  - Harvest routine is now `ZERO -> LOAD -> INC_A -> HARVEST`
  - Ancestor length increased from 41 to 42 instructions

## What's NOT yet implemented
- Snapshot saving every 10,000 ticks (save/resume simulation state)
- Better visualization (TUI, spatial layout)
- Phylogenetic tracking (parent-child lineage trees)

## Current focus: experimentation and observation

The simulator is now mechanically much cleaner than before: ownership leaks are fixed, diagnostics are available, and challenge publication is separated from challenge reward. The current bottleneck is ecological, not correctness.

Recent experiments show:
- The original economy allowed high-energy stagnation in epoch 1
- A harsher passive-income / lower-harvest variant created turnover but mostly pushed the system into marginal survival and reseed dependence
- A derived-target challenge with curated stage recipes is better than both earlier variants:
  - Stage 2 is survivable
  - Harvest can persist past the `10k` boundary
  - But long runs still tend to compress into low-replication, aging lineages instead of sustaining a strong Red Queen dynamic
- A new reproduction-coupled energy model works better than pure anti-coasting pressure:
  - `HARVEST` now gives a modest survival top-up plus a separate reproduction reserve
  - Writing into reserved child memory via `COPY` consumes reproduction reserve
  - `DIVIDE` also requires reproduction reserve
  - Passive inflow and age tax were restored to the gentler baseline while testing this
  - Result: stage 2 remains active through `50k`, with replication still present and invariants intact, though the system still trends toward small-population plateaus instead of a strong arms race
  - This is now the accepted baseline for future experiments

The current goal is to tune the ecology so that:
- Computation remains relevant to harvest
- Long-lived non-replicating lineages cannot coast indefinitely
- The system avoids both trivial equilibrium and simple starvation collapse

### Design goal
Avoid Tierra's stagnation problem (equilibrium reached quickly, fitness landscape goes flat once a fast replicator emerges). The energy + challenge system creates a Red Queen dynamic where organisms must evolve increasingly complex computation to survive as challenge difficulty scales with epochs.

### Parameter values
| Parameter | Value | Location |
|-----------|-------|----------|
| MAXENERGY | 10,000 | cpu.zig |
| Starting energy (ancestor) | 3,000 | main.zig |
| HARVEST survival reward | 150 | scheduler.zig |
| HARVEST reproduction reserve | 384 | scheduler.zig |
| T_CHALLENGE | 1,500 | scheduler.zig |
| Epoch 2 start | 10,000 | scheduler.zig |
| Epoch 3 start | 50,000 | scheduler.zig |
| Epoch 4 start | 90,000 | scheduler.zig |
| Baseline maintenance | 0/tick + age tax | cpu.maintenanceCost() |
| Age tax | (age-8000)/500 after 8000 ticks | cpu.maintenanceCost() |
| Passive deposits/tick | 10,000 | scheduler.doTick() |
| Current passive deposits/tick | 5,000 | scheduler.doTick() |
| Reproduction reserve max | 2,048 | cpu.zig |
| COPY reserve cost into child | 1/write | scheduler.execute() |
| DIVIDE reserve cost | 32 | scheduler.execute() |
| DIVIDE cost | 5 | scheduler.execute() |
| Point mutation rate | 1/2000 | cpu.mutate() |
| Insertion rate | 1/5000 | cpu.mutate() |
| Deletion rate | 1/5000 | cpu.mutate() |
| Cosmic rays | 1 every 3 ticks | scheduler.doTick() |
| PULL cap | 64 | cpu.zig MAXPULL |
| INJECT cap | 32 | cpu.zig MAXINJECT |
| INJECT cost | 3/instruction | cpu.zig INJECTCOST |
| MERGE cost | 2/instruction | cpu.zig MERGECOST |
| EXTEND cost | 50 | cpu.zig EXTENDCOST |
| MAL search range | 20x organism size | scheduler.execute() |
| Re-seed threshold | pop < 10, every 2000 ticks | scheduler.doTick() |
| Soup size | 131,072 | soup.zig SIZE |

## Instruction set (all 34 ops)

### 0x00-0x0E: Arithmetic/stack
NOP_0, NOP_1, OR1, SHL, ZERO, IF_CZ, SUB_AB, SUB_AC, INC_A, INC_B, DEC_C, PUSH_A, POP_A, POP_B, POP_C

### 0x0F-0x16: Memory and flow
ADRF, ADRB, CALL, RET, MOV_AB, MOV_CD, MAL, DIVIDE

### 0x17-0x1A: Cross-boundary
SCAN, PULL, INJECT, MERGE

### 0x1B: Harvest
HARVEST

### 0x1C-0x1D: Hardware evolution
EXTEND, SHRINK

### 0x1E-0x1F: Extended register access
MOV_RA, MOV_AR

### 0x20-0x21: Memory access
COPY — copies mem[BX] to mem[AX] with mutation
LOAD — AX = mem[AX], read soup memory into register

## Conventions
- All addresses wrap mod 131,072 — always use Soup.wrap()
- Fossil layer: soup.free() nulls ownership but never zeroes instruction data
- Registers: AX=0 BX=1 CX=2 DX=3, extras R4+ via EXTEND
- Energy is u32; saturating arithmetic, immediate death check after each deduction
- ADRF/ADRB: template is the NOP sequence at IP+1; complement means NOP_0<->NOP_1
- ADRB searches backward from IP-1 but extracts template from IP+1 (same as ADRF)
- Safe register access: reg()/setReg() in scheduler, getReg() in cpu return 0 for out-of-bounds

## Current conclusions
- The project is not doomed and the design is not inherently flawed
- Energy plus challenge pressure is a viable direction, but the current ecology still allows eventual coasting/stagnation
- Parameter tuning alone was not enough; structural challenge and energy-flow changes were necessary and helped
- The current best baseline is:
  - curated challenge ladder fixed at `inc -> or1 -> shl+or1`
  - ownership diagnostics clean (`orphan=0`, `frag=0`)
  - harvest split into general survival energy plus reproduction reserve
  - gentler passive ecology restored (`PASSIVE_DEPOSITS=5000`, age tax back to `(age-8000)/500`)
- This baseline is better than the previous anti-coasting pass:
  - stage 2 remains replication-active through `50k`
  - the system no longer cleanly collapses at the `10k` boundary
  - but it still settles into small-population stage-2 plateaus rather than sustained escalating adaptation
- The next tuning axis should focus on making stage progression and challenge complexity matter more, not just making starvation harsher
- A later stage-4 epoch has been added so challenge complexity can continue increasing without changing the pre-`50k` baseline
- Because stage 4 starts at `90k`, the usual `13k` and `50k` runs remain regression checks for the accepted baseline, not direct tests of stage 4

## Accepted baseline
- Keep the current reproduction-coupled energy model unless a future experiment clearly outperforms it
- Treat `orphan=0` and `frag=0` as hard invariants during all future runs
- Compare future experiments against this baseline at minimum on:
  - `13k` for the stage-2 boundary
  - `50k` for long-run persistence
  - `100k` when testing stage-4 behavior directly
  - replication, harvests, reseeds, and whether stage 2/3 remain active without collapse
