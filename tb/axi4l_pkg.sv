// axi4l_pkg.sv - UVM environment for the AXI4-Lite register block.
`timescale 1ns/1ps
package axi4l_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "axi4l_item.svh"
  `include "axi4l_driver.svh"
  `include "axi4l_monitor.svh"
  `include "axi4l_ral.svh"
  `include "axi4l_scoreboard.svh"
  `include "axi4l_coverage.svh"
  `include "axi4l_env.svh"
  `include "axi4l_seqs.svh"
  `include "axi4l_tests.svh"
endpackage
