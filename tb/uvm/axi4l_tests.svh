// axi4l_tests.svh - tests.
//
// axi4l_full_test (default): RAL reset check -> RAL read/write + IRQ flow ->
//   directed error injection -> constrained-random traffic (+NUM_TXN=N).
//   Fails if any check, SVA or timeout fails, or if functional coverage is
//   below +COV_TARGET (default 100).
// axi4l_ral_test: RAL sequences only (quick smoke).
//
// Plusargs: +SEED=n (just echoed in the summary), +NUM_TXN=n, +COV_TARGET=pct

class axi4l_base_test extends uvm_test;
  `uvm_component_utils(axi4l_base_test)

  axi4l_env        env;
  virtual axi4l_if vif;
  bit [31:0]       hw_status;
  int unsigned     seq_checks, seq_fails;
  int unsigned     num_txn    = 3000;
  real             cov_target = 100.0;
  bit              run_random = 1;
  int unsigned     seed;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = axi4l_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual axi4l_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axi4l_if not set in config_db")
    void'($value$plusargs("NUM_TXN=%d", num_txn));
    void'($value$plusargs("COV_TARGET=%f", cov_target));
    void'($value$plusargs("SEED=%d", seed));
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    // value the hardware drives into STATUS; it is STATUS's reset value too
    hw_status = $urandom;
    vif.hw_status = hw_status;
    env.rm.STATUS.f.set_reset(hw_status);
    env.sb.init_model();

    wait (vif.rst_n === 1'b1);
    repeat (2) @(posedge vif.clk);

    run_seq(axi4l_ral_reset_seq::type_id::create("ral_reset"));
    run_seq(axi4l_ral_rw_seq::type_id::create("ral_rw"));
    if (run_random) begin
      axi4l_random_seq r;
      run_seq(axi4l_err_seq::type_id::create("err"));
      r = axi4l_random_seq::type_id::create("rand");
      r.n_items = num_txn;
      run_seq(r);
    end

    env.agent.drv.wait_idle();
    repeat (20) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask

  protected task run_seq(axi4l_base_seq s);
    s.rm = env.rm;
    s.start(env.agent.sqr);
    seq_checks += s.n_checks;
    seq_fails  += s.n_fail;
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    int unsigned errs   = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
    real         cov_t  = env.cov.txn_coverage();
    real         cov_w  = env.cov.write_coverage();
    int unsigned checks = env.sb.n_checks + seq_checks;
    int unsigned sva    = axi4l_sva_pkg::fail_count;
    bit          pass;
    string       sva_rules = "";

    if (run_random && (cov_t < cov_target || cov_w < cov_target)) begin
      `uvm_error("COV", $sformatf("coverage below target %.1f%%: cg_txn=%.2f%% cg_write=%.2f%%",
                                  cov_target, cov_t, cov_w))
      errs++;
    end
    foreach (axi4l_sva_pkg::fail_by_rule[r])
      sva_rules = {sva_rules, $sformatf("%s:%0d ", r, axi4l_sva_pkg::fail_by_rule[r])};

    pass = (errs == 0);
    $display("AXI4L_RESULT test=%s seed=%0d txns=%0d writes=%0d reads=%0d checks=%0d sb_mismatch=%0d seq_fail=%0d sva_fail=%0d timeouts=%0d uvm_errors=%0d cov_txn=%.2f cov_write=%.2f okay=%0d slverr=%0d decerr=%0d status=%s",
             get_type_name(), seed, env.agent.drv.n_driven, env.agent.mon.n_writes, env.agent.mon.n_reads,
             checks, env.sb.n_mismatch, seq_fails, sva, env.agent.drv.n_timeouts, errs, cov_t, cov_w,
             env.sb.n_okay, env.sb.n_slverr, env.sb.n_decerr, pass ? "PASS" : "FAIL");
    if (sva_rules != "") $display("AXI4L_SVA %s", sva_rules);
    if (pass) $display("*** TEST PASSED ***");
    else      $display("*** TEST FAILED ***");
  endfunction
endclass

class axi4l_full_test extends axi4l_base_test;
  `uvm_component_utils(axi4l_full_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass

class axi4l_ral_test extends axi4l_base_test;
  `uvm_component_utils(axi4l_ral_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    run_random = 0;
  endfunction
endclass
