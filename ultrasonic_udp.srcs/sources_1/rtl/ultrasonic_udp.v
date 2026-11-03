//****************************************************************************************//
// File name:   ultrasonic_udp.v
// Descriptions: 超声检测顶层 —— 激励 + 50MHz ADC 采集 + 滤波/包络检波 + UDP 上传
//
//   数据流:
//     pulse_gen 每 18ms 发一个 200ns 高压激励脉冲(E16), 同时给出 trig
//        |
//        v
//     ADC 50MHz 采样(10bit) -> dsp_chain
//        带通FIR(0.8~4.5MHz) -> 全波整流 -> 包络低通FIR(1.5MHz) -> 8:1抽取
//        -> 512 个 16bit 包络点
//        |
//        v
//     frame_ram 乒乓缓冲 (写:50MHz 采集域 / 读:125MHz 以太网域)
//        |
//        v
//     eth_udp_tx : 每帧采完发一包 UDP, 1024 字节 = 512 点 x 2 字节(大端)
//
//   深度标定: 512 点 x 8 x 20ns = 81.92us, 钢铁纵波 5900m/s -> 24.2cm
//             每点对应 0.472mm
//
//   UDP 包: 源IP 192.168.1.10, 目的IP 192.168.0.145(可在参数里改),
//           源/目的端口都是 1234, 目标MAC 默认广播(电脑 ping 一次板子后改单播)
//****************************************************************************************//
module ultrasonic_udp(
    input              sys_clk   , //50MHz 系统时钟
    input              sys_rst_n , //复位, 低有效
    //以太网 RGMII
    input              eth_rxc   ,
    input              eth_rx_ctl,
    input       [3:0]  eth_rxd   ,
    output             eth_txc   ,
    output             eth_tx_ctl,
    output      [3:0]  eth_txd   ,
    output             eth_rst_n ,
    //10bit 并行 ADC
    input       [9:0]  ad_data  , //ADC 数据(0~1023, 0V 约 502)
    output             ad_clk   , //ADC 驱动时钟
    output             ad_oe    , //ADC 输出使能(低有效)
    //超声激励
    output             pulse_n  , //高压激励脉冲(低有效)
    //调试指示灯
    output      [3:0]  led
    );

//parameter define
//激励参数
parameter integer PERIOD_NS      = 18_000_000; //激励周期 18ms
parameter integer PULSE_WIDTH_NS = 200;        //脉冲宽度 200ns
//以太网参数
parameter BOARD_MAC       = 48'h00_11_22_33_44_55;
parameter BOARD_IP        = {8'd192,8'd168,8'd1,8'd10};
parameter DES_MAC_DEFAULT = 48'hff_ff_ff_ff_ff_ff;
parameter DES_IP_DEFAULT  = {8'd192,8'd168,8'd0,8'd145};
parameter IDELAY_VALUE    = 0;
//采集/DSP参数
parameter integer PKT_BYTES = 1024;            //每包 512 点 x 2 字节

//wire define
wire          trig          ;   //采集触发
wire  [15:0]  env_data      ;   //包络点
wire          env_we        ;   //包络写使能
wire  [8:0]   env_addr      ;   //包络写地址
wire          frame_done    ;   //一帧采完

reg           frame_sel_w   ;   //当前写入的缓冲号
reg           frame_sel_e   ;   //刚采完那帧的缓冲号(给以太网侧)
reg           frame_tog_r   ;   //帧就绪翻转信号

wire  [3:0]   led_eth       ;
reg   [22:0]  acq_cnt       ;
reg           acq_led       ;

//*****************************************************
//**                    main code
//*****************************************************

//ADC 驱动时钟: sys_clk 取反 -> ADC 在 sys_clk 下降沿出数据,
//在 sys_clk 上升沿采样, 正好落在数据稳定的中间
assign ad_clk = ~sys_clk;
assign ad_oe  = 1'b0;

//激励脉冲
pulse_gen
   #(
    .CLK_FREQ_HZ     (50_000_000     ),
    .PERIOD_NS       (PERIOD_NS      ),
    .PULSE_WIDTH_NS  (PULSE_WIDTH_NS )
    )
   u_pulse_gen(
    .clk             (sys_clk        ),
    .rst_n           (sys_rst_n      ),
    .pulse_n         (pulse_n        ),
    .trig            (trig           )
    );

//ADC 采集 + 滤波 + 包络检波
dsp_chain
   #(
    .LATENCY         (92             ),
    .DECIM           (8              ),
    .POINTS          (512            )
    )
   u_dsp_chain(
    .clk             (sys_clk        ),
    .rst_n           (sys_rst_n      ),
    .adc_data        (ad_data        ),
    .trig            (trig           ),
    .env_data        (env_data       ),
    .env_we          (env_we         ),
    .env_addr        (env_addr       ),
    .frame_done      (frame_done     )
    );

//乒乓缓冲选择 + 帧就绪跨时钟信号
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        frame_sel_w <= 1'b0;
        frame_sel_e <= 1'b0;
        frame_tog_r <= 1'b0;
    end
    else if (frame_done) begin
        frame_sel_e <= frame_sel_w;      // 这一帧存在 frame_sel_w 里
        frame_tog_r <= ~frame_tog_r;     // 通知以太网侧
        frame_sel_w <= ~frame_sel_w;     // 下一帧写另一片
    end
end

//以太网 + 帧缓冲 + UDP 发送
eth_udp_tx
   #(
    .BOARD_MAC       (BOARD_MAC       ),
    .BOARD_IP        (BOARD_IP        ),
    .DES_MAC_DEFAULT (DES_MAC_DEFAULT ),
    .DES_IP_DEFAULT  (DES_IP_DEFAULT  ),
    .IDELAY_VALUE    (IDELAY_VALUE    ),
    .PKT_BYTES       (PKT_BYTES       )
    )
   u_eth_udp_tx(
    .sys_clk         (sys_clk         ),
    .sys_rst_n       (sys_rst_n       ),
    .eth_rxc         (eth_rxc         ),
    .eth_rx_ctl      (eth_rx_ctl      ),
    .eth_rxd         (eth_rxd         ),
    .eth_txc         (eth_txc         ),
    .eth_tx_ctl      (eth_tx_ctl      ),
    .eth_txd         (eth_txd         ),
    .eth_rst_n       (eth_rst_n       ),
    .frame_tog       (frame_tog_r     ),
    .frame_sel       (frame_sel_e     ),
    .frame_wr_en     (env_we          ),
    .frame_wr_sel    (frame_sel_w     ),
    .frame_wr_addr   (env_addr        ),
    .frame_wr_data   (env_data        ),
    .led             (led_eth         )
    );

//采集心跳灯: 每采完 256 帧翻转一次(18ms x 256 ≈ 4.6s)
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        acq_cnt <= 23'd0;
        acq_led <= 1'b0;
    end
    else if (frame_done) begin
        if (acq_cnt == 23'd0) begin
            acq_cnt <= 23'd255;
            acq_led <= ~acq_led;
        end
        else
            acq_cnt <= acq_cnt - 23'd1;
    end
end

//led[0] 以太网RXC心跳   led[1] sys_clk心跳   led[2] 每256包UDP翻转
//led[3] 每256帧采集翻转(闪 = 采集在跑)
assign led = {acq_led, led_eth[2:0]};

endmodule
