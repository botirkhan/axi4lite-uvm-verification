# AXI4-Lite Register Block — UVM + SVA Verification

[![ci](https://github.com/botirkhan/axi4lite-uvm-verification/actions/workflows/ci.yml/badge.svg)](https://github.com/botirkhan/axi4lite-uvm-verification/actions/workflows/ci.yml)

This repo has a small AXI4-Lite slave (8 registers) and an industry-style **UVM** testbench around it. The testbench has an agent, a scoreboard and a **RAL** register model. It drives constrained-random traffic with random back-pressure and injects SLVERR/DECERR errors. **SystemVerilog Assertions** check the VALID/READY rules, and **functional coverage** is closed to 100% on every seed. Five deliberately injected RTL bugs check that the testbench can actually find problems.

## Results

Vivado xsim 2026.1, UVM 1.2. Each seed runs 3,000 random transfers plus the RAL and error-injection sequences ([full table](docs/test_results.md)).

| | |
|---|---|
| Seeds passing | **8 / 8** |
| Scoreboard + sequence checks | **39,083**, 0 mismatches |
| Bus transfers | 25,104 (OKAY 11,017 · SLVERR 1,540 · DECERR 12,547) |
| Assertion failures | 0 |
| Functional coverage | **100%** on every seed (cg_txn and cg_write) |
| Injected bugs caught | **5 / 5**, each on 3/3 seeds |

Mutation testing: each bug is compiled in with `+define+` ([details](docs/mutation_results.md)).

| Injected bug | What it breaks | Caught by |
|---|---|---|
| `BUG_RO_OKAY` | writes to RO registers return OKAY instead of SLVERR | scoreboard, directed checks |
| `BUG_WSTRB` | WSTRB ignored, so every write updates all four bytes | scoreboard |
| `BUG_BVALID_DROP` | BVALID drops after one cycle even if BREADY is low | **SVA A1** (1,300+ firings per seed), driver timeout |
| `BUG_DECODE_ALIAS` | address bit 5 ignored, so 0x20–0x3C alias real registers | scoreboard, directed checks |
| `BUG_RDATA_LIVE` | RDATA read live from the register, not captured at AR | scoreboard (only visible when a write lands during a read stall) |


## The design

`rtl/axi4l_regs.sv`: 32-bit AXI4-Lite slave with a 4 KB window.

| Offset | Register | Access | Behaviour |
|---|---|---|---|
| 0x00 | CTRL | RW | byte strobes honoured |
| 0x04 | STATUS | RO | mirrors the `hw_status` input; a write returns **SLVERR** |
| 0x08 | SCRATCH0 | RW | |
| 0x0C | SCRATCH1 | RW | |
| 0x10 | IRQ_EN | RW | bits [7:0] |
| 0x14 | IRQ_STAT | W1C | write 1 to clear |
| 0x18 | IRQ_SET | WO | writing 1s sets IRQ_STAT bits; reads return 0 |
| 0x1C | ID | RO | `0xA41C_0100`; a write returns **SLVERR** |
| 0x20+ | — | — | any access returns **DECERR** (read data 0) |

AW and W are accepted independently and in either order, each with its own 1-deep holding register. A write commits once both are held and the B channel is free. One read is in flight at a time, and its read data is captured when AR is accepted.

## The testbench

```
                 +---------------------------- axi4l_env ----------------------------+
 sequences       |  axi4l_agent                                                      |
 (RAL, error,    |  +-----------+   +-----------+  AXI4-Lite  +------------+         |
  random) -----> |  | sequencer |-->|  driver   |============>| axi4l_regs |<- SVA   |
                 |  +-----------+   +-----------+      ||     |   (DUT)    |  (bind) |
 RAL model ----->|   (adapter)      +-----------+      ||     +------------+         |
                 |                  |  monitor  |<=====//                            |
                 |                  +-----------+                                    |
                 |                     | analysis port                               |
                 |          +----------+-----------+                                 |
                 |          v                      v                                 |
                 |   scoreboard (ref model     coverage                              |
                 |   built from the RAL)       (covergroups)                         |
                 +-------------------------------------------------------------------+
```

| Piece | File | What it does |
|---|---|---|
| Driver | `tb/uvm/axi4l_driver.svh` | AXI4-Lite master. One read and one write can be in flight at once, so they overlap. AW and W get independent random delays, so AW-first, W-first and same-cycle orderings all happen. BREADY/RREADY are held low for 0–12 cycles. Every wait has a timeout |
| Monitor | `tb/uvm/axi4l_monitor.svh` | Passive. Reports each write at the cycle it **commits** inside the DUT, before any read accepted on the same edge. This lets the scoreboard predict reads that overlap writes exactly, with no "either value is fine" slack |
| RAL model | `tb/uvm/axi4l_ral.svh` | `uvm_reg_block` with RW / RO / W1C / WO fields, plus the bus adapter |
| Scoreboard | `tb/uvm/axi4l_scoreboard.svh` | Reference model built **from the RAL model** (offsets, widths, reset values, access policies). It checks every BRESP, RRESP and RDATA, including byte strobes, W1C, WO reads and error codes |
| Coverage | `tb/uvm/axi4l_coverage.svh` | `kind × response-stall length × response code`, `kind × register`, `kind × read/write overlap`, read/write interleaving, `AW/W order × response`, WSTRB patterns |
| Sequences | `tb/uvm/axi4l_seqs.svh` | RAL reset check, RAL write/read-back and IRQ (W1C/WO) flow, directed SLVERR/DECERR injection at every stall length, and constrained-random traffic |
| Assertions | `sva/axi4l_sva.sv` | Bound to the DUT. Slave rules: VALID held until READY with stable payload, no B without AW+W, no R without AR, quiet out of reset, no X. Master rules: AW/W/AR VALID and payload stable until READY |

### Assertions

| ID | Rule |
|---|---|
| A1 | BVALID stays high until BREADY; BRESP stable |
| A2 | RVALID stays high until RREADY; RDATA/RRESP stable |
| A3 | a write response only after both an AW and a W handshake |
| A4 | a read response only after an AR handshake |
| A5 | BVALID/RVALID low right after reset |
| A6 | no X/Z on slave outputs |
| M1–M3 | AWVALID / WVALID / ARVALID held, payload stable, until READY (checks the driver) |

## Running it

### Full UVM regression (Vivado xsim, Windows)
Double-click `run_sim.bat`. It finds Vivado, then runs:
```
python scripts/run_regression.py --seeds 8 --txns 3000 --mutate
```
This writes `docs/test_results.md`, `docs/mutation_results.md`, `reports/junit.xml` and `reports/regression.json`. The exit code is non-zero if any seed fails, coverage misses 100%, or a mutant survives.

On Linux, run Vivado's `settings64.sh`, then the same Python command.

### CI (GitHub Actions, Verilator)
`ci/ci.yml` (installed as `.github/workflows/ci.yml`) lints the RTL. It also runs `tb/smoke/tb_smoke.sv`, a non-UVM random test with the same SVA bound, on every push, against the clean RTL and four of the injected bugs. Each bug job must **fail** for CI to pass. Verilator's UVM support is still experimental, so the full UVM environment runs on xsim.

## Layout
```
rtl/axi4l_regs.sv          DUT (+ `ifdef BUG_* mutants)
sva/axi4l_sva.sv           assertion checker (bound to the DUT)
tb/axi4l_if.sv             interface
tb/axi4l_pkg.sv            UVM package (includes tb/uvm/*.svh)
tb/tb_top.sv               UVM top
tb/smoke/tb_smoke.sv       Verilator smoke test for CI
scripts/run_regression.py  xsim regression + mutation runner, JUnit output
ci/ci.yml                  GitHub Actions workflow
docs/                      generated results
```

## License
MIT
