#!/usr/bin/env python3
"""UVM regression for the AXI4-Lite register block on the Vivado simulator (xsim).

  python scripts/run_regression.py                 # clean design, 8 seeds
  python scripts/run_regression.py --mutate        # also run every injected bug
  python scripts/run_regression.py --seeds 4 --txns 5000 --mutate

Needs Vivado's xvlog/xelab/xsim on PATH (run settings64.bat first, or use
run_sim.bat which does that). Writes:
  docs/test_results.md       per-seed results for the clean design
  docs/mutation_results.md   which checker caught each injected bug
  reports/junit.xml          JUnit report (one testcase per seed / mutant)
  reports/regression.json    everything above, machine-readable
Exit code is 0 only if every clean seed passes and every mutant is caught.
"""
import argparse
import functools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from xml.sax.saxutils import escape

print = functools.partial(print, flush=True)  # live output in run_logs
ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    "sva/axi4l_sva.sv",
    "rtl/axi4l_regs.sv",
    "tb/axi4l_if.sv",
    "tb/axi4l_pkg.sv",
    "tb/tb_top.sv",
]
INCLUDE_DIRS = ["tb/uvm"]
MUTANTS = {
    "BUG_RO_OKAY":      "writes to read-only registers return OKAY instead of SLVERR",
    "BUG_WSTRB":        "WSTRB ignored, every write updates all four bytes",
    "BUG_BVALID_DROP":  "BVALID drops after one cycle even when BREADY is low",
    "BUG_DECODE_ALIAS": "address bit 5 ignored, so 0x20-0x3C alias the real registers",
    "BUG_RDATA_LIVE":   "RDATA read live from the register instead of captured at AR",
}
RESULT_RE = re.compile(r"AXI4L_RESULT (.*)")
SVA_RE = re.compile(r"AXI4L_SVA (.*)")


def tool(name):
    for cand in (name, name + ".bat", name + ".exe"):
        p = shutil.which(cand)
        if p:
            return p
    sys.exit(f"[run] ERROR: {name} not found on PATH - run Vivado's settings64.bat first")


def sh(cmd, cwd, log):
    """Run a command, append its output to log, return the exit code."""
    with open(log, "a", encoding="utf-8", errors="replace") as f:
        f.write("\n$ " + " ".join(cmd) + "\n")
        f.flush()
        proc = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT,
                              shell=(os.name == "nt"))
    return proc.returncode


def build(variant, build_root):
    """Compile + elaborate one variant ('clean' or a BUG_ define)."""
    d = build_root / variant
    if d.exists():
        shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    log = d / "build.log"
    xvlog = [tool("xvlog"), "-sv", "-L", "uvm", "-d", "AXI4L_UVM"]
    if variant != "clean":
        xvlog += ["-d", variant]
    for inc in INCLUDE_DIRS:
        xvlog += ["-i", str(ROOT / inc)]
    xvlog += [str(ROOT / s) for s in SOURCES]
    if sh(xvlog, d, log) != 0:
        return None, log
    xelab = [tool("xelab"), "tb_top", "-L", "uvm", "-s", "snap", "-timescale", "1ns/1ps"]
    if sh(xelab, d, log) != 0:
        return None, log
    return d, log


def run_seed(d, seed, txns, test, cov_target):
    log = d / f"xsim_s{seed}.log"
    if log.exists():
        log.unlink()
    # options go in a file: cmd.exe / xsim.bat would split "a=b" arguments
    opts = d / f"xsim_s{seed}.opts"
    opts.write_text("\n".join([
        "-R", "-sv_seed", str(seed),
        "-testplusarg", f"UVM_TESTNAME={test}",
        "-testplusarg", f"SEED={seed}",
        "-testplusarg", f"NUM_TXN={txns}",
        "-testplusarg", f"COV_TARGET={cov_target}",
    ]) + "\n")
    cmd = [tool("xsim"), "snap", "-f", opts.name]
    t0 = time.time()
    sh(cmd, d, log)
    dt = time.time() - t0
    text = log.read_text(encoding="utf-8", errors="replace")
    m = None
    for m in RESULT_RE.finditer(text):
        pass
    res = {"seed": seed, "time_s": round(dt, 1), "log": str(log)}
    if m is None:
        res.update(status="NO_RESULT")
        tail = "\n".join(text.splitlines()[-25:])
        res["tail"] = tail
        return res
    for kv in m.group(1).split():
        k, _, v = kv.partition("=")
        try:
            v = float(v) if "." in v else int(v)
        except ValueError:
            pass
        res[k] = v
    s = None
    for s in SVA_RE.finditer(text):
        pass
    res["sva_rules"] = s.group(1).strip() if s else ""
    first_err = re.search(r"UVM_ERROR [^@\n]*@[^\n]*", text.split("Report counts")[0]) if res.get("status") != "PASS" else None
    res["first_error"] = first_err.group(0)[:300] if first_err else ""
    return res


