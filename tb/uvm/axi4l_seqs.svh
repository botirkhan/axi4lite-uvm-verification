// axi4l_seqs.svh - sequences.
//
// axi4l_ral_reset_seq  : RAL front-door read of every readable register vs reset value
// axi4l_ral_rw_seq     : RAL write/read-back of RW registers + W1C/WO interrupt flow
// axi4l_err_seq        : directed error injection (SLVERR / DECERR) at every stall length
// axi4l_random_seq     : constrained-random reads/writes, overlapped, with back-pressure

class axi4l_base_seq extends uvm_sequence #(axi4l_item);
  `uvm_object_utils(axi4l_base_seq)
  axi4l_reg_block rm;
  int unsigned    n_checks, n_fail;

  function new(string name = "axi4l_base_seq");
    super.new(name);
  endfunction

  protected function void expect_eq(string what, uvm_reg_data_t got, uvm_reg_data_t exp);
    n_checks++;
    if (got !== exp) begin
      n_fail++;
      `uvm_error("SEQ_CHECK", $sformatf("%s: got 0x%08h expected 0x%08h", what, got, exp))
    end
  endfunction

  protected function void expect_status(string what, uvm_status_e st, uvm_status_e exp);
    n_checks++;
    if (st != exp) begin
      n_fail++;
      `uvm_error("SEQ_CHECK", $sformatf("%s: status %s expected %s", what, st.name(), exp.name()))
    end
  endfunction
endclass

class axi4l_ral_reset_seq extends axi4l_base_seq;
  `uvm_object_utils(axi4l_ral_reset_seq)
  function new(string name = "axi4l_ral_reset_seq");
    super.new(name);
  endfunction

  task body();
    uvm_reg rl[$];
    rm.get_registers(rl);
    foreach (rl[i]) begin
      uvm_status_e   st;
      uvm_reg_data_t v;
      if (rl[i].get_rights() == "WO") continue;
      rl[i].read(st, v, UVM_FRONTDOOR, .parent(this));
      expect_status({rl[i].get_name(), " reset read"}, st, UVM_IS_OK);
      expect_eq({rl[i].get_name(), " reset value"}, v, rl[i].get_reset());
    end
  endtask
endclass

class axi4l_ral_rw_seq extends axi4l_base_seq;
  `uvm_object_utils(axi4l_ral_rw_seq)
  int unsigned n_loops = 8;
  function new(string name = "axi4l_ral_rw_seq");
    super.new(name);
  endfunction

  task body();
    uvm_status_e   st;
    uvm_reg_data_t v, w;
    axi4l_simple_reg rw_regs[$];
    rw_regs.push_back(rm.CTRL);
    rw_regs.push_back(rm.SCRATCH0);
    rw_regs.push_back(rm.SCRATCH1);
    rw_regs.push_back(rm.IRQ_EN);

    repeat (n_loops) begin
      foreach (rw_regs[i]) begin
        uvm_reg_data_t mask = (rw_regs[i].f.get_n_bits() >= 32) ? 'hFFFF_FFFF
                              : ((1 << rw_regs[i].f.get_n_bits()) - 1);
        w = {$urandom, $urandom} & mask;
        rw_regs[i].write(st, w, UVM_FRONTDOOR, .parent(this));
        expect_status({rw_regs[i].get_name(), " write"}, st, UVM_IS_OK);
        rw_regs[i].read(st, v, UVM_FRONTDOOR, .parent(this));
        expect_status({rw_regs[i].get_name(), " read"}, st, UVM_IS_OK);
        expect_eq({rw_regs[i].get_name(), " read-back"}, v, w);
      end
    end

    // interrupt flow: IRQ_SET (WO) sets bits, IRQ_STAT is W1C
    rm.IRQ_STAT.write(st, 'hFF, UVM_FRONTDOOR, .parent(this));          // clear all
    rm.IRQ_SET.write(st, 'hA5, UVM_FRONTDOOR, .parent(this));
    expect_status("IRQ_SET write", st, UVM_IS_OK);
    rm.IRQ_STAT.read(st, v, UVM_FRONTDOOR, .parent(this));
    expect_eq("IRQ_STAT after IRQ_SET=0xA5", v, 'hA5);
    rm.IRQ_STAT.write(st, 'h05, UVM_FRONTDOOR, .parent(this));          // W1C bits 0,2
    rm.IRQ_STAT.read(st, v, UVM_FRONTDOOR, .parent(this));
    expect_eq("IRQ_STAT after W1C 0x05", v, 'hA0);
    rm.IRQ_STAT.write(st, 'h00, UVM_FRONTDOOR, .parent(this));          // writing 0 clears nothing
    rm.IRQ_STAT.read(st, v, UVM_FRONTDOOR, .parent(this));
    expect_eq("IRQ_STAT after W1C 0x00", v, 'hA0);
  endtask
endclass

// Directed error injection: bus-level items (the RAL refuses to write RO
// registers or touch unmapped addresses, which is exactly what we want here).
class axi4l_err_seq extends axi4l_base_seq;
  `uvm_object_utils(axi4l_err_seq)
  function new(string name = "axi4l_err_seq");
    super.new(name);
  endfunction

  protected task one(axi_kind_e k, bit [11:0] a, int unsigned stall, axi_resp_e exp);
    axi4l_item t = axi4l_item::type_id::create("err");
    start_item(t);
    if (!t.randomize() with { kind == k; addr == a; resp_stall == stall; })
      `uvm_fatal("RAND", "err item randomize failed")
    t.nonblocking = 0;
    finish_item(t);
    n_checks++;
    if (t.resp != exp) begin
      n_fail++;
      `uvm_error("SEQ_CHECK", $sformatf("%s: got %s expected %s", t.convert2string(), t.resp.name(), exp.name()))
    end
  endtask

  task body();
    int unsigned stalls[] = '{0, 1, 2, 4, 9};
    bit [11:0]   unmapped[] = '{12'h020, 12'h03C, 12'h040, 12'h7FC, 12'hFFC};
    foreach (stalls[s]) begin
      one(AXI_WRITE, 12'h004, stalls[s], RESP_SLVERR);   // STATUS (RO)
      one(AXI_WRITE, 12'h01C, stalls[s], RESP_SLVERR);   // ID (RO)
      foreach (unmapped[u]) begin
        one(AXI_WRITE, unmapped[u], stalls[s], RESP_DECERR);
        one(AXI_READ,  unmapped[u], stalls[s], RESP_DECERR);
      end
    end
  endtask
endclass

class axi4l_random_seq extends axi4l_base_seq;
  `uvm_object_utils(axi4l_random_seq)
  int unsigned n_items = 2000;
  function new(string name = "axi4l_random_seq");
    super.new(name);
  endfunction

  task body();
    repeat (n_items) begin
      axi4l_item t = axi4l_item::type_id::create("rnd");
      start_item(t);
      if (!t.randomize()) `uvm_fatal("RAND", "random item randomize failed")
      t.nonblocking = 1;
      finish_item(t);
    end
  endtask
endclass
