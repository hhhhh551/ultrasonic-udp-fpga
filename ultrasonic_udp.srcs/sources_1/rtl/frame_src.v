//****************************************************************************************//
// File name:   frame_src.v
// Descriptions: UDP 发送数据源
//
//   以太网时钟域。采集帧就绪后启动一包 UDP 发送, 载荷 1030 字节:
//
//     偏移 0    : 0xAA          帧头
//     偏移 1    : 0x55
//     偏移 2..3 : 帧序号(16bit 大端, 每发一包加 1)  <- 上位机可据此判丢包
//     偏移 4..5 : 点数 = 512(大端)
//     偏移 6..  : 1024 字节 = 512 个 16bit 包络点(大端)
//
//   这个格式和上位机 AScanProtocol.cs 里的 "带包头格式"(FramedBytes = 1030) 完全对应,
//   上位机会自动识别, 并且用序号判断有没有丢帧。
//
//   数据输出时序与 udp_tx 要求一致(标准FIFO读出时序):
//       tx_req 有效 -> 下一个时钟 tx_data 输出对应字节
//
//   frame_tog 是采集时钟域送来的"帧就绪"翻转信号, 这里做两级同步;
//   frame_sel 在 frame_tog 翻转期间保持稳定, 可直接使用。
//****************************************************************************************//
module frame_src #(
    parameter integer POINTS    = 512,      // 每帧点数
    parameter integer HEADER    = 6,        // 包头字节数
    parameter [15:0]  POINT_NUM = 512       // 包头里写的点数
)(
    input  wire        clk        ,   // 以太网时钟域
    input  wire        rst_n      ,

    input  wire        frame_tog  ,   // 帧就绪翻转信号(异步)
    input  wire        frame_sel  ,   // 该帧所在缓冲号(异步, 稳定)
    input  wire        tx_ready   ,   // 介质空闲, 可以启动新的一包

    output reg         tx_start_en,   // 启动发送(单周期)
    output reg  [15:0] tx_byte_num,   // 本包字节数
    input  wire        tx_req     ,   // udp_tx 读数据请求
    output reg  [7:0]  tx_data    ,   // 待发送字节
    input  wire        tx_done    ,   // 本包发送完成

    output reg  [9:0]  rd_addr    ,   // 送 frame_ram 读地址
    input  wire [15:0] rd_data        // frame_ram 读出数据
    );

localparam integer PKT_BYTES = HEADER + POINTS * 2;   // 6 + 1024 = 1030

//--------------------------------------------------------------- 帧就绪同步
reg [1:0] tog_sync;
reg       tog_prev;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tog_sync <= 2'b00;
        tog_prev <= 1'b0;
    end
    else begin
        tog_sync <= {tog_sync[0], frame_tog};
        tog_prev <= tog_sync[1];
    end
end

wire frame_new = tog_sync[1] ^ tog_prev;

//--------------------------------------------------------------- 主逻辑
reg        pending  ;
reg        busy     ;
reg        sel_q    ;
reg [10:0] byte_cnt ;      // 0 ~ 1029
reg [15:0] seq_cnt  ;      // 帧序号

// 包头
reg [7:0] hdr_byte;
always @(*) begin
    case (byte_cnt)
        11'd0:   hdr_byte = 8'hAA;
        11'd1:   hdr_byte = 8'h55;
        11'd2:   hdr_byte = seq_cnt[15:8];
        11'd3:   hdr_byte = seq_cnt[7:0];
        11'd4:   hdr_byte = POINT_NUM[15:8];
        11'd5:   hdr_byte = POINT_NUM[7:0];
        default: hdr_byte = 8'h00;
    endcase
end

// 数据部分读地址
// 时序推导(rd_data 是外部 RAM 的同步读输出, 相对 rd_addr 迟 1 拍):
//   tx_data(t+1) 用的是 rd_data(t), 而 rd_data(t) = mem[rd_addr(t-1)]
//   rd_addr(t) 又是用 byte_cnt(t-1) 打拍出来的
//   => 真正生效的地址其实依据 byte_cnt(t-2)
//   要求 rd_data(t) = mem[d(t)/2], d(t) = byte_cnt(t) - HEADER
//   => (byte_cnt(t-2) - K)/2 == (byte_cnt(t) - HEADER)/2
//   => K = HEADER - 2 = 4
// 所以这里减 4(不是 HEADER-1=5), 否则在点数跨 256 边界处会错一个字节。
wire [10:0] dsub = (byte_cnt >= 11'd4) ? (byte_cnt - 11'd4) : 11'd0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pending     <= 1'b0;
        busy        <= 1'b0;
        sel_q       <= 1'b0;
        byte_cnt    <= 11'd0;
        seq_cnt     <= 16'd0;
        tx_start_en <= 1'b0;
        tx_byte_num <= PKT_BYTES[15:0];
        tx_data     <= 8'd0;
        rd_addr     <= 10'd0;
    end
    else begin
        tx_start_en <= 1'b0;
        rd_addr     <= {sel_q, dsub[9:1]};

        // 收到新的采集帧
        if (frame_new) begin
            pending <= 1'b1;
            sel_q   <= frame_sel;
        end

        // 介质空闲时启动一包
        if (pending && (busy == 1'b0) && tx_ready) begin
            pending     <= 1'b0;
            busy        <= 1'b1;
            byte_cnt    <= 11'd0;
            tx_start_en <= 1'b1;
            seq_cnt     <= seq_cnt + 16'd1;
        end

        if (tx_done)
            busy <= 1'b0;

        // 读数据请求: 下一个时钟输出对应字节
        if (tx_req) begin
            byte_cnt <= byte_cnt + 11'd1;
            if (byte_cnt < HEADER[10:0])
                tx_data <= hdr_byte;                        // 包头
            else
                tx_data <= byte_cnt[0] ? rd_data[7:0]       // 低字节
                                       : rd_data[15:8];     // 高字节
        end
    end
end

endmodule
