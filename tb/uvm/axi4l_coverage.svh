// axi4l_coverage.svh - functional coverage, sampled once per completed
// transfer (OBS_WR_DONE / OBS_RD_DONE).
//
// cg_txn   : kind x response-stall x response code (the main closure target),
//            kind x register, kind x overlap, and read/write interleaving
//            (previous transfer kind -> this transfer kind)
// cg_write : AW/W arrival order x response, and WSTRB patterns

class axi4l_coverage extends uvm_subscriber #(axi4l_obs);
  `uvm_component_utils(axi4l_coverage)

  // sampled fields
  axi_kind_e   kind;
  axi_resp_e   resp;
  int unsigned stall;
  int unsigned reg_idx;    // 0..7 = mapped register, 8 = 0x20-0x3C, 9 = beyond
  bit          overlap;
  int unsigned seq_code;   // {prev kind, kind}: 0 RR, 1 RW, 2 WR, 3 WW
  int unsigned order;
  bit [3:0]    strb;

  protected bit        have_prev;
  protected axi_kind_e prev_kind;
  int unsigned         n_sampled;

  covergroup cg_txn;
    option.per_instance = 1;
    cp_kind: coverpoint kind;
    cp_resp: coverpoint resp {
      bins okay   = {RESP_OKAY};
      bins slverr = {RESP_SLVERR};
      bins decerr = {RESP_DECERR};
      illegal_bins exokay = {RESP_EXOKAY};
    }
    cp_stall: coverpoint stall {
      bins stall_0    = {0};
      bins stall_1_2  = {[1:2]};
      bins stall_3_7  = {[3:7]};
      bins stall_8up  = {[8:$]};
    }
    cp_reg: coverpoint reg_idx {
      bins ctrl          = {0};
      bins status        = {1};
      bins scratch0      = {2};
      bins scratch1      = {3};
      bins irq_en        = {4};
      bins irq_stat      = {5};
      bins irq_set       = {6};
      bins id            = {7};
      bins unmapped_near = {8};
      bins unmapped_far  = {9};
    }
    cp_overlap: coverpoint overlap;
    cp_interleave: coverpoint seq_code {
      bins rd_then_rd = {0};
      bins rd_then_wr = {1};
      bins wr_then_rd = {2};
      bins wr_then_wr = {3};
    }
    x_kind_stall_resp: cross cp_kind, cp_stall, cp_resp {
      // reads never return SLVERR in this block
      ignore_bins rd_slverr = binsof(cp_kind) intersect {AXI_READ} &&
                              binsof(cp_resp) intersect {RESP_SLVERR};
    }
    x_kind_reg:     cross cp_kind, cp_reg;
    x_kind_overlap: cross cp_kind, cp_overlap;
  endgroup

  covergroup cg_write;
    option.per_instance = 1;
    cp_order: coverpoint order {
      bins aw_first   = {0};
      bins w_first    = {1};
      bins same_cycle = {2};
    }
    cp_wresp: coverpoint resp {
      bins okay   = {RESP_OKAY};
      bins slverr = {RESP_SLVERR};
      bins decerr = {RESP_DECERR};
    }
    cp_strb: coverpoint strb {
      bins full    = {4'hF};
      bins none    = {4'h0};
      bins single  = {4'h1, 4'h2, 4'h4, 4'h8};
      bins partial = {4'h3, 4'h5, 4'h6, 4'h7, 4'h9, 4'hA, 4'hB, 4'hC, 4'hD, 4'hE};
    }
    x_order_resp: cross cp_order, cp_wresp;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_txn   = new();
    cg_write = new();
  endfunction

  function void write(axi4l_obs t);
    if (t.ev != OBS_WR_DONE && t.ev != OBS_RD_DONE) return;
    kind    = t.kind;
    resp    = t.resp;
    stall   = t.stall;
    overlap = t.overlap;
    order   = t.order;
    strb    = t.strb;
    if (t.addr <= 12'h01F)      reg_idx = t.addr[4:2];
    else if (t.addr <= 12'h03F) reg_idx = 8;
    else                        reg_idx = 9;
    if (have_prev) begin
      seq_code = (prev_kind == AXI_WRITE ? 2 : 0) + (kind == AXI_WRITE ? 1 : 0);
    end else begin
      // first transfer: no interleave sample (map onto its own kind pair)
      seq_code = (kind == AXI_WRITE) ? 3 : 0;
    end
    prev_kind = kind;
    have_prev = 1;
    n_sampled++;
    cg_txn.sample();
    if (kind == AXI_WRITE) cg_write.sample();
  endfunction

  function real txn_coverage();
    return cg_txn.get_inst_coverage();
  endfunction

  function real write_coverage();
    return cg_write.get_inst_coverage();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf({"samples=%0d  cg_txn=%.2f%%  (kind x stall x resp=%.2f%%, kind x reg=%.2f%%, ",
                                "overlap=%.2f%%, interleave=%.2f%%)  cg_write=%.2f%%  (order x resp=%.2f%%, strb=%.2f%%)"},
                               n_sampled, cg_txn.get_inst_coverage(),
                               cg_txn.x_kind_stall_resp.get_inst_coverage(),
                               cg_txn.x_kind_reg.get_inst_coverage(),
                               cg_txn.x_kind_overlap.get_inst_coverage(),
                               cg_txn.cp_interleave.get_inst_coverage(),
                               cg_write.get_inst_coverage(),
                               cg_write.x_order_resp.get_inst_coverage(),
                               cg_write.cp_strb.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
