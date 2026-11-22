// axi4l_driver.svh - AXI4-Lite master driver.
//
// * One write and one read can be in flight at the same time (separate
//   semaphores), so reads and writes interleave and overlap on the bus.
// * AW and W are driven by parallel processes with independent delays, so
//   AW-first, W-first and same-cycle orderings all happen.
// * BREADY/RREADY are held low for item.resp_stall cycles of VALID.
// * Every wait has a timeout, so a broken DUT ends the test instead of hanging.
//
// All signals are driven with nonblocking assignments right after a clock
// edge, and READY/VALID are read right after the edge (pre-update values),
// so "vif.x" inside a wait loop is the value the DUT sampled at that edge.

class axi4l_driver extends uvm_driver #(axi4l_item);
  `uvm_component_utils(axi4l_driver)

  virtual axi4l_if vif;
  int unsigned     timeout_cycles = 200;
  int unsigned     n_timeouts;
  int unsigned     n_driven;
  protected int    outstanding;
  protected semaphore wr_sem, rd_sem;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    wr_sem = new(1);
    rd_sem = new(1);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4l_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axi4l_if not set in config_db")
  endfunction

  task wait_idle();
    wait (outstanding == 0);
  endtask

  protected task reset_signals();
    vif.awvalid <= 1'b0; vif.awaddr <= '0; vif.awprot <= '0;
    vif.wvalid  <= 1'b0; vif.wdata  <= '0; vif.wstrb  <= '0;
    vif.bready  <= 1'b0;
    vif.arvalid <= 1'b0; vif.araddr <= '0; vif.arprot <= '0;
    vif.rready  <= 1'b0;
  endtask

  task run_phase(uvm_phase phase);
    reset_signals();
    wait (vif.rst_n === 1'b1);
    @(posedge vif.clk);
    forever begin
      seq_item_port.get_next_item(req);
      if (req.kind == AXI_WRITE) wr_sem.get(); else rd_sem.get();
      outstanding++;
      n_driven++;
      if (req.nonblocking) begin
        spawn(req);
        seq_item_port.item_done();
      end else begin
        drive(req);
        seq_item_port.item_done();
      end
    end
  endtask

  // separate task so each forked transfer has its own copy of the handle
  protected task spawn(axi4l_item t);
    fork
      drive(t);
    join_none
  endtask

  protected task drive(axi4l_item t);
    t.timed_out = 0;
    if (t.kind == AXI_WRITE) begin
      do_write(t);
      wr_sem.put();
    end else begin
      do_read(t);
      rd_sem.put();
    end
    outstanding--;
  endtask

  // wait for an edge where `cond` was true; returns 1 on timeout
  `define AXI4L_WAIT_EDGE(cond, tmo) \
    begin \
      int unsigned _n = 0; \
      tmo = 0; \
      do begin \
        @(posedge vif.clk); \
        _n++; \
        if (_n > timeout_cycles) begin tmo = 1; break; end \
      end while (!(cond)); \
    end

  protected task do_write(axi4l_item t);
    bit tmo_aw, tmo_w, tmo_b;
    @(posedge vif.clk);
    fork
      begin
        repeat (t.aw_delay) @(posedge vif.clk);
        vif.awaddr  <= t.addr;
        vif.awprot  <= 3'b000;
        vif.awvalid <= 1'b1;
        `AXI4L_WAIT_EDGE(vif.awready === 1'b1, tmo_aw)
        vif.awvalid <= 1'b0;
      end
      begin
        repeat (t.w_delay) @(posedge vif.clk);
        vif.wdata  <= t.data;
        vif.wstrb  <= t.strb;
        vif.wvalid <= 1'b1;
        `AXI4L_WAIT_EDGE(vif.wready === 1'b1, tmo_w)
        vif.wvalid <= 1'b0;
      end
    join

    if (t.resp_stall == 0) begin
      vif.bready <= 1'b1;
      `AXI4L_WAIT_EDGE(vif.bvalid === 1'b1, tmo_b)
    end else begin
      `AXI4L_WAIT_EDGE(vif.bvalid === 1'b1, tmo_b)        // 1st stalled cycle
      if (!tmo_b) begin
        repeat (t.resp_stall - 1) @(posedge vif.clk);
        vif.bready <= 1'b1;
        `AXI4L_WAIT_EDGE(vif.bvalid === 1'b1, tmo_b)
      end
    end
    t.resp = axi_resp_e'(vif.bresp);
    vif.bready <= 1'b0;

    if (tmo_aw || tmo_w || tmo_b) begin
      t.timed_out = 1;
      n_timeouts++;
      `uvm_error("DRV_TIMEOUT", $sformatf("write handshake timed out (aw=%0b w=%0b b=%0b): %s",
                                          tmo_aw, tmo_w, tmo_b, t.convert2string()))
      vif.awvalid <= 1'b0;
      vif.wvalid  <= 1'b0;
    end
  endtask

  protected task do_read(axi4l_item t);
    bit tmo_ar, tmo_r;
    @(posedge vif.clk);
    repeat (t.ar_delay) @(posedge vif.clk);
    vif.araddr  <= t.addr;
    vif.arprot  <= 3'b000;
    vif.arvalid <= 1'b1;
    `AXI4L_WAIT_EDGE(vif.arready === 1'b1, tmo_ar)
    vif.arvalid <= 1'b0;

    if (t.resp_stall == 0) begin
      vif.rready <= 1'b1;
      `AXI4L_WAIT_EDGE(vif.rvalid === 1'b1, tmo_r)
    end else begin
      `AXI4L_WAIT_EDGE(vif.rvalid === 1'b1, tmo_r)
      if (!tmo_r) begin
        repeat (t.resp_stall - 1) @(posedge vif.clk);
        vif.rready <= 1'b1;
        `AXI4L_WAIT_EDGE(vif.rvalid === 1'b1, tmo_r)
      end
    end
    t.rdata = vif.rdata;
    t.resp  = axi_resp_e'(vif.rresp);
    vif.rready <= 1'b0;

    if (tmo_ar || tmo_r) begin
      t.timed_out = 1;
      n_timeouts++;
      `uvm_error("DRV_TIMEOUT", $sformatf("read handshake timed out (ar=%0b r=%0b): %s",
                                          tmo_ar, tmo_r, t.convert2string()))
    end
  endtask

  `undef AXI4L_WAIT_EDGE
endclass
