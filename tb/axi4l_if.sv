// axi4l_if.sv - AXI4-Lite bus between the UVM agent (master) and the DUT.
`timescale 1ns/1ps
interface axi4l_if (input logic clk, input logic rst_n);
  logic [11:0] awaddr;
  logic [2:0]  awprot;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  logic [11:0] araddr;
  logic [2:0]  arprot;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;
  // hardware side of the register block
  logic [31:0] hw_status;
  logic        irq;
endinterface