def caught_by(r):
    who = []
    if r.get("sb_mismatch", 0):
        who.append("scoreboard")
    if r.get("sva_fail", 0):
        who.append("SVA")
    if r.get("seq_fail", 0):
        who.append("RAL/directed checks")
    if r.get("timeouts", 0):
        who.append("driver timeout")
    if not who and r.get("status") == "FAIL":
        who.append("coverage/monitor")
    return who


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=8)
    ap.add_argument("--txns", type=int, default=3000)
    ap.add_argument("--mutate", action="store_true", help="also run the injected bugs")
    ap.add_argument("--mutant-seeds", type=int, default=3)
    ap.add_argument("--only-mutants", action="store_true")
    ap.add_argument("--cov-target", type=float, default=100.0)
    ap.add_argument("--test", default="axi4l_full_test")
    args = ap.parse_args()

    build_root = Path(tempfile.gettempdir()) / "axi4l_build"
    print(f"[run] build dir: {build_root}")
    summary = {"clean": [], "mutants": {}, "txns": args.txns}
    ok = True

    if not args.only_mutants:
        d, log = build("clean", build_root)
        if d is None:
            print(f"[run] clean build FAILED - see {log}")
            print(log.read_text(errors="replace")[-4000:])
            return 2
        for seed in range(1, args.seeds + 1):
            r = run_seed(d, seed, args.txns, args.test, args.cov_target)
            summary["clean"].append(r)
            if r.get("status") != "PASS":
                ok = False
            print("[run] seed {:2d}  txns {:>5}  checks {:>6}  mismatches {}  sva {}  "
                  "cov_txn {:>6}%  cov_write {:>6}%  {}  ({}s)".format(
                      seed, r.get("txns", "-"), r.get("checks", "-"), r.get("sb_mismatch", "-"),
                      r.get("sva_fail", "-"), r.get("cov_txn", "-"), r.get("cov_write", "-"),
                      r.get("status"), r["time_s"]))
            if r.get("status") != "PASS":
                print("        " + (r.get("first_error") or r.get("tail", ""))[:1500])
        passed = sum(1 for r in summary["clean"] if r.get("status") == "PASS")
        checks = sum(r.get("checks", 0) for r in summary["clean"])
        print(f"[run] {passed}/{args.seeds} seeds passed, {checks} checks")

    if args.mutate:
        for bug, desc in MUTANTS.items():
            d, log = build(bug, build_root)
            if d is None:
                print(f"[{bug}] build FAILED - see {log}")
                ok = False
                summary["mutants"][bug] = {"desc": desc, "runs": [], "killed": 0, "build": "FAILED"}
                continue
            runs = []
            for seed in range(1, args.mutant_seeds + 1):
                r = run_seed(d, seed, args.txns, args.test, args.cov_target)
                runs.append(r)
                print(f"[{bug}] seed {seed}  {r.get('status')}  caught by: {', '.join(caught_by(r)) or '-'}"
                      f"  sva: {r.get('sva_rules', '')}")
            killed = sum(1 for r in runs if r.get("status") == "FAIL")
            summary["mutants"][bug] = {"desc": desc, "runs": runs, "killed": killed}
            print(f"[run] {bug}: {'KILLED' if killed else 'SURVIVED'} by {killed}/{len(runs)} seeds")
            if killed == 0 or any(r.get("status") == "NO_RESULT" for r in runs):
                ok = False

    write_reports(summary, args)
    return 0 if ok else 1


