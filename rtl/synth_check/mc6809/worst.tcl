project_open mc6809_fmax
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 5 -detail summary -file worst_paths.txt
delete_timing_netlist
project_close
