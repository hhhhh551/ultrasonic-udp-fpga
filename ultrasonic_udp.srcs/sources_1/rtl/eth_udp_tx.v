//****************************************************************************************//
// File name:   eth_udp_tx.v
// Descriptions: 以太网 UDP 发送(由原来跑通的 eth_udp_loop 改造)
//
//   与 eth_udp_loop 的区别:
//     1. 数据源 data_gen 换成 frame_src, 每帧从外部 frame_ram 读 1024 字节发一包;
//     2. 多引出 4 个端口给顶层接帧缓冲: frame_tog / frame_sel / frame_raddr / frame_rdata;
//     3. 保留 ARP + ICMP(ping), 方便调试链路; async_fifo 只给 ping 回环用。
//
//   帧接口说明:
//     frame_tog  : 采集时钟域送来的翻转信号, 表示有一帧新数据(这里两级同步)
//     frame_sel  : 该帧所在的乒乓缓冲号, 在 frame_tog 翻转期间保持不变
//     frame_raddr/frame_rdata : 读 frame_ram 的地址/数据(以太网时钟域)
//****************************************************************************************//
module eth_udp_tx(
    input              sys_clk   , //系统时钟 50MHz
    input              sys_rst_n , //系统复位信号，低电平有效
    //以太网RGMII接口
    input              eth_rxc   , //RGMII接收数据时钟
    input              eth_rx_ctl, //RGMII输入数据有效信号
    input       [3:0]  eth_rxd   , //RGMII输入数据
    output             eth_txc   , //RGMII发送数据时钟
    output             eth_tx_ctl, //RGMII输出数据有效信号
    output      [3:0]  eth_txd   , //RGMII输出数据
    output             eth_rst_n , //以太网芯片复位信号，低电平有效
    //采集帧接口(写口在 sys_clk 50MHz 采集域)
    input              frame_tog , //帧就绪翻转信号(来自采集时钟域)
    input              frame_sel , //该帧所在缓冲号
    input              frame_wr_en  , //写使能
    input              frame_wr_sel , //写缓冲号
    input       [8:0]  frame_wr_addr, //写地址
    input       [15:0] frame_wr_data, //写数据
    //调试指示灯
    output      [3:0]  led
    );

//parameter define
parameter BOARD_MAC       = 48'h00_11_22_33_44_55;
parameter BOARD_IP        = {8'd192,8'd168,8'd1,8'd10};
parameter DES_MAC_DEFAULT = 48'hff_ff_ff_ff_ff_ff;
parameter DES_IP_DEFAULT  = {8'd192,8'd168,8'd0,8'd145};
parameter IDELAY_VALUE    = 0;
parameter PKT_BYTES       = 1024;

//wire define
wire          clk_200m          ;
wire          locked            ;

wire          gmii_rx_clk       ;
wire          gmii_rx_dv        ;
wire  [7:0]   gmii_rxd          ;
wire          gmii_tx_clk       ;
wire          gmii_tx_en        ;
wire  [7:0]   gmii_txd          ;

wire          arp_gmii_tx_en    ;
wire  [7:0]   arp_gmii_txd      ;
wire          arp_rx_done       ;
wire          arp_rx_type       ;
wire  [47:0]  src_mac           ;
wire  [31:0]  src_ip            ;
wire          arp_tx_en         ;
wire          arp_tx_type       ;
wire  [47:0]  des_mac           ;
wire  [31:0]  des_ip            ;
wire          arp_tx_done       ;

wire          icmp_gmii_tx_en   ;
wire  [7:0]   icmp_gmii_txd     ;
wire          icmp_rec_pkt_done ;
wire          icmp_rec_en       ;
wire  [ 7:0]  icmp_rec_data     ;
wire  [15:0]  icmp_rec_byte_num ;
wire  [15:0]  icmp_tx_byte_num  ;
wire          icmp_tx_done      ;
wire          icmp_tx_req       ;
wire  [7:0]   icmp_tx_data      ;
wire          icmp_tx_start_en  ;

wire          udp_gmii_tx_en    ;
wire  [7:0]   udp_gmii_txd      ;
wire          udp_tx_done       ;
wire          udp_tx_req        ;
wire          udp_tx_ready      ;

wire          udp_tx_start_en   ;
wire  [15:0]  udp_tx_byte_num   ;
wire  [ 7:0]  udp_tx_data       ;
wire  [ 9:0]  frame_raddr_int   ;
wire  [15:0]  frame_rdata       ;

wire  [7:0]   rec_data          ;
wire          rec_en            ;
wire          tx_req            ;
wire  [7:0]   tx_data           ;

//*****************************************************
//**                    main code
//*****************************************************

assign icmp_tx_byte_num = icmp_rec_byte_num;
assign des_mac          = src_mac;
assign des_ip           = src_ip;
assign eth_rst_n        = sys_rst_n;

