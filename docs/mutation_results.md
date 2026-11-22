# Mutation results

Generated 2026-11-22 13:59. Each bug is compiled in with a `+define+` and run on 3 seeds. A bug is *killed* if the regression fails.

| Injected bug | What it breaks | Killed | Caught by | Assertions that fired |
|---|---|:-:|---|---|
| `BUG_RO_OKAY` | writes to read-only registers return OKAY instead of SLVERR | 3/3 | RAL/directed checks, scoreboard | - |
| `BUG_WSTRB` | WSTRB ignored, every write updates all four bytes | 3/3 | scoreboard | - |
| `BUG_BVALID_DROP` | BVALID drops after one cycle even when BREADY is low | 3/3 | RAL/directed checks, SVA, driver timeout | A1_bvalid_hold |
| `BUG_DECODE_ALIAS` | address bit 5 ignored, so 0x20-0x3C alias the real registers | 3/3 | RAL/directed checks, scoreboard | - |
| `BUG_RDATA_LIVE` | RDATA read live from the register instead of captured at AR | 3/3 | RAL/directed checks, scoreboard | - |

**5/5 injected bugs caught.**
