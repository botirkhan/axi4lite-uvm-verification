// axi4l_ral.svh - UVM register model (RAL) of the block, and the adapter that
// turns RAL operations into AXI4-Lite bus items.
//
// The scoreboard builds its reference model from this RAL model (offsets,
// reset values, field widths and access policies), so the register map is
// written down in exactly one place in the testbench.

class axi4l_simple_reg extends uvm_reg;
  `uvm_object_utils(axi4l_simple_reg)
  uvm_reg_field f;

  function new(string name = "axi4l_simple_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  // one field at bit 0
  function void setup(int unsigned width, string access, uvm_reg_data_t reset,
                      bit is_volatile = 0);
    f = uvm_reg_field::type_id::create("f", , get_full_name());
    f.configure(this, width, 0, access, is_volatile, reset, 1, (access != "RO"), 0);
  endfunction
endclass

class axi4l_reg_block extends uvm_reg_block;
  `uvm_object_utils(axi4l_reg_block)

  axi4l_simple_reg CTRL, STATUS, SCRATCH0, SCRATCH1, IRQ_EN, IRQ_STAT, IRQ_SET, ID;

  function new(string name = "axi4l_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  protected function axi4l_simple_reg make(string n, int unsigned width, string access,
                                           uvm_reg_data_t reset, uvm_reg_addr_t offset,
                                           string rights, bit is_volatile = 0);
    axi4l_simple_reg r = axi4l_simple_reg::type_id::create(n, , get_full_name());
    r.configure(this, null, "");
    r.setup(width, access, reset, is_volatile);
    default_map.add_reg(r, offset, rights);
    return r;
  endfunction

  virtual function void build();
    default_map = create_map("map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);
    CTRL     = make("CTRL",     32, "RW",  'h0,          'h00, "RW");
    STATUS   = make("STATUS",   32, "RO",  'h0,          'h04, "RO", 1);
    SCRATCH0 = make("SCRATCH0", 32, "RW",  'h0,          'h08, "RW");
    SCRATCH1 = make("SCRATCH1", 32, "RW",  'h0,          'h0C, "RW");
    IRQ_EN   = make("IRQ_EN",    8, "RW",  'h0,          'h10, "RW");
    IRQ_STAT = make("IRQ_STAT",  8, "W1C", 'h0,          'h14, "RW", 1);
    IRQ_SET  = make("IRQ_SET",   8, "WO",  'h0,          'h18, "WO");
    ID       = make("ID",       32, "RO",  'hA41C_0100,  'h1C, "RO");
    lock_model();
  endfunction
endclass

class axi4l_adapter extends uvm_reg_adapter;
  `uvm_object_utils(axi4l_adapter)

  function new(string name = "axi4l_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses   = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axi4l_item t = axi4l_item::type_id::create("ral_item");
    t.kind        = (rw.kind == UVM_READ) ? AXI_READ : AXI_WRITE;
    t.addr        = rw.addr[11:0];
    t.data        = rw.data[31:0];
    t.strb        = rw.byte_en[3:0];
    t.aw_delay    = $urandom_range(0, 2);
    t.w_delay     = $urandom_range(0, 2);
    t.ar_delay    = $urandom_range(0, 2);
    t.resp_stall  = $urandom_range(0, 4);
    t.nonblocking = 0;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axi4l_item t;
    if (!$cast(t, bus_item)) begin
      `uvm_fatal("ADAPTER", "bus item is not an axi4l_item")
      return;
    end
    rw.kind    = (t.kind == AXI_READ) ? UVM_READ : UVM_WRITE;
    rw.addr    = t.addr;
    rw.data    = (t.kind == AXI_READ) ? t.rdata : t.data;
    rw.byte_en = t.strb;
    rw.status  = (t.resp == RESP_OKAY && !t.timed_out) ? UVM_IS_OK : UVM_NOT_OK;
  endfunction
endclass
