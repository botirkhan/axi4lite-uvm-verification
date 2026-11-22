// axi4l_monitor.svh - passive AXI4-Lite monitor.
//
// Sampling: values are read right after each rising edge, before the
// nonblocking updates land, so they are exactly what the DUT saw at that edge.
//
// Event ordering (this is what lets the scoreboard predict reads that overlap
// writes exactly, with no "either value is OK" slack):
//   The DUT commits a write on edge E and raises BVALID right after it. The
//   monitor sees the new BVALID at edge E+1 and sends OBS_WR_COMMIT first,
//   then any OBS_RD_ADDR for an AR handshake at that same edge. A read
//   accepted at edge M returns register values from before edge M, i.e. it
//   includes every commit E < M, which is every commit the monitor has
//   already reported by the time it reports the AR at M.

class axi4l_monitor extends uvm_monitor;
  `uvm_component_utils(axi4l_monitor)

  virtual axi4l_if vif;
  uvm_analysis_port #(axi4l_obs) ap;

  protected longint unsigned cycle;
  // AW / W handshakes waiting for their commit
  protected bit [11:0]       aw_q[$];
  protected longint unsigned aw_cyc_q[$];
  protected bit [35:0]       w_q[$];       // {strb, data}
  protected longint unsigned w_cyc_q[$];
  // write between commit and B handshake
  protected bit              wr_pend;
  protected axi4l_obs        wr_cur;
  protected bit              wr_ovl;
  // read between AR and R handshake
  protected bit              rd_pend;
  protected axi4l_obs        rd_cur;
  protected bit              rd_ovl;
  protected bit              prev_b_stall, prev_r_stall;

  int unsigned n_writes, n_reads;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4l_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axi4l_if not set in config_db")
  endfunction

  protected function void clear_state();
    aw_q.delete(); aw_cyc_q.delete(); w_q.delete(); w_cyc_q.delete();
    wr_pend = 0; rd_pend = 0; wr_ovl = 0; rd_ovl = 0;
    prev_b_stall = 0; prev_r_stall = 0;
  endfunction

  task run_phase(uvm_phase phase);
    clear_state();
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n !== 1'b1) begin
        clear_state();
        continue;
      end
      cycle++;
      sample_edge();
    end
  endtask

  protected function void sample_edge();
    bit b_new, wr_busy, rd_busy;

    // 1) request handshakes
    if (vif.awvalid && vif.awready) begin
      aw_q.push_back(vif.awaddr);
      aw_cyc_q.push_back(cycle);
    end
    if (vif.wvalid && vif.wready) begin
      w_q.push_back({vif.wstrb, vif.wdata});
      w_cyc_q.push_back(cycle);
    end

    // 2) write commit = first cycle of a new BVALID
    b_new = vif.bvalid && !prev_b_stall;
    if (b_new) begin
      if (wr_pend)
        `uvm_error("MON", "new write response while the previous one never completed")
      if (aw_q.size() == 0 || w_q.size() == 0) begin
        `uvm_error("MON", "BVALID without a matching AW and W handshake")
      end else begin
        bit [35:0] w;
        longint unsigned ac, wc;
        wr_cur = axi4l_obs::type_id::create("wr");
        w  = w_q.pop_front();
        ac = aw_cyc_q.pop_front();
        wc = w_cyc_q.pop_front();
        wr_cur.ev    = OBS_WR_COMMIT;
        wr_cur.kind  = AXI_WRITE;
        wr_cur.addr  = aw_q.pop_front();
        wr_cur.data  = w[31:0];
        wr_cur.strb  = w[35:32];
        wr_cur.resp  = axi_resp_e'(vif.bresp);
        wr_cur.order = (ac < wc) ? 0 : (wc < ac) ? 1 : 2;
        wr_cur.cycle = cycle;
        wr_cur.stall = 0;
        wr_pend = 1;
        ap.write(wr_cur);
      end
    end

    // 3) read address
    if (vif.arvalid && vif.arready) begin
      if (rd_pend) `uvm_error("MON", "AR accepted while a read response is pending")
      rd_cur = axi4l_obs::type_id::create("rd");
      rd_cur.ev    = OBS_RD_ADDR;
      rd_cur.kind  = AXI_READ;
      rd_cur.addr  = vif.araddr;
      rd_cur.cycle = cycle;
      rd_cur.stall = 0;
      rd_pend = 1;
      ap.write(rd_cur);
    end

    // 4) overlap bookkeeping: is each channel busy at this edge?
    wr_busy = vif.awvalid || vif.wvalid || aw_q.size() > 0 || w_q.size() > 0 || wr_pend;
    rd_busy = vif.arvalid || rd_pend;
    if (wr_busy && rd_busy) begin
      wr_ovl = 1;
      rd_ovl = 1;
    end

    // 5) read data
    if (rd_pend && vif.rvalid && !vif.rready) rd_cur.stall++;
    if (vif.rvalid && vif.rready) begin
      if (!rd_pend) begin
        `uvm_error("MON", "R handshake with no read outstanding")
      end else begin
        axi4l_obs d = axi4l_obs::type_id::create("rd_done");
        d.ev      = OBS_RD_DONE;
        d.kind    = AXI_READ;
        d.addr    = rd_cur.addr;
        d.rdata   = vif.rdata;
        d.resp    = axi_resp_e'(vif.rresp);
        d.stall   = rd_cur.stall;
        d.overlap = rd_ovl;
        d.cycle   = cycle;
        rd_pend = 0;
        rd_ovl  = 0;
        n_reads++;
        ap.write(d);
      end
    end

    // 6) write response
    if (wr_pend && vif.bvalid && !vif.bready) wr_cur.stall++;
    if (vif.bvalid && vif.bready && wr_pend) begin
      axi4l_obs d = axi4l_obs::type_id::create("wr_done");
      d.ev      = OBS_WR_DONE;
      d.kind    = AXI_WRITE;
      d.addr    = wr_cur.addr;
      d.data    = wr_cur.data;
      d.strb    = wr_cur.strb;
      d.resp    = axi_resp_e'(vif.bresp);
      d.order   = wr_cur.order;
      d.stall   = wr_cur.stall;
      d.overlap = wr_ovl;
      d.cycle   = cycle;
      if (d.resp != wr_cur.resp)
        `uvm_error("MON", $sformatf("BRESP changed while BVALID was high: %s -> %s",
                                    wr_cur.resp.name(), d.resp.name()))
      wr_pend = 0;
      wr_ovl  = 0;
      n_writes++;
      ap.write(d);
    end

    prev_b_stall = vif.bvalid && !vif.bready;
    prev_r_stall = vif.rvalid && !vif.rready;
  endfunction
endclass
