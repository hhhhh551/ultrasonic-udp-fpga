//****************************************************************************************//
// File name:   dsp_chain.v
// Descriptions: 超声回波信号处理链
//
//   ADC(10bit,50MHz) -> 带通FIR(0.8~4.5MHz) -> |x| 全波整流 -> 包络低通FIR(1.5MHz)
//                    -> 8:1 抽取 -> 512 个 16bit 包络点 -> 写 RAM
//
//   直流偏置(实测 0V -> 502 而不是 512)由带通滤波器自然滤掉, 不需要单独标定。
//   (仿真验证: 纯直流 502 输入时, 带通输出稳态值为 0 LSB)
//
//   trig 上升沿启动一帧采集:
//     等待 LATENCY 拍后 (此时包络输出对应 ADC 第 0 个采样点),
//     每 8 拍取一个点, 共 512 点, 每点 16bit。
//     512 点 x 8 x 20ns = 81.92us -> 钢铁纵波 5900m/s 对应 24.2cm 深度。
//
//   包络幅值换算: env_data = 64 x (包络幅值, 单位 ADC LSB)
//     示例: 探头幅度 +-300LSB 时包络约 191, 输出约 12224 (实测 12160)
//****************************************************************************************//
module dsp_chain #(
    parameter integer LATENCY        = 92,   // ADC采样 -> 包络输出 的采样点延时, 已由仿真确定
    parameter integer DECIM          = 8,    // 抽取比
    parameter integer POINTS         = 512,  // 每帧点数
    parameter integer ENV_GAIN_SHIFT = 6     // 包络输出左移位数 (x64)
)(
    input  wire        clk       ,   // 50MHz 采样时钟
    input  wire        rst_n     ,
    input  wire [9:0]  adc_data  ,   // ADC 原始数据(无符号, 0~1023)
    input  wire        trig      ,   // 采集触发(单周期脉冲)

    output reg  [15:0] env_data  ,   // 包络点数据
    output reg         env_we    ,   // 写使能(单周期)
    output reg  [8:0]  env_addr  ,   // 写地址 0~511
    output reg         frame_done    // 一帧采完(单周期脉冲)
    );

//--------------------------------------------------------------- ADC 输入
// 直接当成有符号16位数送进带通, 直流分量由带通滤除
wire signed [15:0] adc_s = {6'd0, adc_data};

//--------------------------------------------------------------- 带通FIR
wire signed [23:0] bpf_out;

fir_sym #(
    .N   (63),
    .SEL (0),
    .DW  (16),
    .CW  (18),
    .OW  (24)
) u_bpf (
    .clk  (clk    ),
    .rst_n(rst_n  ),
    .din  (adc_s  ),
    .dout (bpf_out)
);

//--------------------------------------------------------------- 全波整流 |x|
// 取低16位即可(实际幅值只有 +-600 左右)
wire signed [15:0] bpf16   = bpf_out[15:0];
wire        [15:0] abs_val = bpf16[15] ? ((~bpf16) + 16'd1) : bpf16;
wire signed [15:0] env_in  = abs_val;

//--------------------------------------------------------------- 包络低通FIR
wire signed [23:0] env_out;

fir_sym #(
    .N   (95),
    .SEL (1),
    .DW  (16),
    .CW  (18),
    .OW  (24)
) u_env (
    .clk  (clk    ),
    .rst_n(rst_n  ),
    .din  (env_in ),
    .dout (env_out)
);

//--------------------------------------------------------------- 增益 + 饱和
// 包络理论上非负, 但滤波器输出在零点附近会出现很小的负值(取整),
// 必须先钳到 0 再左移, 否则 -1 会被当成 0xFFFF 变成满量程
wire signed [23:0] env_pos = env_out[23] ? 24'sd0 : env_out;
wire        [15:0] env16   = env_pos[15:0];
wire        [21:0] env_sh  = {6'd0, env16} << ENV_GAIN_SHIFT;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        env_data <= 16'd0;
    else if (|env_sh[21:16])
        env_data <= 16'hFFFF;          // 饱和
    else
        env_data <= env_sh[15:0];
end

//--------------------------------------------------------------- 采集控制
localparam integer LAST_PT = POINTS - 1;
localparam integer LAT_S   = (LATENCY > 0) ? (LATENCY - 1) : 0;

localparam [1:0] S_IDLE = 2'd0,   // 等触发
                 S_WAIT = 2'd1,   // 等流水线延时
                 S_CAP  = 2'd2;   // 抽取存储

reg        [1:0]  state   ;
reg        [15:0] acq_n   ;       // 触发后经过的采样时钟数
reg        [8:0]  pt_cnt  ;       // 已存点数
reg        [2:0]  ph_cnt  ;       // 抽取相位

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_IDLE;
        acq_n      <= 16'd0;
        pt_cnt     <= 9'd0;
        ph_cnt     <= 3'd0;
        env_we     <= 1'b0;
        env_addr   <= 9'd0;
        frame_done <= 1'b0;
    end
    else begin
        env_we     <= 1'b0;
        frame_done <= 1'b0;

        case (state)
            S_IDLE: begin
                if (trig) begin
                    acq_n  <= 16'd0;
                    pt_cnt <= 9'd0;
                    ph_cnt <= 3'd0;
                    state  <= S_WAIT;
                end
            end

            S_WAIT: begin
                // acq_n = LATENCY 时, 包络输出正好对应 ADC 第 0 个采样
                if (acq_n >= LAT_S) begin
                    acq_n  <= acq_n + 16'd1;
                    ph_cnt <= 3'd0;
                    state  <= S_CAP;
                end
                else
                    acq_n <= acq_n + 16'd1;
            end

            S_CAP: begin
                acq_n <= acq_n + 16'd1;
                if (ph_cnt == (DECIM[2:0] - 3'd1))
                    ph_cnt <= 3'd0;
                else
                    ph_cnt <= ph_cnt + 3'd1;

                if (ph_cnt == 3'd0) begin
                    env_we   <= 1'b1;
                    env_addr <= pt_cnt;
                    if (pt_cnt == LAST_PT[8:0]) begin
                        state      <= S_IDLE;
                        frame_done <= 1'b1;
                    end
                    else
                        pt_cnt <= pt_cnt + 9'd1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
