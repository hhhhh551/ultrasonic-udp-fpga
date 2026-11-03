#---------------------------------------------------------------------------------------
# 新建 ultrasonic_udp 工程并综合实现出 bit
#   激励(gata_test) + 10bit ADC(50MHz) + 带通/包络检波 + UDP 上传
#
# 用法:
#   1) 先把源码放到 stage 目录  D:/project/vivado_project/_ultrasonic_stage/rtl
#   2) vivado -mode batch -source build_ultrasonic.tcl
#
# 说明: create_project -force 会清空工程目录, 所以源码必须先从 stage 目录拷进工程,
#       保证工程是自包含的(源码最终位于  ultrasonic_udp.srcs/sources_1/rtl)。
#---------------------------------------------------------------------------------------
set proj_root  {D:/project/vivado_project/ultrasonic_udp_v2}
set proj_name  {ultrasonic_udp_v2}
set stage_root {D:/project/vivado_project/_ultrasonic_stage/rtl}
set rtl_root   $proj_root/ultrasonic_udp.srcs/sources_1/rtl
set ip_root    $proj_root/ultrasonic_udp.srcs/sources_1/ip
set jobs       8

#----------------------------- 0. 建工程 -----------------------------
puts "\[INFO\] ===== create project ====="
# 旧工程目录里可能有被别的进程占用的文件, 删不掉就算了, 直接覆盖重建
foreach d {.cache .hw .ip_user_files .sim .srcs .gen} {
    if {[file exists $proj_root/$d]} { catch { file delete -force $proj_root/$d } }
}
if {[file exists $proj_root/$proj_name.xpr]} {
    catch { file delete -force $proj_root/$proj_name.xpr }
}
create_project -force $proj_name $proj_root -part xc7a100tfgg484-2
set_property target_language Verilog [current_project]

#----------------------------- 1. 把源码拷进工程(自包含) -----------------------------
puts "\[INFO\] ===== copy sources into project ====="
file mkdir $rtl_root
foreach sub {arp icmp udp gmii_to_rgmii} {
    file mkdir $rtl_root/$sub
    foreach f [glob -nocomplain $stage_root/$sub/*.v] {
        file copy -force $f $rtl_root/$sub/
    }
}
foreach f [glob -nocomplain $stage_root/*.v] {
    file copy -force $f $rtl_root/
}
file copy -force $stage_root/fir_coef.vh $rtl_root/
file copy -force $stage_root/ultrasonic_udp.xdc $rtl_root/
puts "\[INFO\] rtl files copied : [llength [glob -nocomplain $rtl_root -directory]]"

#----------------------------- 2. 添加 RTL -----------------------------
set rtl_files [concat \
    [glob -nocomplain $rtl_root/*.v] \
    [glob -nocomplain $rtl_root/arp/*.v] \
    [glob -nocomplain $rtl_root/icmp/*.v] \
    [glob -nocomplain $rtl_root/udp/*.v] \
    [glob -nocomplain $rtl_root/gmii_to_rgmii/*.v]]
puts "\[INFO\] adding [llength $rtl_files] verilog files"

add_files -norecurse -fileset sources_1 $rtl_files
add_files -norecurse -fileset sources_1 $rtl_root/fir_coef.vh
set_property file_type {Verilog Header} [get_files $rtl_root/fir_coef.vh]
set_property include_dirs $rtl_root [get_filesets sources_1]

set_property top ultrasonic_udp [get_filesets sources_1]
update_compile_order -fileset sources_1

#----------------------------- 3. 约束文件 -----------------------------
add_files -norecurse -fileset constrs_1 $rtl_root/ultrasonic_udp.xdc
set_property target_constrs_file $rtl_root/ultrasonic_udp.xdc [current_fileset -constrset]

#----------------------------- 4. 重建两个 IP -----------------------------
file mkdir $ip_root

puts "\[INFO\] create ip : clk_wiz_0 (50MHz -> 200MHz, IDELAYCTRL 参考时钟)"
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
          -module_name clk_wiz_0 -dir $ip_root
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ               {50.000}    \
    CONFIG.PRIMITIVE                  {MMCM}      \
    CONFIG.NUM_OUT_CLKS               {1}         \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000}   \
    CONFIG.CLKOUT1_USED               {true}      \
    CONFIG.CLKOUT2_USED               {false}     \
    CONFIG.CLKOUT3_USED               {false}     \
    CONFIG.CLKOUT4_USED               {false}     \
    CONFIG.CLK_OUT1_PORT              {clk_out1}  \
    CONFIG.MMCM_CLKFBOUT_MULT_F       {20.000}    \
    CONFIG.MMCM_CLKIN1_PERIOD         {20.000}    \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F      {5.000}     \
    CONFIG.USE_LOCKED                 {true}      \
    CONFIG.USE_RESET                  {true}      \
    CONFIG.RESET_PORT                 {reset}     \
    CONFIG.RESET_TYPE                 {ACTIVE_HIGH} \
] [get_ips clk_wiz_0]

puts "\[INFO\] create ip : async_fifo_2048x8b (8bit x 2048, 独立时钟块RAM)"
create_ip -name fifo_generator -vendor xilinx.com -library ip -version 13.2 \
          -module_name async_fifo_2048x8b -dir $ip_root
set_property -dict [list \
    CONFIG.Input_Data_Width            {8}                          \
    CONFIG.Input_Depth                 {2048}                       \
    CONFIG.Output_Data_Width           {8}                          \
    CONFIG.Output_Depth                {2048}                       \
    CONFIG.Fifo_Implementation         {Independent_Clocks_Block_RAM} \
    CONFIG.Reset_Type                  {Asynchronous_Reset}          \
    CONFIG.Enable_Safety_Circuit       {false}                      \
    CONFIG.Full_Threshold_Assert_Value {2045}                       \
    CONFIG.Full_Threshold_Negate_Value {2044}                       \
] [get_ips async_fifo_2048x8b]

generate_target all [get_ips clk_wiz_0]
generate_target all [get_ips async_fifo_2048x8b]
update_compile_order -fileset sources_1

puts "\[INFO\] ===== synth ====="
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "ERROR: synth_1 FAILED" }
puts "\[INFO\] ===== synth OK ====="

puts "\[INFO\] ===== impl + bitstream ====="
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "ERROR: impl_1 FAILED" }

open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -delay_type max]]
puts "\[INFO\] WNS = $wns ns"
report_utilization -file $proj_root/rpt_utilization.txt
report_timing_summary -file $proj_root/rpt_timing_summary.txt
close_design
close_project
puts "\[INFO\] ===== ALL DONE ====="
