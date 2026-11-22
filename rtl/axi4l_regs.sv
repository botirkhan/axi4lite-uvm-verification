// axi4l_regs.sv
// AXI4-Lite slave register block: 8 x 32-bit registers in a 4 KB window.
//
//   Offset  Name       Access  Notes
//   0x00    CTRL       RW      byte strobes honoured
//   0x04    STATUS     RO      mirrors hw_status input; write -> SLVERR
//   0x08    SCRATCH0   RW
//   0x0C    SCRATCH1   RW
//   0x10    IRQ_EN     RW      bits [7:0], upper bits read as zero
//   0x14    IRQ_STAT   W1C     bits [7:0], write 1 to clear
//   0x18    IRQ_SET    WO      writing 1s sets IRQ_STAT bits; reads return 0
//   0x1C    ID         RO      32'hA41C_0100; write -> SLVERR
//   0x20+   (unmapped)         read/write -> DECERR, read data 0
//
// Handshake notes
//   * AW and W are accepted independently, in any order (each has a 1-deep
//     holding register). The write commits once both are held and the B
//     channel is free; BVALID rises on the cycle after commit.
//   * One read in flight: ARREADY is low while RVALID is pending.
//   * Read data is captured when AR is accepted and held stable until RREADY.
//
// Injected bugs for mutation testing (define exactly one, or none):
//   BUG_RO_OKAY        writes to RO registers return OKAY instead of SLVERR
//   BUG_WSTRB          WSTRB ignored: every write updates all four bytes
//   BUG_BVALID_DROP    BVALID drops after one cycle even if BREADY is low
//   BUG_DECODE_ALIAS   address bit 5 ignored, so 0x20-0x3C alias 0x00-0x1C
//   BUG_RDATA_LIVE     RDATA is read live from the register, not captured
`timescale 1ns/1ps
module axi4l_regs #(
  parameter int ADDR_W = 12
) (
  input  logic              clk,
  input  logic              rst_n,
  // write address
  input  logic [ADDR_W-1:0] s_awaddr,
  input  logic [2:0]        s_awprot,
  input  logic              s_awvalid,
  output logic              s_awready,
  // write data
  input  logic [31:0]       s_wdata,
  input  logic [3:0]        s_wstrb,
  input  logic              s_wvalid,
  output logic              s_wready,
  // write response
  output logic [1:0]        s_bresp,
  output logic              s_bvalid,
  input  logic              s_bready,
  // read address
  input  logic [ADDR_W-1:0] s_araddr,
  input  logic [2:0]        s_arprot,
  input  logic              s_arvalid,
  output logic              s_arready,
  // read data
  output logic [31:0]       s_rdata,
  output logic [1:0]        s_rresp,
  output logic              s_rvalid,
  input  logic              s_rready,
  // hardware side
  input  logic [31:0]       hw_status,
  output logic              irq
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;
  localparam logic [31:0] ID_VALUE   = 32'hA41C_0100;

  // ---------------------------------------------------------------- registers
  logic [31:0] ctrl_q, scratch0_q, scratch1_q;
  logic [7:0]  irq_en_q, irq_stat_q;

  // ---------------------------------------------------------------- decode
  function automatic logic in_range(input logic [ADDR_W-1:0] a);
`ifdef BUG_DECODE_ALIAS
    return (a[ADDR_W-1:6] == '0);
`else
    return (a[ADDR_W-1:5] == '0);
`endif
  endfunction

  function automatic logic is_ro(input logic [ADDR_W-1:0] a);
    return (a[4:2] == 3'd1) || (a[4:2] == 3'd7);
  endfunction

  function automatic logic [1:0] wr_resp(input logic [ADDR_W-1:0] a);
    if (!in_range(a)) return RESP_DECERR;
`ifdef BUG_RO_OKAY
    return RESP_OKAY;
`else
    if (is_ro(a))     return RESP_SLVERR;
    return RESP_OKAY;
`endif
  endfunction

  function automatic logic [31:0] rd_value(input logic [ADDR_W-1:0] a);
    if (!in_range(a)) return 32'h0;
    case (a[4:2])
      3'd0:    return ctrl_q;
      3'd1:    return hw_status;
      3'd2:    return scratch0_q;
      3'd3:    return scratch1_q;
      3'd4:    return {24'h0, irq_en_q};
      3'd5:    return {24'h0, irq_stat_q};
      3'd6:    return 32'h0;            // IRQ_SET is write-only
      default: return ID_VALUE;
    endcase
  endfunction

  function automatic logic [31:0] merge(input logic [31:0] old_v,
                                        input logic [31:0] new_v,
                                        input logic [3:0]  strb);
    logic [31:0] m;
`ifdef BUG_WSTRB
    m = 32'hFFFF_FFFF;
`else
    m = {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
`endif
    return (old_v & ~m) | (new_v & m);
  endfunction

  // ---------------------------------------------------------------- write path
  logic              aw_held, w_held, bvalid_q;
  logic [ADDR_W-1:0] aw_addr_q;
  logic [31:0]       w_data_q;
  logic [3:0]        w_strb_q;
  logic [1:0]        bresp_q;

  assign s_awready = !aw_held;
  assign s_wready  = !w_held;
  assign s_bvalid  = bvalid_q;
  assign s_bresp   = bresp_q;

  wire        do_write = aw_held && w_held && !bvalid_q;
  wire [1:0]  wresp    = wr_resp(aw_addr_q);
`ifdef BUG_WSTRB
  wire [7:0]  lo_mask  = 8'hFF;
`else
  wire [7:0]  lo_mask  = {8{w_strb_q[0]}};
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_held    <= 1'b0;
      w_held     <= 1'b0;
      bvalid_q   <= 1'b0;
      bresp_q    <= RESP_OKAY;
      aw_addr_q  <= '0;
      w_data_q   <= '0;
      w_strb_q   <= '0;
      ctrl_q     <= '0;
      scratch0_q <= '0;
      scratch1_q <= '0;
      irq_en_q   <= '0;
      irq_stat_q <= '0;
    end else begin
      if (s_awvalid && s_awready) begin
        aw_held   <= 1'b1;
        aw_addr_q <= s_awaddr;
      end
      if (s_wvalid && s_wready) begin
        w_held   <= 1'b1;
        w_data_q <= s_wdata;
        w_strb_q <= s_wstrb;
      end

      if (do_write) begin
        aw_held  <= 1'b0;
        w_held   <= 1'b0;
        bvalid_q <= 1'b1;
        bresp_q  <= wresp;
        if (wresp == RESP_OKAY) begin
          case (aw_addr_q[4:2])
            3'd0: ctrl_q     <= merge(ctrl_q,     w_data_q, w_strb_q);
            3'd2: scratch0_q <= merge(scratch0_q, w_data_q, w_strb_q);
            3'd3: scratch1_q <= merge(scratch1_q, w_data_q, w_strb_q);
            3'd4: irq_en_q   <= (irq_en_q & ~lo_mask) | (w_data_q[7:0] & lo_mask);
            3'd5: irq_stat_q <= irq_stat_q & ~(w_data_q[7:0] & lo_mask);
            3'd6: irq_stat_q <= irq_stat_q |  (w_data_q[7:0] & lo_mask);
            default: ;  // RO registers (only reachable with BUG_RO_OKAY)
          endcase
        end
`ifdef BUG_BVALID_DROP
      end else if (bvalid_q) begin
        bvalid_q <= 1'b0;
`else
      end else if (bvalid_q && s_bready) begin
        bvalid_q <= 1'b0;
`endif
      end
    end
  end

  // ---------------------------------------------------------------- read path
  logic              rvalid_q;
  logic [31:0]       rdata_q;
  logic [1:0]        rresp_q;
  logic [ADDR_W-1:0] ar_addr_q;

  assign s_arready = !rvalid_q;
  assign s_rvalid  = rvalid_q;
  assign s_rresp   = rresp_q;
`ifdef BUG_RDATA_LIVE
  assign s_rdata   = rd_value(ar_addr_q);
`else
  assign s_rdata   = rdata_q;
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rvalid_q  <= 1'b0;
      rdata_q   <= '0;
      rresp_q   <= RESP_OKAY;
      ar_addr_q <= '0;
    end else if (s_arvalid && s_arready) begin
      rvalid_q  <= 1'b1;
      ar_addr_q <= s_araddr;
      rdata_q   <= rd_value(s_araddr);
      rresp_q   <= in_range(s_araddr) ? RESP_OKAY : RESP_DECERR;
    end else if (rvalid_q && s_rready) begin
      rvalid_q  <= 1'b0;
    end
  end

  assign irq = |(irq_stat_q & irq_en_q);

  // unused inputs (AxPROT is accepted but not checked)
  wire unused_ok = &{1'b0, s_awprot, s_arprot};

endmodule
