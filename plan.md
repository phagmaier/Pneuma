# Pneuma Implementation Plan

What you have working: soup, ownership map, CPU struct, opcode enum, scheduler dispatch,
template search, MAL, DIVIDE (returns flag), basic arithmetic/stack/flow instructions.

What's left, in the order you should do it.

---

## Phase 1: COPY instruction + Seed Ancestor (do this first, nothing works without it)

### 1a. Add a COPY opcode

The ancestor needs to copy itself instruction-by-instruction. You need an instruction that
copies the instruction at address `[BX]` to address `[AX]` (where AX must be within owned
memory — the child's allocated block).

- Add `copy` to the Op enum (it becomes opcode 0x1F or bump movAR to make room — or just
  append it after movAR as the 32nd opcode). You have 31 opcodes now, so adding one more
  gives you 32 (fits in 5 bits, which is what the spec wants).
- In the execute switch, the logic is:
  - Read `soup.mem[wrap(BX)]` to get the source instruction
  - Write it to `soup.mem[wrap(AX)]` — but ONLY if AX is within the child's allocated
    memory (between `cpu.childStart` and `cpu.childStart + cpu.childSize`). If it's not
    in the child's region, do nothing (fail silently).
  - This is where **mutation** happens (see Phase 2), but skip mutation for now and just
    do the raw copy.

### 1b. Write the seed ancestor

This is the hand-written self-replicating program. You write it as an array of opcodes and
load it into the soup at startup. Here's the logic it needs to perform:

```
1. Find own start:
   - Place a NOP template (e.g., NOP_1 NOP_1 NOP_0 NOP_0) right after a label
   - Execute ADRB to search backward for the complement (NOP_0 NOP_0 NOP_1 NOP_1)
   - That complement is at the END of the organism, so ADRB finds it and AX = address
     of the instruction right after it (which wraps to the start)
   - PUSH_A to save start address

2. Find own end:
   - Place the complement template (NOP_0 NOP_0 NOP_1 NOP_1)
   - Execute ADRF to search forward — finds the end marker
   - AX = address right after the end template

3. Calculate length:
   - POP_B (BX = start address)
   - SUB_AB (CX = AX - BX = length)
   - PUSH_A (save end address)
   - PUSH_C (save length... actually you just need CX for MAL)

4. Allocate child memory:
   - MAL — uses CX as size, allocates, puts child start in AX

5. Set up copy loop:
   - You need BX = source pointer (parent start), AX = dest pointer (child start),
     CX = counter (length)
   - Pop what you saved to get these into the right registers
   - You may need to juggle with PUSH/POP/MOV to get things arranged

6. Copy loop:
   - Place a NOP template to mark the loop top
   - COPY (copies soup[BX] to soup[AX])
   - INC_A (advance dest pointer)
   - INC_B (advance source pointer)
   - DEC_C (decrement counter)
   - IF_CZ (if counter == 0, skip next instruction)
   - ADRB to jump back to loop template (when CX != 0, this finds the loop marker)
     Actually: IF_CZ skips the NEXT instruction when CX != 0. So when CX == 0 you
     fall through to ADRF which jumps to the divide section. When CX != 0 you execute
     the skipped instruction...

   Think about this carefully. The standard Tierra pattern is:
   - DEC_C
   - IF_CZ → if CX IS zero, execute next (jump to divide). If CX is NOT zero, skip it.
   - ADRF [template for end/divide section] ← this gets EXECUTED when CX==0
   - ADRB [template for copy loop top] ← this gets EXECUTED when CX!=0 (skipped ADRF)

   Wait, that's wrong too. IF_CZ means "if CX == 0, execute next; else skip next."
   So:
   - CX == 0 → execute ADRF (find divide section) → jump there
   - CX != 0 → skip ADRF → fall through to ADRB (find loop top) → jump back

   But you need a JMP/CALL to actually jump. ADRF just puts the address in AX.
   In Tierra the pattern uses CALL or just sets IP. You could do:
   - ADRF [divide template]   ← when CX==0, AX = divide address
   - ADRB [loop template]     ← when CX!=0, AX = loop top address
   - Then somehow jump to AX. You don't have a raw JMP, but you can use CALL
     (which pushes return address — wastes a stack slot but works) or you could
     add a JMP_A instruction.

   Simplest approach: just use CALL to jump. The ancestor won't RET from these
   calls but it doesn't matter — it divides and the child starts fresh.

   Work this out on paper first. Write out each instruction with its index, trace
   through the registers and stack manually for one full replication cycle. This is
   the most important debugging you'll do on this project.

### 1c. Loading the ancestor into the soup

In main.zig (or a new seed.zig file):
- Create an array of u32 opcodes representing the ancestor
- Pick a starting position in the soup (e.g., address 0 or some offset)
- Write each opcode into soup.mem[start + i]
- Set soup.occupied[start + i] = organism_id (0 for the first organism)
- Create a Cpu with that start address and size = ancestor length
- Add it to the scheduler's cpu list
- Optionally place 2-5 copies at different locations for safety

### 1d. Test it

Before adding ANYTHING else, verify the ancestor can replicate:
- Run the scheduler loop, executing one instruction per CPU per tick
- Print the IP, registers, and stack after each instruction
- Trace through manually and confirm it finds its start, finds its end,
  calculates the right length, allocates, copies every instruction, and divides
- After divide, confirm the child appears in the CPU list and can also replicate
- Run for ~1000 ticks and confirm population grows

---

## Phase 2: Main Loop + Death + Mutation

### 2a. The main scheduler loop

In scheduler.zig, add a `step()` or `tick()` method that:
1. Shuffles the cpu list (random execution order per tick — use `rand.shuffle()` or
   Fisher-Yates on the ArrayList's items slice)
2. Iterates through each CPU and calls `execute()`
3. If execute returns true (divide happened):
   - Create a new Cpu: id = next_id, start = parent.childStart, size = parent.childSize,
     ip = parent.childStart
   - Reset parent's childStart and childSize to 0
   - Append the new Cpu to the list
   - Increment next_id (add a `nextId: u32` field to Scheduler)
4. Increment tick counter
5. Apply cosmic ray mutation (see 2c)

Wire this up in main.zig: create scheduler, seed ancestor, loop calling step().

### 2b. Death

For now (before energy), organisms need some death condition or you'll run out of memory.
Options:
- **Age-based reaper**: if population exceeds a threshold (e.g., soup_size / average_organism_length),
  kill the oldest organism
- **Simple reaper**: when population > MAX_POP, kill the oldest organism each tick

When an organism dies:
- Call `soup.free(cpu.start, cpu.size)` to NULL out ownership
- Leave the instructions in place (fossil layer)
- Call `cpu.deinit(allocator)` to free registers/stack
- Remove it from the cpu list (use `swapRemove` for O(1) removal — order doesn't matter
  since you shuffle each tick anyway)

Be careful with removal during iteration. Best approach: collect indices to remove in a
separate list, then remove them in reverse order after the iteration.

### 2c. Mutation

**Copy mutation** (in the COPY instruction handler):
- After reading the source instruction but before writing to dest:
  - Roll a random number. If < 0.002 (1/500): replace the instruction with `Op.randOp(rand)`
  - Roll again. If < 0.0005 (1/2000): insertion mutation — write a random instruction at dest,
    but DON'T advance the source pointer (child gets an extra instruction). You'll need to
    increase childSize by 1 and re-claim one more slot of memory.
  - Roll again. If < 0.0005 (1/2000): deletion — advance the source pointer without writing
    (child is 1 shorter). Decrease childSize by 1.
- Insertion/deletion are tricky to get right. Start with just point mutation. Add
  insertion/deletion later once basic replication works.

**Cosmic ray mutation** (once per tick in the step function):
- Pick a random address in the soup (0 to SIZE-1)
- Replace soup.mem[address] with Op.randOp(rand)
- This affects everything — living code, dead code, empty space

### 2d. Test it

- Run for 10,000+ ticks
- Print population count every 100 ticks
- You should see population grow, then stabilize when the reaper kicks in
- After a while you should see parasites emerge — shorter organisms (< ancestor length)
  that still replicate. This is the classic Tierra result.

---

## Phase 3: Implement the remaining stub instructions

These are all currently `{}` in your switch. Implement them one at a time.

### 3a. SCAN

Like `search()` but searches ALL memory (not just own code). The difference from ADRF/ADRB
is:
- ADRF/ADRB: in standard Tierra, these only search within the organism's own memory. Your
  current search() searches the whole soup, which actually makes it behave like SCAN already.
  You have two choices:
  1. Restrict ADRF/ADRB to only match within `cpu.start` to `cpu.start + cpu.size`, then
     SCAN searches everything (this is spec-correct)
  2. Keep ADRF/ADRB as-is (searching everything) and make SCAN identical but with alternating
     forward/backward search pattern

- SCAN reads the NOP template after itself (just like ADRF), searches outward alternating
  forward/backward at increasing distances
- Returns match address in AX, or max_u32 (as -1 equivalent) if not found within SIZE/2

### 3b. PULL

- Copies CX instructions from address AX (anywhere in soup) to address BX (must be within
  own memory)
- Cap CX at 64
- For each instruction: read soup.mem[wrap(AX + i)], write to soup.mem[wrap(BX + i)]
- Check that each destination address (BX + i) is owned by this CPU before writing
- This is where mutation also applies (same rates as COPY)

### 3c. INJECT

- Writes CX instructions from address AX (own memory) to address BX (anywhere)
- Cap CX at 32
- For each instruction: read soup.mem[wrap(AX + i)], write to soup.mem[wrap(BX + i)]
- Does NOT change ownership of the target addresses
- No mutation on inject (it's deliberate writing, not copying for reproduction)

### 3d. MERGE

- Extends organism boundary to absorb CX adjacent unowned slots starting at AX
- AX must be immediately adjacent to the organism (either cpu.start - 1 going backward,
  or cpu.start + cpu.size going forward)
- Each target slot must have `occupied[slot] == null` — can't merge living organisms
- For each valid slot: set `occupied[slot] = cpu.id`, increment cpu.size (or decrement
  cpu.start and increment cpu.size if merging backward)

### 3e. HARVEST

- If AX == current challenge target AND organism hasn't harvested this period: add E_HARVEST
  to energy
- You'll need a `harvested: bool` field on Cpu, reset each challenge period
- Skip this until you implement the challenge system (Phase 5 in your spec). For now just
  leave it as a no-op.

### 3f. EXTEND

- AX == 0: add one register (call growRegisters, new size = current + 1). Max 8 total.
  Add 1 to cpu.cost (maintenance per tick).
- AX == 1: add 8 stack slots (call growStack, new size = current + 8). Max 64 total.
  Add 1 to cpu.cost.

### 3g. SHRINK

- AX == 0: remove highest register (realloc smaller). Can't go below 4. Subtract 1 from
  cpu.cost.
- AX == 1: remove 8 stack slots. Can't go below 8. If stackptr > new size, set stackptr
  to new size. Subtract 1 from cpu.cost.

### 3h. MOV_RA and MOV_AR

- MOV_RA: `AX = registers[CX % num_registers]`
- MOV_AR: `registers[CX % num_registers] = AX`
- `num_registers` is `cpu.registers.len`
- The modulo ensures it can't go out of bounds even with arbitrary CX values

---

## Phase 4: Energy System

Only do this after Phase 1-3 are working and you see stable replication + parasites.

### 4a. Add energy costs to execute()

- Every instruction execution: subtract 1 energy (do this at the top of execute, before
  the switch)
- After execute returns, in the tick function: subtract 2 (baseline existence) + cpu.cost
  (hardware maintenance)
- If energy <= 0 at any point: organism dies

### 4b. Energy on DIVIDE

- Child gets `parent.energy / 2` (integer division)
- Parent keeps `parent.energy - child_energy` (gets the remainder)
- Subtract 10 from parent's energy (DIVIDE overhead)

### 4c. Passive energy deposits

In the tick function, after all CPUs execute:
- Pick R_DEPOSIT (1310) random addresses
- For each: if occupied[addr] has an owner, add E_PASSIVE (1) to that CPU's energy
- Cap at MAXENERGY (10,000)

### 4d. Scavenge energy on death

When an organism dies:
- Calculate scavenge = energy / 2
- Store `scavenge / size` energy at each of the organism's former addresses
- You'll need a new array on Soup: `scavenge_energy: []u32` (parallel to mem and occupied)
- When MERGE absorbs an address, add that address's scavenge_energy to the merging organism
  and zero it out

### 4e. Tune it

The first time you turn on energy, everything will probably die immediately. That's normal.
- Start with high ancestor energy (5000+)
- Increase passive deposit rate if population crashes
- Decrease baseline cost if organisms die before reproducing
- The goal is a stable population that fluctuates around a carrying capacity

---

## Phase 5: Challenge System

### 5a. Add challenge state to Scheduler

- `challenge_target: u32` — the current answer
- `challenge_tick: u32` — when the current challenge started
- T_CHALLENGE = 5000

### 5b. Generate challenges

Every T_CHALLENGE ticks, generate a new target:
- Epoch 1 (ticks 0-50,000): random number 0-31
- Epoch 2 (50,000-200,000): result of 2 operations on small numbers
- Epoch 3 (200,000+): result of 3-5 operations

### 5c. Store target at address 0

Overwrite soup.mem[0] with the target value each challenge period. Organisms can read it
by PULLing from address 0.

### 5d. Implement HARVEST

Now fill in the harvest instruction: check AX against challenge_target, award E_HARVEST (80),
set harvested flag. Reset all harvested flags when challenge changes.

---

## Phase 6: Wire up main.zig

Your main.zig currently doesn't do anything. It needs to:

1. Create the scheduler
2. Seed the ancestor(s) into the soup
3. Run the main loop:
   ```
   while (true) {
       scheduler.step();
       if (scheduler.tick % 100 == 0) {
           // print metrics: population, avg length, etc.
       }
   }
   ```

---

## Phase 7: Metrics + Snapshots (do this whenever you want visibility)

### 7a. Basic logging

Every 100 ticks, print or write to a file:
- Population count (cpus.items.len)
- Average organism size
- Max organism size
- Average energy (once energy is implemented)
- Dead memory fraction (count nulls in occupied / SIZE)

### 7b. Phylogenetic tracking

On every divide:
- Record parent_id, child_id, tick, parent genome hash, child genome hash
- Write to a file (CSV is fine)
- A genome hash can be a simple hash of the instructions in the organism's memory region

### 7c. Snapshots

Every 10,000 ticks, dump the full state to a file:
- All of soup.mem
- All of soup.occupied
- All CPU states

---

## Order of attack (TL;DR)

1. Add COPY opcode → write seed ancestor → load into soup → test replication by hand
2. Main loop + reaper (age/population-based death) + cosmic ray mutation
3. Copy mutation (point mutation only at first)
4. Run long, look for parasites
5. Implement SCAN, PULL, INJECT, MERGE, EXTEND, SHRINK, MOV_RA, MOV_AR
6. Energy system + tuning
7. Challenge system + HARVEST
8. Metrics and snapshots
9. Insertion/deletion mutation
10. Long runs and observation
