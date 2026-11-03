#========================================================================================
# ultrasonic_udp.xdc
#   超声检测顶层引脚约束
#   合并自: 100t_udp_fuben(以太网) + AD_DA_8bit_test(ADC) + gata_test(激励) + flow_led(LED)
#   已核对: 除 sys_clk(R4)/sys_rst_n(U7) 是共用之外, 没有任何引脚冲突
#========================================================================================

#-----------------------------------时钟与复位-------------------------------------------
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS15} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS15} [get_ports sys_rst_n]

#-----------------------------------以太网 RGMII-----------------------------------------
create_clock -period 8.000 -name eth_rxc [get_ports eth_rxc]
set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} [get_ports eth_rst_n]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports eth_rxc]
set_property -dict {PACKAGE_PIN Y21 IOSTANDARD LVCMOS33} [get_ports eth_rx_ctl]
set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[3]}]

set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports eth_txc]
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} [get_ports eth_tx_ctl]
set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVCMOS33} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} [get_ports {eth_txd[3]}]

#-----------------------------------10bit ADC--------------------------------------------
set_property -dict {PACKAGE_PIN Y16  IOSTANDARD LVCMOS33} [get_ports {ad_data[0]}]
set_property -dict {PACKAGE_PIN AA16 IOSTANDARD LVCMOS33} [get_ports {ad_data[1]}]
set_property -dict {PACKAGE_PIN AB16 IOSTANDARD LVCMOS33} [get_ports {ad_data[2]}]
set_property -dict {PACKAGE_PIN AB17 IOSTANDARD LVCMOS33} [get_ports {ad_data[3]}]
set_property -dict {PACKAGE_PIN AA15 IOSTANDARD LVCMOS33} [get_ports {ad_data[4]}]
set_property -dict {PACKAGE_PIN AB15 IOSTANDARD LVCMOS33} [get_ports {ad_data[5]}]
set_property -dict {PACKAGE_PIN Y13  IOSTANDARD LVCMOS33} [get_ports {ad_data[6]}]
set_property -dict {PACKAGE_PIN AA14 IOSTANDARD LVCMOS33} [get_ports {ad_data[7]}]
set_property -dict {PACKAGE_PIN AA13 IOSTANDARD LVCMOS33} [get_ports {ad_data[8]}]
set_property -dict {PACKAGE_PIN AB13 IOSTANDARD LVCMOS33} [get_ports {ad_data[9]}]

set_property -dict {PACKAGE_PIN AB11 IOSTANDARD LVCMOS33} [get_ports ad_clk]
set_property -dict {PACKAGE_PIN W12  IOSTANDARD LVCMOS33} [get_ports ad_oe]

#ADC 驱动时钟是 sys_clk 取反后送出, 数据在下一个 sys_clk 上升沿采样,
#实际余量约 10ns, 这里按相对 sys_clk 的输入延时约束(留 4ns 内部预算)
set_input_delay -clock sys_clk -max 16.000 [get_ports {ad_data[*]}]
set_input_delay -clock sys_clk -min  4.000 [get_ports {ad_data[*]}]

#-----------------------------------超声激励---------------------------------------------
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports pulse_n]

#-----------------------------------调试指示灯-------------------------------------------
set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS15} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS15} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS15} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS15} [get_ports {led[3]}]

#-----------------------------------配置-----------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