//包络帧缓冲(乒乓双缓冲)
//   写: sys_clk 采集域   读: gmii_tx_clk 以太网域
frame_ram
   #(
    .POINTS          (512            )
    )
   u_frame_ram(
    .wr_clk          (sys_clk        ),
    .wr_en           (frame_wr_en    ),
    .wr_sel          (frame_wr_sel   ),
    .wr_addr         (frame_wr_addr  ),
    .wr_data         (frame_wr_data  ),
    .rd_clk          (gmii_tx_clk    ),
    .rd_addr         (frame_raddr_int),
    .rd_data         (frame_rdata    )
    );

clk_wiz_0 u_clk_wiz_0
   (
    .clk_out1       (clk_200m   ),
    .reset          (~sys_rst_n ),
    .locked         (locked     ),
    .clk_in1        (sys_clk    )
    );

gmii_to_rgmii
    #(
     .IDELAY_VALUE  (IDELAY_VALUE)
     )
    u_gmii_to_rgmii (
    .idelay_clk     (clk_200m    ),
    .gmii_rx_clk    (gmii_rx_clk ),
    .gmii_rx_dv     (gmii_rx_dv  ),
    .gmii_rxd       (gmii_rxd    ),
    .gmii_tx_clk    (gmii_tx_clk ),
    .gmii_tx_en     (gmii_tx_en  ),
    .gmii_txd       (gmii_txd    ),
    .rgmii_rxc      (eth_rxc     ),
    .rgmii_rx_ctl   (eth_rx_ctl  ),
    .rgmii_rxd      (eth_rxd     ),
    .rgmii_txc      (eth_txc     ),
    .rgmii_tx_ctl   (eth_tx_ctl  ),
    .rgmii_txd      (eth_txd     )
    );

arp
   #(
    .BOARD_MAC      (BOARD_MAC      ),
    .BOARD_IP       (BOARD_IP       ),
    .DES_MAC_DEFAULT(DES_MAC_DEFAULT),
    .DES_IP_DEFAULT (DES_IP_DEFAULT )
    )
   u_arp(
    .rst_n          (sys_rst_n      ),
    .gmii_rx_clk    (gmii_rx_clk    ),
    .gmii_rx_dv     (gmii_rx_dv     ),
    .gmii_rxd       (gmii_rxd       ),
    .gmii_tx_clk    (gmii_tx_clk    ),
    .gmii_tx_en     (arp_gmii_tx_en ),
    .gmii_txd       (arp_gmii_txd   ),
    .arp_rx_done    (arp_rx_done    ),
    .arp_rx_type    (arp_rx_type    ),
    .src_mac        (src_mac        ),
    .src_ip         (src_ip         ),
    .arp_tx_en      (arp_tx_en      ),
    .arp_tx_type    (arp_tx_type    ),
    .des_mac        (des_mac        ),
    .des_ip         (des_ip         ),
    .tx_done        (arp_tx_done    )
    );

icmp
   #(
    .BOARD_MAC      (BOARD_MAC        ),
    .BOARD_IP       (BOARD_IP         ),
    .DES_MAC_DEFAULT(DES_MAC_DEFAULT  ),
    .DES_IP_DEFAULT (DES_IP_DEFAULT   )
    )
   u_icmp(
    .rst_n          (sys_rst_n        ),
    .gmii_rx_clk    (gmii_rx_clk      ),
    .gmii_rx_dv     (gmii_rx_dv       ),
    .gmii_rxd       (gmii_rxd         ),
    .gmii_tx_clk    (gmii_tx_clk      ),
    .gmii_tx_en     (icmp_gmii_tx_en  ),
    .gmii_txd       (icmp_gmii_txd    ),
    .rec_pkt_done   (icmp_rec_pkt_done),
    .rec_en         (icmp_rec_en      ),
    .rec_data       (icmp_rec_data    ),
    .rec_byte_num   (icmp_rec_byte_num),
    .tx_start_en    (icmp_tx_start_en ),
    .tx_data        (icmp_tx_data     ),
    .tx_byte_num    (icmp_tx_byte_num ),
    .des_mac        (des_mac          ),
    .des_ip         (des_ip           ),
    .tx_done        (icmp_tx_done     ),
    .tx_req         (icmp_tx_req      )
    );

udp
   #(
    .BOARD_MAC      (BOARD_MAC      ),
    .BOARD_IP       (BOARD_IP       ),
    .DES_MAC_DEFAULT(DES_MAC_DEFAULT),
    .DES_IP_DEFAULT (DES_IP_DEFAULT )
    )
   u_udp(
    .rst_n          (sys_rst_n      ),
    .gmii_rx_clk    (gmii_rx_clk    ),
    .gmii_rx_dv     (gmii_rx_dv     ),
    .gmii_rxd       (gmii_rxd       ),
    .gmii_tx_clk    (gmii_tx_clk    ),
    .gmii_tx_en     (udp_gmii_tx_en ),
    .gmii_txd       (udp_gmii_txd   ),
    .rec_pkt_done   (               ),
    .rec_en         (               ),
    .rec_data       (               ),
    .rec_byte_num   (               ),
    .tx_start_en    (udp_tx_start_en),
    .tx_data        (udp_tx_data    ),
    .tx_byte_num    (udp_tx_byte_num),
    .des_mac        (des_mac        ),
    .des_ip         (des_ip         ),
    .tx_done        (udp_tx_done    ),
    .tx_req         (udp_tx_req     )
    );

