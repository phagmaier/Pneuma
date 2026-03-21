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
- Energy system: per-instruction costs, maintenance, death + scavenge, passive income
- Mutation system: point (1/2000), insertion (1/5000), deletion (1/5000) on COPY and PULL; cosmic rays every 3 ticks
- Challenge system: epoch-based targets, HARVEST reward (600 energy), T_CHALLENGE timer (1500 ticks)
- Tick loop: shuffle -> execute -> energy deduction -> death -> maintenance -> passive deposits -> cosmic ray -> challenge
- Ancestor: 41-instruction self-replicator with ZERO+LOAD+HARVEST routine, loaded at 5 addresses with 3000 energy each
- Logging: per-500-tick stats (pop, energy, size, births, deaths, harvests, reseeds), genome dump every 10K ticks
- Re-seeding: fresh ancestor every 2000 ticks when pop < 10

## What's NOT yet implemented
- Snapshot saving every 10,000 ticks (save/resume simulation state)
- Better visualization (TUI, spatial layout)
- Phylogenetic tracking (parent-child lineage trees)

## Current focus: experimentation and observation

The simulation is self-sustaining through 74,000+ ticks with continuous replication, harvesting, and natural population oscillation (6-25 organisms). The energy economy is balanced. Next steps are running long experiments, observing emergent behavior, and tuning parameters to encourage more complex evolution.

### Design goal
Avoid Tierra's stagnation problem (equilibrium reached quickly, fitness landscape goes flat once a fast replicator emerges). The energy + challenge system creates a Red Queen dynamic where organisms must evolve increasingly complex computation to survive as challenge difficulty scales with epochs.

### Parameter values
| Parameter | Value | Location |
|-----------|-------|----------|
| MAXENERGY | 10,000 | cpu.zig |
| Starting energy (ancestor) | 3,000 | main.zig |
| E_HARVEST | 600 | scheduler.zig |
| T_CHALLENGE | 1,500 | scheduler.zig |
| Baseline maintenance | 0/tick + age tax | cpu.maintenanceCost() |
| Age tax | (age-8000)/500 after 8000 ticks | cpu.maintenanceCost() |
| Passive deposits/tick | 10,000 | scheduler.doTick() |
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