def write_reports(summary, args):
    (ROOT / "docs").mkdir(exist_ok=True)
    (ROOT / "reports").mkdir(exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M")

    clean = summary["clean"]
    if clean:
        tot = lambda k: sum(r.get(k, 0) for r in clean)
        lines = [
            "# Regression results (clean design)", "",
            f"Generated {stamp} by `scripts/run_regression.py` on Vivado xsim, "
            f"{summary['txns']} random transfers per seed plus the RAL and error-injection sequences.", "",
            "| Seed | Transfers | Writes | Reads | Checks | Mismatches | SVA fails | OKAY | SLVERR | DECERR | cg_txn | cg_write | Result |",
            "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:--|",
        ]
        for r in clean:
            lines.append("| {seed} | {txns} | {writes} | {reads} | {checks} | {sb_mismatch} | {sva_fail} | "
                         "{okay} | {slverr} | {decerr} | {cov_txn}% | {cov_write}% | {status} |".format(
                             **{k: r.get(k, "-") for k in ("seed", "txns", "writes", "reads", "checks",
                                                          "sb_mismatch", "sva_fail", "okay", "slverr",
                                                          "decerr", "cov_txn", "cov_write", "status")}))
        passed = sum(1 for r in clean if r.get("status") == "PASS")
        lines += ["", f"**{passed}/{len(clean)} seeds passed, {tot('checks')} checks, "
                      f"{tot('sb_mismatch')} mismatches, {tot('sva_fail')} assertion failures, "
                      f"{tot('txns')} bus transfers.**", ""]
        (ROOT / "docs" / "test_results.md").write_text("\n".join(lines), encoding="utf-8")

    if summary["mutants"]:
        lines = ["# Mutation results", "",
                 f"Generated {stamp}. Each bug is compiled in with a `+define+` and run on "
                 f"{args.mutant_seeds} seeds. A bug is *killed* if the regression fails.", "",
                 "| Injected bug | What it breaks | Killed | Caught by | Assertions that fired |",
                 "|---|---|:-:|---|---|"]
        for bug, m in summary["mutants"].items():
            who = sorted({w for r in m["runs"] for w in caught_by(r)})
            rules = sorted({rule.split(":")[0] for r in m["runs"] for rule in r.get("sva_rules", "").split()})
            lines.append(f"| `{bug}` | {m['desc']} | {m['killed']}/{len(m['runs'])} | "
                         f"{', '.join(who) or '-'} | {', '.join(rules) or '-'} |")
        killed = sum(1 for m in summary["mutants"].values() if m["killed"])
        lines += ["", f"**{killed}/{len(summary['mutants'])} injected bugs caught.**", ""]
        (ROOT / "docs" / "mutation_results.md").write_text("\n".join(lines), encoding="utf-8")

    # JUnit
    cases = []
    for r in clean:
        name = f"clean.seed{r['seed']}"
        body = "" if r.get("status") == "PASS" else \
            f'<failure message="{escape(str(r.get("status")))}">{escape(r.get("first_error") or r.get("tail", ""))}</failure>'
        cases.append(f'  <testcase classname="axi4l" name="{name}" time="{r["time_s"]}">{body}</testcase>')
    for bug, m in summary["mutants"].items():
        body = "" if m["killed"] else '<failure message="mutant survived">no checker failed</failure>'
        t = sum(r["time_s"] for r in m["runs"])
        cases.append(f'  <testcase classname="axi4l.mutation" name="{bug}" time="{t:.1f}">{body}</testcase>')
    fails = sum(1 for c in cases if "<failure" in c)
    xml = ['<?xml version="1.0" encoding="UTF-8"?>',
           f'<testsuite name="axi4lite-uvm" tests="{len(cases)}" failures="{fails}">'] + cases + ["</testsuite>", ""]
    (ROOT / "reports" / "junit.xml").write_text("\n".join(xml), encoding="utf-8")

    slim = json.loads(json.dumps(summary, default=str))
    for r in slim["clean"]:
        r.pop("log", None)
    for m in slim["mutants"].values():
        for r in m["runs"]:
            r.pop("log", None)
    (ROOT / "reports" / "regression.json").write_text(json.dumps(slim, indent=2), encoding="utf-8")
    print("[run] wrote docs/test_results.md, docs/mutation_results.md, reports/junit.xml, reports/regression.json")


if __name__ == "__main__":
    sys.exit(main())
