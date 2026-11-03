//****************************************************************************************//
// File name:   pulse_gen.v
// Descriptions: 超声激励脉冲发生器
//   周期 PERIOD_NS(默认 18ms) 产生一个低电平脉冲 PULSE_WIDTH_NS(默认 200ns),
//   同时给出单周期 trig 脉冲, 送给 dsp_chain 启动一帧采集。
//****************************************************************************************//
module pulse_gen #(
    parameter integer CLK_FREQ_HZ    = 50_000_000,
    parameter integer PERIOD_NS      = 18_000_000,
    parameter integer PULSE_WIDTH_NS = 200
)(
    input  wire clk      ,
    input  wire rst_n    ,
    output reg  pulse_n  ,     // 高压激励(低有效)
    output reg  trig           // 采集触发(与 pulse_n 下降沿同时, 单周期)
    );

localparam integer PERIOD_CYCLES = (64'd1 * CLK_FREQ_HZ * PERIOD_NS) / 64'd1_000_000_000;
localparam integer PULSE_CYCLES  = (64'd1 * CLK_FREQ_HZ * PULSE_WIDTH_NS + 64'd999_999_999)
                                   / 64'd1_000_000_000;
localparam integer CNT_W         = (PERIOD_CYCLES <= 1) ? 1 : $clog2(PERIOD_CYCLES);
localparam [CNT_W-1:0] PERIOD_LAST = PERIOD_CYCLES - 1;
localparam [CNT_W-1:0] PULSE_LOAD  = PULSE_CYCLES  - 1;

reg [CNT_W-1:0] period_cnt;
reg [CNT_W-1:0] pulse_cnt;

wire period_tick = (period_cnt == PERIOD_LAST);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        period_cnt <= {CNT_W{1'b0}};
        pulse_cnt  <= {CNT_W{1'b0}};
        pulse_n    <= 1'b1;
        trig       <= 1'b0;
    end
    else begin
        trig <= 1'b0;

        // 周期计数
        if (period_tick)
            period_cnt <= {CNT_W{1'b0}};
        else
            period_cnt <= period_cnt + 1'b1;

        // 脉冲宽度 + 触发
        if (period_tick) begin
            pulse_cnt <= PULSE_LOAD;
            pulse_n   <= 1'b0;
            trig      <= 1'b1;
        end
        else if (pulse_cnt != {CNT_W{1'b0}}) begin
            pulse_cnt <= pulse_cnt - 1'b1;
            pulse_n   <= 1'b0;
        end
        else begin
            pulse_n <= 1'b1;
        end
    end
end

endmodule
