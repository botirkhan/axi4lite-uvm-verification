// tb_top.sv - UVM top: clock, reset, DUT, SVA bind.
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  import axi4l_pkg::*;
  `include "uvm_macros.svh"

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;   // 100 MHz

  axi4l_if bus (.clk(clk), .rst_n(rst_n));

  axi4l_regs #(.ADDR_W(12)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .s_awaddr  (bus.awaddr),
    .s_awprot  (bus.awprot),
    .s_awvalid (bus.awvalid),
    .s_awready (bus.awready),
    .s_wdata   (bus.wdata),
    .s_wstrb   (bus.wstrb),
    .s_wvalid  (bus.wvalid),
    .s_wready  (bus.wready),
    .s_bresp   (bus.bresp),
    .s_bvalid  (bus.bvalid),
    .s_bready  (bus.bready),
    .s_araddr  (bus.araddr),
    .s_arprot  (bus.arprot),
    .s_arvalid (bus.arvalid),
    .s_arready (bus.arready),
    .s_rdata   (bus.rdata),
    .s_rresp   (bus.rresp),
    .s_rvalid  (bus.rvalid),
    .s_rready  (bus.rready),
    .hw_status (bus.hw_status),
    .irq       (bus.irq)
  );

  // assertions ride along with every instance of the DUT
  bind axi4l_regs axi4l_sva #(.ADDR_W(ADDR_W)) u_sva (.*);

  initial begin
    // bus.hw_status is driven by the test at time 0, before reset is released
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
  end

  initial begin
    uvm_config_db#(virtual axi4l_if)::set(null, "*", "vif", bus);
    run_test("axi4l_full_test");
  end
endmodule
