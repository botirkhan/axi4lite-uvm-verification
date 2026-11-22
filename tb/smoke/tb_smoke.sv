// tb_smoke.sv - small non-UVM testbench for CI (Verilator --timing).
//
// Random reads/writes with random READY back-pressure, checked against a
// simple model, with the same SVA checker bound to the DUT. The full UVM
// environment (RAL, scoreboard, coverage closure) runs on xsim; this keeps
// the RTL + assertions under a regression on every push.
//
// Prints "SMOKE_RESULT pass=<0|1> checks=<n> errors=<n> sva_fail=<n>".
`timescale 1ns/1ps
module tb_smoke;
  logic        clk = 1'b0, rst_n = 1'b0;
  logic [11:0] awaddr = '0, araddr = '0;
  logic [2:0]  awprot = '0, arprot = '0;
  logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
  logic [31:0] wdata = '0;
  logic [3:0]  wstrb = '0;
  wire         awready, wready, bvalid, arready, rvalid, irq;
  wire  [1:0]  bresp, rresp;
  wire  [31:0] rdata;
  logic [31:0] hw_status = 32'h1234_5678;

  always #5 clk = ~clk;

  axi4l_regs #(.ADDR_W(12)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_awaddr(awaddr), .s_awprot(awprot), .s_awvalid(awvalid), .s_awready(awready),
    .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
    .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_araddr(araddr), .s_arprot(arprot), .s_arvalid(arvalid), .s_arready(arready),
    .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
    .hw_status(hw_status), .irq(irq));

  bind axi4l_regs axi4l_sva #(.ADDR_W(ADDR_W)) u_sva (.*);

  // ---------------------------------------------------------------- model
  logic [31:0] m_ctrl = '0, m_s0 = '0, m_s1 = '0;
  logic [7:0]  m_en = '0, m_stat = '0;
  int unsigned checks = 0, errors = 0;

  function automatic logic [31:0] smask(input logic [3:0] s);
    return {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
  endfunction

  function automatic logic [1:0] exp_wresp(input logic [11:0] a);
    if (a[11:5] != 0) return 2'b11;
    if (a[4:2] == 3'd1 || a[4:2] == 3'd7) return 2'b10;
    return 2'b00;
  endfunction

  function automatic logic [31:0] exp_rdata(input logic [11:0] a);
    if (a[11:5] != 0) return 32'h0;
    case (a[4:2])
      3'd0: return m_ctrl;
      3'd1: return hw_status;
      3'd2: return m_s0;
      3'd3: return m_s1;
      3'd4: return {24'h0, m_en};
      3'd5: return {24'h0, m_stat};
      3'd6: return 32'h0;
      default: return 32'hA41C_0100;
    endcase
  endfunction

  task automatic model_write(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s);
    logic [31:0] m = smask(s);
    if (exp_wresp(a) != 2'b00) return;
    case (a[4:2])
      3'd0: m_ctrl = (m_ctrl & ~m) | (d & m);
      3'd2: m_s0   = (m_s0   & ~m) | (d & m);
      3'd3: m_s1   = (m_s1   & ~m) | (d & m);
      3'd4: m_en   = (m_en   & ~m[7:0]) | (d[7:0] & m[7:0]);
      3'd5: m_stat = m_stat & ~(d[7:0] & m[7:0]);
      3'd6: m_stat = m_stat |  (d[7:0] & m[7:0]);
      default: ;
    endcase
  endtask

  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      errors++;
      if (errors <= 10) $display("MISMATCH: %s", what);
    end
  endtask

  // ---------------------------------------------------------------- bus tasks
  // Sequential: one transfer at a time, random request delay and response stall.
  task automatic axi_write(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s,
                           input int unsigned stall);
    int n = 0;
    @(posedge clk);
    awaddr <= a; awvalid <= 1'b1;
    wdata <= d; wstrb <= s; wvalid <= 1'b1;
    bready <= (stall == 0);
    while (awvalid || wvalid) begin
      @(posedge clk);
      if (awready) awvalid <= 1'b0;
      if (wready)  wvalid  <= 1'b0;
      if (++n > 100) break;
    end
    n = 0;
    while (!(bvalid && bready)) begin
      @(posedge clk);
      if (bvalid && !bready) begin
        if (stall > 0) stall--;
        if (stall == 0) bready <= 1'b1;
      end
      if (++n > 100) begin check(0, "write response timeout"); break; end
    end
    check(bresp == exp_wresp(a), $sformatf("write 0x%03h BRESP %0d exp %0d", a, bresp, exp_wresp(a)));
    model_write(a, d, s);
    bready <= 1'b0;
  endtask

  task automatic axi_read(input logic [11:0] a, input int unsigned stall);
    int n = 0;
    logic [31:0] exp_d = exp_rdata(a);
    logic [1:0]  exp_r = (a[11:5] != 0) ? 2'b11 : 2'b00;
    @(posedge clk);
    araddr <= a; arvalid <= 1'b1;
    rready <= (stall == 0);
    while (arvalid) begin
      @(posedge clk);
      if (arready) arvalid <= 1'b0;
      if (++n > 100) break;
    end
    n = 0;
    while (!(rvalid && rready)) begin
      @(posedge clk);
      if (rvalid && !rready) begin
        if (stall > 0) stall--;
        if (stall == 0) rready <= 1'b1;
      end
      if (++n > 100) begin check(0, "read response timeout"); break; end
    end
    check(rresp == exp_r, $sformatf("read 0x%03h RRESP %0d exp %0d", a, rresp, exp_r));
    check(rdata == exp_d, $sformatf("read 0x%03h RDATA 0x%08h exp 0x%08h", a, rdata, exp_d));
    rready <= 1'b0;
  endtask

  // ---------------------------------------------------------------- stimulus
  initial begin
    int unsigned n_txn = 4000;
    void'($value$plusargs("NUM_TXN=%d", n_txn));
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    for (int i = 0; i < n_txn; i++) begin
      logic [11:0] a;
      int unsigned r = $urandom_range(0, 99);
      a = (r < 80) ? {7'h0, 3'($urandom_range(0, 7)), 2'b00}
                   : (r < 90) ? {7'h1, 3'($urandom_range(0, 7)), 2'b00}
                              : {10'($urandom_range(16, 1023)), 2'b00};
      if ($urandom_range(0, 1))
        axi_write(a, $urandom, ($urandom_range(0, 3) == 0) ? 4'($urandom) : 4'hF,
                  $urandom_range(0, 9));
      else
        axi_read(a, $urandom_range(0, 9));
    end
    repeat (5) @(posedge clk);
    $display("SMOKE_RESULT pass=%0d checks=%0d errors=%0d sva_fail=%0d",
             (errors == 0 && axi4l_sva_pkg::fail_count == 0), checks, errors,
             axi4l_sva_pkg::fail_count);
    $finish;
  end
endmodule
