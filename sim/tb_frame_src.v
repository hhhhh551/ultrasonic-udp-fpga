`timescale 1ns/1ps
//****************************************************************************************//
// tb_frame_src : 验证 UDP 数据源
//   模拟 udp_tx 的 tx_req 时序(连续 1030 次读请求), 检查:
//     1) tx_byte_num = 1030
//     2) 包头 AA 55 + 序号 + 点数(512)
//     3) 1024 字节数据 = 512 个点大端排列
//     4) 连发两帧, 序号递增
//****************************************************************************************//
module tb_frame_src;

localparam integer POINTS  = 512;
localparam integer PKT     = 1030;      // 6 + 1024

reg         clk;
reg         rst_n;
reg         frame_tog;
reg         frame_sel;
reg         tx_ready;
reg         tx_req;
reg         tx_done;

wire        tx_start_en;
wire [15:0] tx_byte_num;
wire [7:0]  tx_data;
wire [9:0]  rd_addr;
reg  [15:0] rd_data;

always #4 clk = ~clk;                    // 125MHz

//----------------- 模拟 frame_ram 读口
reg [15:0] mem [0:1023];

always @(posedge clk) begin
    rd_data <= mem[rd_addr];
end

//----------------- DUT
frame_src #(
    .POINTS   (POINTS),
    .HEADER   (6    ),
    .POINT_NUM(512  )
) u_dut (
    .clk        (clk       ),
    .rst_n      (rst_n     ),
    .frame_tog  (frame_tog ),
    .frame_sel  (frame_sel ),
    .tx_ready   (tx_ready  ),
    .tx_start_en(tx_start_en),
    .tx_byte_num(tx_byte_num),
    .tx_req     (tx_req    ),
    .tx_data    (tx_data   ),
    .tx_done    (tx_done   ),
    .rd_addr    (rd_addr   ),
    .rd_data    (rd_data   )
);

//----------------- 记录发出去的字节
// tx_data 在 tx_req 有效的下一个时钟才变成该字节, 所以用 tx_req 打一拍再采样
reg       tx_req_d;
reg [7:0] cap [0:2047];
reg [9:0] h_addr [0:2047];
reg [15:0] h_data [0:2047];
integer   cap_n;

always @(posedge clk) begin
    tx_req_d <= tx_req;
    if (tx_req_d) begin
        cap[cap_n]    = tx_data;
        h_addr[cap_n] = rd_addr;
        h_data[cap_n] = rd_data;
        cap_n         = cap_n + 1;
    end
end

//----------------- 跑一包
integer err, p, k, i;
reg [15:0] seq_expect;

task run_packet;
    integer n;
    begin
        // 等 frame_src 启动
        wait (tx_start_en == 1'b1);
        repeat (60) @(posedge clk);      // 模拟 udp_tx 发前导码+各层包头
        tx_req = 1'b1;
        for (n = 0; n < PKT; n = n + 1) @(posedge clk);
        tx_req = 1'b0;
        repeat (4) @(posedge clk);
        tx_done = 1'b1;
        @(posedge clk);
        tx_done = 1'b0;
        repeat (10) @(posedge clk);
    end
endtask

initial begin
    err = 0; cap_n = 0; seq_expect = 16'd1;
    clk = 0; rst_n = 0; frame_tog = 0; frame_sel = 0;
    tx_ready = 1; tx_req = 0; tx_done = 0;

    // 填 RAM: 第 k 点 = 16'h5A00 + k  (高字节 0x5A/0x5B, 低字节 = k&0xFF)
    for (i = 0; i < POINTS; i = i + 1) mem[i]         = 16'h5A00 + i[15:0];
    for (i = 0; i < POINTS; i = i + 1) mem[512 + i]   = 16'h6B00 + i[15:0];

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    //================ 第一帧(缓冲0) ================
    cap_n = 0;
    @(negedge clk); frame_sel = 1'b0; frame_tog = ~frame_tog;
    run_packet;

    $display("");
    $display("=============== frame_src 第 1 帧 ===============");
    $display(" 收到的字节数     = %0d (期望 %0d)", cap_n, PKT);
    if (cap_n != PKT) begin $display(" FAIL: 字节数不对"); err = err + 1; end
    if (tx_byte_num !== 16'd1030) begin $display(" FAIL: tx_byte_num=%0d", tx_byte_num); err = err + 1; end

    $display(" 包头             = %02h %02h %02h %02h %02h %02h",
             cap[0],cap[1],cap[2],cap[3],cap[4],cap[5]);
    if (cap[0] !== 8'hAA) begin $display(" FAIL: 帧头0"); err = err + 1; end
    if (cap[1] !== 8'h55) begin $display(" FAIL: 帧头1"); err = err + 1; end
    if ({cap[2],cap[3]} !== seq_expect) begin
        $display(" FAIL: 序号 = %0d, 期望 %0d", {cap[2],cap[3]}, seq_expect); err = err + 1;
    end
    if ({cap[4],cap[5]} !== 16'd512) begin
        $display(" FAIL: 点数 = %0d, 期望 512", {cap[4],cap[5]}); err = err + 1;
    end

    // 检查数据区
    for (k = 0; k < POINTS; k = k + 1) begin
        if ({cap[6 + 2*k], cap[7 + 2*k]} !== (16'h5A00 + k[15:0])) begin
            $display(" FAIL: 第 %0d 点 = %04h, 期望 %04h",
                     k, {cap[6 + 2*k], cap[7 + 2*k]}, 16'h5A00 + k[15:0]);
            err = err + 1;
            if (err > 6) k = POINTS;
        end
    end
    $display(" 前 4 点          = %04h %04h %04h %04h",
             {cap[6],cap[7]}, {cap[8],cap[9]}, {cap[10],cap[11]}, {cap[12],cap[13]});
    $display(" 末 2 点          = %04h %04h",
             {cap[6+2*510],cap[7+2*510]}, {cap[6+2*511],cap[7+2*511]});
    $display(" 调试: 点 254..258 = %04h %04h %04h %04h %04h  (期望 %04h %04h %04h %04h %04h)",
             {cap[6+2*254],cap[7+2*254]}, {cap[6+2*255],cap[7+2*255]},
             {cap[6+2*256],cap[7+2*256]}, {cap[6+2*257],cap[7+2*257]},
             {cap[6+2*258],cap[7+2*258]},
             16'h5A00+254, 16'h5A00+255, 16'h5A00+256, 16'h5A00+257, 16'h5A00+258);
    $display(" mem[255..258]     = %04h %04h %04h %04h",
             mem[255], mem[256], mem[257], mem[258]);
    for (i = 516; i <= 520; i = i + 1)
        $display("  cap[%0d] byte=%02h  rd_addr=%0d  rd_data=%04h", i, cap[i], h_addr[i], h_data[i]);

    //================ 第二帧(缓冲1) ================
    seq_expect = 16'd2;
    cap_n = 0;
    @(negedge clk); frame_sel = 1'b1; frame_tog = ~frame_tog;
    run_packet;

    $display("=============== frame_src 第 2 帧 ===============");
    $display(" 收到的字节数     = %0d (期望 %0d)", cap_n, PKT);
    $display(" 包头             = %02h %02h %02h %02h %02h %02h",
             cap[0],cap[1],cap[2],cap[3],cap[4],cap[5]);
    if (cap_n != PKT) begin $display(" FAIL: 字节数不对"); err = err + 1; end
    if ({cap[2],cap[3]} !== seq_expect) begin
        $display(" FAIL: 序号 = %0d, 期望 %0d", {cap[2],cap[3]}, seq_expect); err = err + 1;
    end
    for (k = 0; k < POINTS; k = k + 1) begin
        if ({cap[6 + 2*k], cap[7 + 2*k]} !== (16'h6B00 + k[15:0])) begin
            $display(" FAIL: 第 %0d 点 = %04h, 期望 %04h (说明读错了缓冲)",
                     k, {cap[6 + 2*k], cap[7 + 2*k]}, 16'h6B00 + k[15:0]);
            err = err + 1;
            if (err > 12) k = POINTS;
        end
    end
    $display(" 前 4 点          = %04h %04h %04h %04h",
             {cap[6],cap[7]}, {cap[8],cap[9]}, {cap[10],cap[11]}, {cap[12],cap[13]});

    $display("================================================");
    if (err == 0) $display("================ TEST PASS ================");
    else          $display("================ TEST FAIL (%0d) ================", err);
    $finish;
end

initial begin
    #500000;
    $display("TIMEOUT (cap_n=%0d)", cap_n);
    $finish;
end

endmodule
