// axi4l_scoreboard.svh - reference model + checker.
//
// The model is a table built from the RAL model: one entry per register with
// its offset, width, reset value and access policy (RW / RO / W1C / WO).
// Writes update it on OBS_WR_COMMIT; reads snapshot the expected value on
// OBS_RD_ADDR and compare on OBS_RD_DONE. Every response code is checked:
//   unmapped address -> DECERR (read data 0)
//   write to RO      -> SLVERR, no state change
//   read of WO       -> OKAY, data 0
// Block-specific side effect: writing 1s to IRQ_SET sets IRQ_STAT bits.

class axi4l_scoreboard extends uvm_component;
  `uvm_component_utils(axi4l_scoreboard)

  uvm_analysis_imp #(axi4l_obs, axi4l_scoreboard) imp;
  axi4l_reg_block rm;

  typedef struct {
    string         name;
    string         access;
    bit [31:0]     mask;   // implemented bits
    bit [31:0]     value;
  } reg_entry_t;

  typedef struct {
    bit [11:0]  addr;
    bit [31:0]  data;
    axi_resp_e  resp;
  } rd_exp_t;

  protected reg_entry_t     regs[bit [11:0]];
  protected rd_exp_t        rd_exp_q[$];
  protected bit [11:0]      irq_set_off, irq_stat_off;

  int unsigned n_checks, n_mismatch, n_wr, n_rd;
  int unsigned n_okay, n_slverr, n_decerr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp = new("imp", this);
  endfunction

  // call after reset values (e.g. STATUS = hw_status) are final
  function void init_model();
    uvm_reg      rl[$];
    uvm_reg_field fl[$];
    regs.delete();
    rd_exp_q.delete();
    rm.get_registers(rl);
    foreach (rl[i]) begin
      reg_entry_t e;
      bit [11:0]  off = rl[i].get_offset();
      fl.delete();
      rl[i].get_fields(fl);
      e.name   = rl[i].get_name();
      e.access = fl[0].get_access();
      e.mask   = (fl[0].get_n_bits() >= 32) ? 32'hFFFF_FFFF : ((32'h1 << fl[0].get_n_bits()) - 1);
      e.value  = rl[i].get_reset() & e.mask;
      regs[off] = e;
    end
    irq_set_off  = rm.IRQ_SET.get_offset();
    irq_stat_off = rm.IRQ_STAT.get_offset();
  endfunction

  protected function void sb_check(bit ok, string what);
    n_checks++;
    if (!ok) begin
      n_mismatch++;
      `uvm_error("SB_MISMATCH", what)
    end
  endfunction

  static function bit [31:0] strb_mask(bit [3:0] s);
    return {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
  endfunction

  function void write(axi4l_obs o);
    bit [11:0] off = {o.addr[11:2], 2'b00};
    case (o.ev)
      OBS_WR_COMMIT: do_commit(o, off);
      OBS_RD_ADDR:   do_rd_addr(o, off);
      OBS_RD_DONE:   do_rd_done(o);
      default: ;     // OBS_WR_DONE: response already checked at commit
    endcase
  endfunction

  protected function void do_commit(axi4l_obs o, bit [11:0] off);
    axi_resp_e exp;
    n_wr++;
    if (!regs.exists(off))                 exp = RESP_DECERR;
    else if (regs[off].access == "RO")     exp = RESP_SLVERR;
    else                                   exp = RESP_OKAY;
    count_resp(exp);
    sb_check(o.resp == exp, $sformatf("write 0x%03h: BRESP %s, expected %s",
                                   o.addr, o.resp.name(), exp.name()));
    if (exp != RESP_OKAY) return;

    begin
      bit [31:0] bm  = strb_mask(o.strb) & regs[off].mask;
      bit [31:0] old = regs[off].value;
      case (regs[off].access)
        "RW":  regs[off].value = (old & ~bm) | (o.data & bm);
        "W1C": regs[off].value = old & ~(o.data & bm);
        "WO":  if (off == irq_set_off) begin
                 bit [31:0] sm = strb_mask(o.strb) & regs[irq_stat_off].mask;
                 regs[irq_stat_off].value |= (o.data & sm);
               end
        default: `uvm_error("SB", $sformatf("unhandled access %s", regs[off].access))
      endcase
    end
  endfunction

  protected function void do_rd_addr(axi4l_obs o, bit [11:0] off);
    rd_exp_t e;
    e.addr = o.addr;
    if (!regs.exists(off)) begin
      e.data = 32'h0;
      e.resp = RESP_DECERR;
    end else if (regs[off].access == "WO") begin
      e.data = 32'h0;
      e.resp = RESP_OKAY;
    end else begin
      e.data = regs[off].value;
      e.resp = RESP_OKAY;
    end
    rd_exp_q.push_back(e);
  endfunction

  protected function void do_rd_done(axi4l_obs o);
    rd_exp_t e;
    n_rd++;
    if (rd_exp_q.size() == 0) begin
      sb_check(0, "read data with no read address recorded");
      return;
    end
    e = rd_exp_q.pop_front();
    count_resp(e.resp);
    sb_check(o.resp == e.resp, $sformatf("read 0x%03h: RRESP %s, expected %s",
                                      e.addr, o.resp.name(), e.resp.name()));
    sb_check(o.rdata == e.data, $sformatf("read 0x%03h: RDATA 0x%08h, expected 0x%08h",
                                       e.addr, o.rdata, e.data));
  endfunction

  protected function void count_resp(axi_resp_e r);
    case (r)
      RESP_OKAY:   n_okay++;
      RESP_SLVERR: n_slverr++;
      RESP_DECERR: n_decerr++;
      default: ;
    endcase
  endfunction

  function void check_phase(uvm_phase phase);
    if (rd_exp_q.size() != 0)
      `uvm_error("SB", $sformatf("%0d reads never completed", rd_exp_q.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("writes=%0d reads=%0d checks=%0d mismatches=%0d (OKAY=%0d SLVERR=%0d DECERR=%0d)",
                              n_wr, n_rd, n_checks, n_mismatch, n_okay, n_slverr, n_decerr), UVM_LOW)
  endfunction
endclass
