//****************************************************************************************//
// File name:   frame_ram.v
// Descriptions: 包络帧缓冲 (乒乓双缓冲, 双时钟)
//
//   写口: 采集时钟域(sys_clk 50MHz), 由 dsp_chain 写 512 个 16bit 包络点
//   读口: 以太网时钟域(eth_rxc 125MHz), 由 frame_src 读给 UDP 发送
//
//   两片缓冲交替使用: 发送第 N 帧的同时, 采集第 N+1 帧, 互不干扰。
//   地址 = {缓冲号, 点号}  共 10bit
//****************************************************************************************//
module frame_ram #(
    parameter integer POINTS = 512
)(
    // 写口(采集时钟域)
    input  wire        wr_clk   ,
    input  wire        wr_en    ,
    input  wire        wr_sel   ,     // 缓冲号 0/1
    input  wire [8:0]  wr_addr  ,
    input  wire [15:0] wr_data  ,
    // 读口(以太网时钟域)
    input  wire        rd_clk   ,
    input  wire [9:0]  rd_addr  ,
    output reg  [15:0] rd_data
    );

localparam integer DEPTH = POINTS * 2;

reg [15:0] mem [0:DEPTH-1];

// 写
always @(posedge wr_clk) begin
    if (wr_en)
        mem[{wr_sel, wr_addr}] <= wr_data;
end

// 读(同步读, 输出寄存 -> 综合成 BRAM)
always @(posedge rd_clk) begin
    rd_data <= mem[rd_addr];
end

endmodule
