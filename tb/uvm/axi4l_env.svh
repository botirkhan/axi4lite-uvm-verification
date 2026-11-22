// axi4l_env.svh - agent and environment.

typedef uvm_sequencer #(axi4l_item) axi4l_sequencer;

class axi4l_agent extends uvm_agent;
  `uvm_component_utils(axi4l_agent)
  axi4l_sequencer sqr;
  axi4l_driver    drv;
  axi4l_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = axi4l_sequencer::type_id::create("sqr", this);
    drv = axi4l_driver::type_id::create("drv", this);
    mon = axi4l_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class axi4l_env extends uvm_env;
  `uvm_component_utils(axi4l_env)
  axi4l_agent      agent;
  axi4l_scoreboard sb;
  axi4l_coverage   cov;
  axi4l_reg_block  rm;
  axi4l_adapter    adapter;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = axi4l_agent::type_id::create("agent", this);
    sb    = axi4l_scoreboard::type_id::create("sb", this);
    cov   = axi4l_coverage::type_id::create("cov", this);
    rm    = axi4l_reg_block::type_id::create("rm");
    rm.configure(null, "");
    rm.build();
    adapter = axi4l_adapter::type_id::create("adapter");
    sb.rm = rm;
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(sb.imp);
    agent.mon.ap.connect(cov.analysis_export);
    rm.default_map.set_sequencer(agent.sqr, adapter);
    rm.default_map.set_auto_predict(0);  // the scoreboard is the predictor
  endfunction
endclass
