//****************************************************************************************//
// File name:   fir_sym.v
// Descriptions: 对称线性相位 FIR 滤波器 (通用, 系数从 fir_coef.vh 的常量函数取)
//
//   N     : 抽头数, 必须是奇数 (63 / 95)
//   SEL   : 0 = 带通 BPF (bpf_coef) , 1 = 包络低通 (env_coef)
//   DW    : 输入数据位宽(有符号)
//   对称结构: h[k] == h[N-1-k] , 先加后乘, 乘法器数 = (N+1)/2
//
//   流水线(总延时 = 5 + LEVELS 拍, LEVELS = log2((N+1)/2)):
//     移位寄存器 1 拍 + 乘积 1 拍 + 叶节点寄存 1 拍 + 加法树 LEVELS 拍 + 输出 2 拍
//****************************************************************************************//

module fir_sym #(
    parameter integer N   = 63,     // 抽头数(奇数)
    parameter integer SEL = 0,      // 0=带通  1=包络低通
    parameter integer DW  = 16,     // 输入位宽
    parameter integer CW  = 18,     // 系数位宽
    parameter integer OW  = 24      // 输出位宽(有符号, 已除以 2^(CW-1) 还原)
)(
    input  wire                  clk      ,
    input  wire                  rst_n    ,
    input  wire signed [DW-1:0]  din      ,
    output reg  signed [OW-1:0]  dout
    );

`include "fir_coef.vh"

//--------------------------------------------------------------- localparam
localparam integer HALF   = (N - 1) / 2;        // 对称对数
localparam integer M      = HALF + 1;           // 乘法项数(含中心抽头)
localparam integer PW     = DW + 1 + CW;        // 乘积位宽
localparam integer LEVELS = $clog2(M);          // 加法树级数
localparam integer AW     = PW + LEVELS;        // 加法器位宽

//--------------------------------------------------------------- 系数选择
function signed [CW-1:0] get_coef;
    input integer i;
    begin
        if (SEL == 0)
            get_coef = bpf_coef(i);
        else
            get_coef = env_coef(i);
    end
endfunction

//--------------------------------------------------------------- 移位寄存器
reg signed [DW-1:0] dly [0:N-1];
integer i_dly;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i_dly = 0; i_dly < N; i_dly = i_dly + 1)
            dly[i_dly] <= {DW{1'b0}};
    end
    else begin
        dly[0] <= din;
        for (i_dly = 1; i_dly < N; i_dly = i_dly + 1)
            dly[i_dly] <= dly[i_dly-1];
    end
end

//--------------------------------------------------------------- 先加后乘
wire signed [CW-1:0] coef_w [0:M-1];
wire signed [DW:0]   pair_w [0:M-1];
wire signed [PW-1:0] leaf_w [0:M-1];

genvar gk;
generate
    for (gk = 0; gk < M; gk = gk + 1) begin : gen_tap
        assign coef_w[gk] = get_coef(gk);
        if (gk == HALF) begin : g_center
            assign pair_w[gk] = {dly[gk][DW-1], dly[gk]};
        end
        else begin : g_pair
            assign pair_w[gk] = {dly[gk][DW-1], dly[gk]} +
                                {dly[N-1-gk][DW-1], dly[N-1-gk]};
        end
        assign leaf_w[gk] = pair_w[gk] * coef_w[gk];
    end
endgenerate

reg signed [PW-1:0] prod [0:M-1];
integer i_prd;

always @(posedge clk) begin
    for (i_prd = 0; i_prd < M; i_prd = i_prd + 1)
        prod[i_prd] <= leaf_w[i_prd];
end

//--------------------------------------------------------------- 加法树
reg signed [AW-1:0] sum_lv [0:LEVELS][0:(1<<LEVELS)-1];
integer jj, jx;

// 第 0 级: 乘积符号扩展后寄存
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (jj = 0; jj < (1<<LEVELS); jj = jj + 1)
            sum_lv[0][jj] <= {AW{1'b0}};
    end
    else begin
        for (jj = 0; jj < (1<<LEVELS); jj = jj + 1) begin
            if (jj < M)
                sum_lv[0][jj] <= {{(AW-PW){prod[jj][PW-1]}}, prod[jj]};
            else
                sum_lv[0][jj] <= {AW{1'b0}};
        end
    end
end

genvar gl;
generate
    for (gl = 1; gl <= LEVELS; gl = gl + 1) begin : gen_lv
        localparam integer SZ = (1 << (LEVELS - gl));
        integer jz;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                for (jz = 0; jz < SZ; jz = jz + 1)
                    sum_lv[gl][jz] <= {AW{1'b0}};
            end
            else begin
                for (jz = 0; jz < SZ; jz = jz + 1)
                    sum_lv[gl][jz] <= sum_lv[gl-1][2*jz] + sum_lv[gl-1][2*jz+1];
            end
        end
    end
endgenerate

//--------------------------------------------------------------- 输出: 算术右移还原比例 + 2 级寄存器
wire signed [AW-1:0] acc = sum_lv[LEVELS][0];

reg signed [OW-1:0] dout_r0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dout_r0 <= {OW{1'b0}};
        dout    <= {OW{1'b0}};
    end
    else begin
        dout_r0 <= acc >>> (CW-1);       // 算术右移, 保持符号
        dout    <= dout_r0;
    end
end

endmodule
