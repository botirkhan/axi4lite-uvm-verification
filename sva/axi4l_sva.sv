// axi4l_sva.sv
// AXI4-Lite handshake assertions, bound to the slave ports of axi4l_regs.
//
// Slave-side rules (check the DUT):
//   A1  BVALID, once high, stays high until BREADY (and BRESP is stable)
//   A2  RVALID, once high, stays high until RREADY (RDATA/RRESP stable)
//   A3  A new write response only after both an AW and a W handshake
//   A4  A new read response only after an AR handshake
//   A5  BVALID/RVALID are low right after reset
//   A6  Slave outputs never X/Z out of reset
// Master-side rules (check the testbench driver):
//   M1  AWVALID stays high until AWREADY; AWADDR stable while waiting
//   M2  WVALID stays high until WREADY; WDATA/WSTRB stable while waiting
//   M3  ARVALID stays high until ARREADY; ARADDR stable while waiting
//
// Every failure increments axi4l_sva_pkg::fail_count so the testbench can
// report it. Under +define+AXI4L_UVM failures are also UVM errors.
`timescale 1ns/1ps

package axi4l_sva_pkg;
  int unsigned fail_count = 0;
  int unsigned fail_by_rule[string];
  function automatic void note_fail(string rule);
    fail_count++;
    if (fail_by_rule.exists(rule)) fail_by_rule[rule]++;
    else fail_by_rule[rule] = 1;
  endfunction
endpackage

module axi4l_sva #(
  parameter int ADDR_W = 12
) (
  input logic              clk,
  input logic              rst_n,
  input logic [ADDR_W-1:0] s_awaddr,
  input logic              s_awvalid,
  input logic              s_awready,
  input logic [31:0]       s_wdata,
  input logic [3:0]        s_wstrb,
  input logic              s_wvalid,
  input logic              s_wready,
  input logic [1:0]        s_bresp,
  input logic              s_bvalid,
  input logic              s_bready,
  input logic [ADDR_W-1:0] s_araddr,
  input logic              s_arvalid,
  input logic              s_arready,
  input logic [31:0]       s_rdata,
  input logic [1:0]        s_rresp,
  input logic              s_rvalid,
  input logic              s_rready
);
`ifdef AXI4L_UVM
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `define SVA_FAIL(rule, msg) begin axi4l_sva_pkg::note_fail(rule); `uvm_error("SVA", {rule, ": ", msg}) end
`else
  `define SVA_FAIL(rule, msg) begin axi4l_sva_pkg::note_fail(rule); $error("SVA %s: %s", rule, msg); end
`endif

  // handshake counters (count completed handshakes, pre-edge view)
  int unsigned aw_hs, w_hs, b_hs, ar_hs, r_hs;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_hs <= 0; w_hs <= 0; b_hs <= 0; ar_hs <= 0; r_hs <= 0;
    end else begin
      if (s_awvalid && s_awready) aw_hs <= aw_hs + 1;
      if (s_wvalid  && s_wready)  w_hs  <= w_hs  + 1;
      if (s_bvalid  && s_bready)  b_hs  <= b_hs  + 1;
      if (s_arvalid && s_arready) ar_hs <= ar_hs + 1;
      if (s_rvalid  && s_rready)  r_hs  <= r_hs  + 1;
    end
  end

  // "new" response = valid now, and last cycle was not a stalled valid
  logic b_stall_d, r_stall_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b_stall_d <= 1'b0;
      r_stall_d <= 1'b0;
    end else begin
      b_stall_d <= s_bvalid && !s_bready;
      r_stall_d <= s_rvalid && !s_rready;
    end
  end
  wire b_new = s_bvalid && !b_stall_d;
  wire r_new = s_rvalid && !r_stall_d;

  // every property: sampled on clk, disabled while in reset
  `define CK @(posedge clk) disable iff (!rst_n)

  // ---------------------------------------------------------------- slave
  A1_bvalid_hold: assert property (`CK s_bvalid && !s_bready |=> s_bvalid && $stable(s_bresp))
    else `SVA_FAIL("A1_bvalid_hold", "BVALID dropped or BRESP changed before BREADY")

  A2_rvalid_hold: assert property (`CK s_rvalid && !s_rready |=> s_rvalid && $stable(s_rdata) && $stable(s_rresp))
    else `SVA_FAIL("A2_rvalid_hold", "RVALID dropped or RDATA/RRESP changed before RREADY")

  A3_b_after_aw_w: assert property (`CK b_new |-> (aw_hs > b_hs) && (w_hs > b_hs))
    else `SVA_FAIL("A3_b_after_aw_w", "write response without both AW and W handshakes")

  A4_r_after_ar: assert property (`CK r_new |-> (ar_hs > r_hs))
    else `SVA_FAIL("A4_r_after_ar", "read response without an AR handshake")

  A6_no_x: assert property (`CK !$isunknown({s_awready, s_wready, s_bvalid, s_arready, s_rvalid,
                                         (s_bvalid ? s_bresp : 2'b00),
                                         (s_rvalid ? {s_rresp, s_rdata} : 34'h0)}))
    else `SVA_FAIL("A6_no_x", "X/Z on a slave output")

  // A5 is checked on the reset release edge, so it is not disabled by reset
  A5_reset_quiet: assert property (@(posedge clk) disable iff (1'b0)
                                   $rose(rst_n) |-> !s_bvalid && !s_rvalid)
    else `SVA_FAIL("A5_reset_quiet", "BVALID/RVALID high out of reset")

  // ---------------------------------------------------------------- master
  M1_aw_hold: assert property (`CK s_awvalid && !s_awready |=> s_awvalid && $stable(s_awaddr))
    else `SVA_FAIL("M1_aw_hold", "AWVALID dropped or AWADDR changed before AWREADY")

  M2_w_hold: assert property (`CK s_wvalid && !s_wready |=> s_wvalid && $stable(s_wdata) && $stable(s_wstrb))
    else `SVA_FAIL("M2_w_hold", "WVALID dropped or WDATA/WSTRB changed before WREADY")

  M3_ar_hold: assert property (`CK s_arvalid && !s_arready |=> s_arvalid && $stable(s_araddr))
    else `SVA_FAIL("M3_ar_hold", "ARVALID dropped or ARADDR changed before ARREADY")

  // ---------------------------------------------------------------- covers
`ifndef VERILATOR
  C1_b_stall8:   cover property (`CK s_bvalid && !s_bready [*8] ##1 s_bready);
  C2_r_stall8:   cover property (`CK s_rvalid && !s_rready [*8] ##1 s_rready);
  C3_aw_w_same:  cover property (`CK s_awvalid && s_awready && s_wvalid && s_wready);
  C4_w_first:    cover property (`CK s_wvalid && s_wready && !s_awvalid ##[1:4] s_awvalid && s_awready);
  C5_rw_overlap: cover property (`CK s_bvalid && s_rvalid);
`endif

  `undef SVA_FAIL
  `undef CK
endmodule
