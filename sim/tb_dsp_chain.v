`timescale 1ns/1ps
//****************************************************************************************//
// tb_dsp_chain : 验证 带通 -> 整流 -> 包络 -> 8:1抽取 整条链路
//   在已知采样点处注入 2.5MHz 高斯包络回波(幅度 300 LSB, 直流偏置 502),
//   检查: 点数 / 包络幅值 / 时间对齐(LATENCY) / 直流抑制
//****************************************************************************************//
module tb_dsp_chain;

localparam real    FS     = 50.0e6;
localparam real    FREQ   = 2.5e6;
localparam real    AMP    = 300.0;
localparam real    TAU    = 1.2e-6;
localparam integer C      = 1200;      // 回波中心采样点
localparam integer TRIG_N = 300;       // 触发时刻(ADC采样点)
localparam integer LAT    = 92;        // 实测得到的整条链路延时(采样点)
localparam integer DECIM  = 8;
localparam integer EXP_PT = (C - TRIG_N) / DECIM;   // 对齐后期望的峰值点号

reg        clk;
reg        rst_n;
reg [9:0]  adc;
reg        trig;
integer    n;

always #10 clk = ~clk;                 // 50MHz

//----------------- ADC 激励(下降沿更新, 上升沿稳定)
real    envr, sig;
integer adc_i;

always @(negedge clk) begin
    n = n + 1;
    envr = $exp(-(1.0*(n-C)*(n-C)) / (2.0*(TAU*FS)*(TAU*FS)));
    sig  = AMP * envr * $sin(6.283185307179586 * FREQ * (n-C) / FS);
    adc_i = $rtoi(502.0 + sig + 0.5);
    if (adc_i < 0)    adc_i = 0;
    if (adc_i > 1023) adc_i = 1023;
    adc <= adc_i[9:0];
end

//----------------- DUT
wire [15:0] env_data;
wire        env_we;
wire [8:0]  env_addr;
wire        frame_done;

dsp_chain #(
    .LATENCY(LAT),
    .DECIM  (DECIM),
    .POINTS (512)
) u_dut (
    .clk       (clk       ),
    .rst_n     (rst_n     ),
    .adc_data  (adc       ),
    .trig      (trig      ),
    .env_data  (env_data  ),
    .env_we    (env_we    ),
    .env_addr  (env_addr  ),
    .frame_done(frame_done)
);

//----------------- 采集
integer cap [0:511];
integer got [0:511];
integer i;

always @(posedge clk) begin
    if (env_we) begin
        cap[env_addr] = env_data;
        got[env_addr] = 1;
    end
end

integer k, peak_k, peak_v, cnt, min_v, err, d_pt;

initial begin
    for (i = 0; i < 512; i = i + 1) begin cap[i] = 0; got[i] = 0; end
    peak_k = 0; peak_v = 0; cnt = 0; min_v = 999999; err = 0;
    clk = 1'b0; rst_n = 1'b0; trig = 1'b0; n = -1;
    repeat (10) @(negedge clk);
    rst_n = 1'b1;

    wait (n == TRIG_N);
    @(negedge clk);
    trig = 1'b1;
    @(negedge clk);
    trig = 1'b0;

    wait (frame_done == 1'b1);
    repeat (20) @(negedge clk);

    for (i = 0; i < 512; i = i + 1) begin
        if (got[i] == 1) cnt = cnt + 1;
        if (cap[i] > peak_v) begin peak_v = cap[i]; peak_k = i; end
        if (cap[i] < min_v)  min_v  = cap[i];
    end
    d_pt = peak_k - EXP_PT;

    $display("");
    $display("================ dsp_chain 结果 ================");
    $display(" 写入包络点数        = %0d  (期望 512)", cnt);
    $display(" 包络峰值            = %0d  @ 第 %0d 点", peak_v, peak_k);
    $display(" 期望峰值点号        = %0d  (回波中心 %0.3f us / 抽取比 %0d)",
             EXP_PT, (C-TRIG_N)/FS*1e6, DECIM);
    $display(" 峰值点误差          = %0d 点 = %0d 个采样 = %0.0f ns",
             d_pt, d_pt*DECIM, d_pt*DECIM/FS*1e9);
    $display(" 包络幅值(期望~%0d) = %0d", 191*64, peak_v);
    $display(" 包络最小值          = %0d  (无回波处, 期望 ~0)", min_v);
    $display("------------------------------------------------");
    $display(" 前 8 点             = %0d %0d %0d %0d %0d %0d %0d %0d",
             cap[0],cap[1],cap[2],cap[3],cap[4],cap[5],cap[6],cap[7]);
    $display(" 峰值附近            = %0d %0d %0d %0d %0d",
             cap[peak_k-2],cap[peak_k-1],cap[peak_k],cap[peak_k+1],cap[peak_k+2]);
    $display(" 末尾 508..511       = %0d %0d %0d %0d",
             cap[508],cap[509],cap[510],cap[511]);

    if (cnt != 512)                       begin $display(" FAIL: 点数不对");        err = err + 1; end
    if ((d_pt > 1) || (d_pt < -1))        begin $display(" FAIL: 峰值点号偏差>1");   err = err + 1; end
    if (peak_v < 11000 || peak_v > 13000) begin $display(" FAIL: 包络幅值不对");     err = err + 1; end
    if (cap[0] != 0)                      begin $display(" FAIL: 起点应无回波");     err = err + 1; end

    if (err == 0) $display("================ TEST PASS ================");
    else          $display("================ TEST FAIL (%0d) ================", err);
    $finish;
end

initial begin
    #(2000000);
    $display("TIMEOUT");
    $finish;
end

endmodule
