# Pneuma

An artificial life simulator inspired by [Tierra](https://en.wikipedia.org/wiki/Tierra_(computer_simulation)), written in Zig. Digital organisms live in a shared circular memory buffer ("soup"), execute their own code, compete for energy and territory, replicate with mutation, and evolve over time.

Pneuma's key departure from Tierra is an **energy + challenge system** designed to prevent the rapid stagnation that plagues classic alife simulators. Instead of reaching equilibrium once a fast replicator emerges, organisms face escalating computational challenges that reward increasingly complex behavior -- a [Red Queen](https://en.wikipedia.org/wiki/Red_Queen_hypothesis) dynamic.

## How it works

### The soup
A circular buffer of 131,072 instruction slots. Each slot holds a single opcode (u32). Memory wraps around, so address 131,071 + 1 = address 0. All memory is globally readable; writing outside your territory requires special instructions.

### Organisms
Each organism owns a contiguous region of the soup and has:
- **Registers**: 4 general-purpose (AX, BX, CX, DX), expandable to 8 via the EXTEND instruction
- **Stack**: depth 8, expandable to 64
- **Energy**: earned through territory (passive income), completing challenges (HARVEST), and scavenging dead organisms. Spent on every instruction executed, maintenance, and replication
- **An instruction pointer** that walks through the soup executing opcodes

### Replication
The ancestor organism is a 41-instruction self-replicator that:
1. Uses template matching (NOP_0/NOP_1 complement patterns) to measure its own length
2. Allocates space for a child (MAL)
3. Copies itself instruction-by-instruction (COPY), with mutations applied during copying
4. Divides (DIVIDE), splitting energy with its offspring

### Mutation
- **Point mutation**: 1/2000 chance per COPY/PULL to replace an instruction with a random opcode
- **Insertion**: 1/5000 chance to insert a random instruction
- **Deletion**: 1/5000 chance to skip copying an instruction
- **Cosmic rays**: every 3 ticks, one random soup address gets a random opcode

### Energy and challenges
Energy is the currency of life. Organisms earn it by:
- **Territory**: 10,000 random energy deposits per tick across the soup. Larger organisms catch more
- **Harvesting**: every 1,500 ticks, a new challenge target is posted. Organisms that compute the correct answer and execute HARVEST earn 600 energy
- **Scavenging**: dead organisms leave 50% of their energy behind, reclaimable via MERGE

Challenges scale with time:
- **Epoch 1** (< 50K ticks): random constant 0-31 (just read it from memory)
- **Epoch 2** (< 200K ticks): 2 arithmetic operations on a small constant
- **Epoch 3** (200K+): 3-5 operations on a small constant

### Cross-boundary warfare
Organisms can interact with each other and unclaimed territory:
- **PULL**: copy foreign code into your own territory (with mutation -- imperfect espionage)
- **INJECT**: write your code into foreign territory (overwrite others' instructions)
- **MERGE**: claim adjacent unoccupied territory, absorbing any scavenged energy

## 34 opcodes

| Range | Instructions |
|-------|-------------|
| Arithmetic/stack | NOP_0, NOP_1, OR1, SHL, ZERO, IF_CZ, SUB_AB, SUB_AC, INC_A, INC_B, DEC_C, PUSH_A, POP_A, POP_B, POP_C |
| Memory/flow | ADRF, ADRB, CALL, RET, MOV_AB, MOV_CD, MAL, DIVIDE |
| Cross-boundary | SCAN, PULL, INJECT, MERGE |
| Challenge | HARVEST |
| Hardware evolution | EXTEND, SHRINK |
| Extended registers | MOV_RA, MOV_AR |
| Memory access | COPY, LOAD |

## Building and running

Requires Zig 0.15.2+.

```bash
zig build run -Doptimize=ReleaseFast
```

Or to build and run separately:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/Evolution
```

For debug builds (with memory leak detection):

```bash
zig build run
```

## Output

The simulation logs stats every 500 ticks:

```
t=500    pop=12  avgE=1842  avgSz=41   szRange=[38,52] terr=504   maxAge=487   harv=8  repl=3  | births=4 deaths=1 reseeds=0 target=17
```

Every 10,000 ticks it dumps the genome of the first 5 organisms in 2-letter mnemonics:

```
[0] id=23 age=312 energy=2100 size=41 start=1000
     code: n1 n1 n0 n0 zr ld hv ab n1 n1 n0 n0 pA af n1 n1 n0 n0 oB sb ml pA n0 n1 oA oA cp ia ib dc iz dv pA ab n0 n1 ca n0 n0 n1 n1
```

## Project structure

```
src/
  soup.zig        -- circular memory buffer, ownership, template search
  cpu.zig         -- organism state, registers, stack, mutation
  op.zig          -- opcode enum (34 ops)
  scheduler.zig   -- execution dispatch, tick loop, challenges, ancestor
  main.zig        -- entry point, seeding, logging
```

## License

MIT / Public Domain (dual-licensed). See [LICENSE](LICENSE).