//UDP 数据源: 从 frame_ram 读 1024 字节
frame_src
   #(
    .POINTS          (512            ),
    .HEADER          (6              ),
    .POINT_NUM       (512            )
    )
   u_frame_src(
    .clk             (gmii_tx_clk    ),
    .rst_n           (sys_rst_n      ),
    .frame_tog       (frame_tog      ),
    .frame_sel       (frame_sel      ),
    .tx_ready        (udp_tx_ready   ),
    .tx_start_en     (udp_tx_start_en),
    .tx_byte_num     (udp_tx_byte_num),
    .tx_req          (udp_tx_req     ),
    .tx_data         (udp_tx_data    ),
    .tx_done         (udp_tx_done    ),
    .rd_addr         (frame_raddr_int),
    .rd_data         (frame_rdata    )
    );

//异步FIFO(只给 ping 回环用)
async_fifo_2048x8b u_async_fifo_2048x8b (
    .rst            (~sys_rst_n ),
    .wr_clk         (gmii_rx_clk),
    .rd_clk         (gmii_rx_clk),
    .din            (rec_data   ),
    .wr_en          (rec_en     ),
    .rd_en          (tx_req     ),
    .dout           (tx_data    ),
    .full           (),
    .empty          ()
);

eth_ctrl u_eth_ctrl(
    .clk              (gmii_rx_clk     ),
    .rst_n            (sys_rst_n       ),
    .arp_rx_done      (arp_rx_done     ),
    .arp_rx_type      (arp_rx_type     ),
    .arp_tx_en        (arp_tx_en       ),
    .arp_tx_type      (arp_tx_type     ),
    .arp_tx_done      (arp_tx_done     ),
    .arp_gmii_tx_en   (arp_gmii_tx_en  ),
    .arp_gmii_txd     (arp_gmii_txd    ),
    .icmp_rec_pkt_done(icmp_rec_pkt_done),
    .icmp_tx_start_en (icmp_tx_start_en),
    .icmp_tx_done     (icmp_tx_done    ),
    .icmp_gmii_tx_en  (icmp_gmii_tx_en ),
    .icmp_gmii_txd    (icmp_gmii_txd   ),
    .icmp_rec_en      (icmp_rec_en     ),
    .icmp_rec_data    (icmp_rec_data   ),
    .icmp_tx_req      (icmp_tx_req     ),
    .icmp_tx_data     (icmp_tx_data    ),
    .udp_tx_start_en  (udp_tx_start_en ),
    .udp_tx_done      (udp_tx_done     ),
    .udp_gmii_tx_en   (udp_gmii_tx_en  ),
    .udp_gmii_txd     (udp_gmii_txd    ),
    .udp_tx_ready     (udp_tx_ready    ),
    .rec_data         (rec_data        ),
    .rec_en           (rec_en          ),
    .tx_req           (tx_req          ),
    .tx_data          (tx_data         ),
    .gmii_tx_en       (gmii_tx_en      ),
    .gmii_txd         (gmii_txd        )
    );

//*****************************************************
//**              调试指示灯(只看闪不闪, 极性不关心)
//**  led[0] : 以太网 RXC 时钟心跳    闪 = 网口时钟正常
//**  led[1] : sys_clk 心跳(MMCM锁定) 闪 = FPGA 已配置
//**  led[2] : 每 256 包 UDP 发完翻转 闪 = UDP 在发
//*****************************************************

reg [22:0] rx_clk_cnt  ;
reg        rx_clk_led  ;
reg [22:0] sys_clk_cnt ;
reg        sys_clk_led ;
reg [ 7:0] done_cnt    ;
reg        done_led    ;

always @(posedge gmii_rx_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        rx_clk_cnt <= 23'd0;
        rx_clk_led <= 1'b0;
    end
    else if (rx_clk_cnt >= 23'd5_000_000) begin
        rx_clk_cnt <= 23'd0;
        rx_clk_led <= ~rx_clk_led;
    end
    else
        rx_clk_cnt <= rx_clk_cnt + 23'd1;
end

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        sys_clk_cnt <= 23'd0;
        sys_clk_led <= 1'b0;
    end
    else if (locked && (sys_clk_cnt >= 23'd2_000_000)) begin
        sys_clk_cnt <= 23'd0;
        sys_clk_led <= ~sys_clk_led;
    end
    else if (locked)
        sys_clk_cnt <= sys_clk_cnt + 23'd1;
    else ;
end

always @(posedge gmii_tx_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        done_cnt <= 8'd0;
        done_led <= 1'b0;
    end
    else if (udp_tx_done) begin
        done_cnt <= done_cnt + 8'd1;
        if (done_cnt == 8'hFF)
            done_led <= ~done_led;
        else ;
    end
    else ;
end

assign led[0] = rx_clk_led;
assign led[1] = sys_clk_led;
assign led[2] = done_led;
assign led[3] = 1'b0;

endmodule
