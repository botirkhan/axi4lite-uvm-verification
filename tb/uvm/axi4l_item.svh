// axi4l_item.svh - one AXI4-Lite read or write, plus the timing knobs the
// driver uses for constrained-random back-pressure.

typedef enum bit {AXI_READ = 1'b0, AXI_WRITE = 1'b1} axi_kind_e;
typedef enum bit [1:0] {RESP_OKAY = 2'b00, RESP_EXOKAY = 2'b01,
                        RESP_SLVERR = 2'b10, RESP_DECERR = 2'b11} axi_resp_e;

class axi4l_item extends uvm_sequence_item;
  `uvm_object_utils(axi4l_item)

  rand axi_kind_e   kind;
  rand bit [11:0]   addr;
  rand bit [31:0]   data;
  rand bit [3:0]    strb;
  rand int unsigned aw_delay;    // cycles before AWVALID
  rand int unsigned w_delay;     // cycles before WVALID
  rand int unsigned ar_delay;    // cycles before ARVALID
  rand int unsigned resp_stall;  // cycles BVALID/RVALID wait for READY

  // set by the sequence: 1 = driver returns at once (random traffic),
  // 0 = driver returns after the response (RAL / directed checks)
  bit               nonblocking;

  // filled in by the driver
  bit [31:0]        rdata;
  axi_resp_e        resp;
  bit               timed_out;

  constraint c_align { addr[1:0] == 2'b00; }
  // address region picked first, then an address inside it
  // (0 = mapped registers, 1 = just past the map, 2 = far unmapped)
  rand int unsigned region;
  constraint c_region { region dist { 0 := 75, 1 := 10, 2 := 15 }; }
  constraint c_addr  { (region == 0) -> addr inside {[12'h000:12'h01C]};
                       (region == 1) -> addr inside {[12'h020:12'h03C]};
                       (region == 2) -> addr inside {[12'h040:12'hFFC]};
                       solve region before addr; }
  constraint c_delay { aw_delay inside {[0:3]};
                       w_delay  inside {[0:3]};
                       ar_delay inside {[0:3]}; }
  constraint c_stall { resp_stall dist { 0 := 30, [1:2] :/ 25, [3:7] :/ 25, [8:12] :/ 20 }; }
  constraint c_strb  { strb dist { 4'hF := 55, 4'h0 := 5,
                                   4'h1 := 5, 4'h2 := 5, 4'h4 := 5, 4'h8 := 5,
                                   4'h3 := 4, [4'h5:4'h7] :/ 6, [4'h9:4'hE] :/ 10 }; }

  function new(string name = "axi4l_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    if (kind == AXI_WRITE)
      return $sformatf("WR addr=0x%03h data=0x%08h strb=%b resp=%s stall=%0d",
                       addr, data, strb, resp.name(), resp_stall);
    return $sformatf("RD addr=0x%03h rdata=0x%08h resp=%s stall=%0d",
                     addr, rdata, resp.name(), resp_stall);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    axi4l_item t;
    super.do_copy(rhs);
    $cast(t, rhs);
    kind = t.kind; addr = t.addr; data = t.data; strb = t.strb;
    aw_delay = t.aw_delay; w_delay = t.w_delay; ar_delay = t.ar_delay;
    resp_stall = t.resp_stall; nonblocking = t.nonblocking;
    rdata = t.rdata; resp = t.resp; timed_out = t.timed_out;
  endfunction
endclass

// What the monitor sees on the bus. One object per event, sent in the order
// the events take effect inside the DUT (see axi4l_monitor.svh).
typedef enum {OBS_WR_COMMIT, OBS_WR_DONE, OBS_RD_ADDR, OBS_RD_DONE} axi4l_obs_e;

class axi4l_obs extends uvm_object;
  `uvm_object_utils(axi4l_obs)
  axi4l_obs_e  ev;
  axi_kind_e   kind;
  bit [11:0]   addr;
  bit [31:0]   data;      // write data
  bit [3:0]    strb;
  bit [31:0]   rdata;
  axi_resp_e   resp;
  int unsigned stall;     // cycles VALID waited for READY on B or R
  bit          overlap;   // the other channel was busy during this transfer
  int unsigned order;     // writes: 0 = AW first, 1 = W first, 2 = same cycle
  longint unsigned cycle;

  function new(string name = "axi4l_obs");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("%s @%0d addr=0x%03h data=0x%08h strb=%b rdata=0x%08h resp=%s stall=%0d ovl=%0b order=%0d",
                     ev.name(), cycle, addr, data, strb, rdata, resp.name(), stall, overlap, order);
  endfunction
endclass
