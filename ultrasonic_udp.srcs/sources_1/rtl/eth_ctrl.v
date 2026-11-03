//****************************************Copyright (c)***********************************//
//原子哥在线教学平台：www.yuanzige.com
//技术支持：http://www.openedv.com/forum.php
//淘宝店铺：https://zhengdianyuanzi.tmall.com
//关注微信公众平台微信号："正点原子"，免费获取ZYNQ & FPGA & STM32 & LINUX资料。
//版权所有，盗版必究。
//Copyright(C) 正点原子 2023-2033
//All rights reserved
//----------------------------------------------------------------------------------------
// File name:           eth_ctrl
// Created by:          正点原子
// Created date:        2025年10月22日13:38:00
// Version:             V1.1
// Descriptions:        以太网控制模块
//
//                      修改说明(V1.1):
//                      1、UDP 改为由 data_gen 定时主动上传，不再参与 FIFO 环回，
//                         因此去掉 udp_rec_data/udp_rec_en/udp_tx_req/udp_tx_data 四个端口；
//                      2、新增 udp_tx_ready 输出，告诉 data_gen "介质空闲, 可以发下一包"；
//                      3、ARP/ICMP 的请求改为挂起(pending)方式, 并且只在介质空闲时才启动发送,
//                         避免和周期性 UDP 数据包抢占 GMII 发送通道导致两个包都被破坏；
//                      4、ICMP 的发送启动信号 icmp_tx_start_en 改由本模块产生,
//                         保证一帧 ARP/ICMP 发送期间不会被 UDP 打断。
//----------------------------------------------------------------------------------------
//****************************************************************************************//

module eth_ctrl(
    input              clk              ,    //时钟
    input              rst_n            ,    //系统复位信号，低电平有效
    //ARP相关端口信号
    input              arp_rx_done      ,    //ARP接收完成信号
    input              arp_rx_type      ,    //ARP接收类型 0:请求  1:应答
    output reg         arp_tx_en        ,    //ARP发送使能信号
    output             arp_tx_type      ,    //ARP发送类型 0:请求  1:应答
    input              arp_tx_done      ,    //ARP发送完成信号
    input              arp_gmii_tx_en   ,    //ARP GMII输出数据有效信号
    input     [7:0]    arp_gmii_txd     ,    //ARP GMII输出数据
    //ICMP相关端口信号
    input              icmp_rec_pkt_done,    //ICMP单包数据接收完成信号
    output reg         icmp_tx_start_en ,    //ICMP开始发送信号
    input              icmp_tx_done     ,    //ICMP发送完成信号
    input              icmp_gmii_tx_en  ,    //ICMP GMII输出数据有效信号
    input     [7:0]    icmp_gmii_txd    ,    //ICMP GMII输出数据
    //ICMP fifo接口信号
    input              icmp_rec_en      ,    //ICMP接收的数据使能信号
    input     [7:0]    icmp_rec_data    ,    //ICMP接收的数据
    input              icmp_tx_req      ,    //ICMP读数据请求信号
    output    [7:0]    icmp_tx_data     ,    //ICMP待发送数据
    //UDP相关端口信号
    input              udp_tx_start_en  ,    //UDP开始发送信号
    input              udp_tx_done      ,    //UDP发送完成信号
    input              udp_gmii_tx_en   ,    //UDP GMII输出数据有效信号
    input     [7:0]    udp_gmii_txd     ,    //UDP GMII输出数据
    output             udp_tx_ready     ,    //UDP可以启动发送(介质空闲)
    //fifo接口信号
    input      [7:0]   tx_data          ,    //待发送的数据
    output             tx_req           ,    //读数据请求信号
    output reg         rec_en           ,    //接收的数据使能信号
    output reg [7:0]   rec_data         ,    //接收的数据
    //GMII发送引脚
    output reg         gmii_tx_en       ,    //GMII输出数据有效信号
    output reg [7:0]   gmii_txd              //GMII输出数据
    );

//reg define
reg [1:0]  protocol_sw;     //协议切换信号
reg        icmp_tx_busy;    //ICMP正在发送数据标志信号
reg        udp_tx_busy;     //UDP正在发送数据标志信号
reg        arp_busy;        //ARP正在发送数据标志信号
reg        arp_pending;     //有ARP请求等待应答
reg        icmp_pending;    //有ICMP请求等待应答
reg        icmp_tx_req_d0;  //ICMP读数据请求信号寄存器

//*****************************************************
//**                    main code
//*****************************************************

assign arp_tx_type  = 1'b1;                                     //ARP发送类型固定为ARP应答
assign tx_req       = icmp_tx_req;                               //读数据请求信号(只有ICMP回环用FIFO)
assign icmp_tx_data = icmp_tx_req_d0 ? tx_data : 8'd0;           //ICMP待发送数据选择

//介质空闲时才允许UDP启动下一包，保证ARP/ICMP有插入发送的机会
assign udp_tx_ready = (~arp_pending) & (~arp_busy) & (~icmp_pending) & (~icmp_tx_busy);

//ICMP读数据请求信号寄存一拍(补偿标准FIFO一个时钟的读出延时)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        icmp_tx_req_d0 <= 1'd0;
    else
        icmp_tx_req_d0 <= icmp_tx_req;
end

//接收数据使能信号与接收数据的判断(只有ICMP数据写入FIFO用于回环)
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rec_en    <= 1'd0;
        rec_data  <= 8'd0;
    end
    else if (icmp_rec_en) begin
        rec_en    <= icmp_rec_en;
        rec_data  <= icmp_rec_data;
    end
    else begin
        rec_en    <= 1'd0;
        rec_data  <= rec_data;
    end
end

//协议的切换
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        gmii_tx_en <= 1'd0;
        gmii_txd   <= 8'd0;
    end
    else begin
        case(protocol_sw)
            2'b00:  begin
                gmii_tx_en <= arp_gmii_tx_en;
                gmii_txd   <= arp_gmii_txd;
            end
            2'b01: begin
                gmii_tx_en <= udp_gmii_tx_en;
                gmii_txd   <= udp_gmii_txd;
            end
            2'b10: begin
                gmii_tx_en <= icmp_gmii_tx_en;
                gmii_txd   <= icmp_gmii_txd;
            end
            default:;
        endcase
    end
end

//控制ICMP发送忙信号
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        icmp_tx_busy <= 1'b0;
    else if(icmp_tx_start_en)
        icmp_tx_busy <= 1'b1;
    else if(icmp_tx_done)
        icmp_tx_busy <= 1'b0;
    else ;
end

//控制UDP发送忙信号
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        udp_tx_busy <= 1'b0;
    else if(udp_tx_start_en)
        udp_tx_busy <= 1'b1;
    else if(udp_tx_done)
        udp_tx_busy <= 1'b0;
    else ;
end

//控制ARP发送忙信号
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        arp_busy <= 1'b0;
    else if(arp_tx_en)
        arp_busy <= 1'b1;
    else if(arp_tx_done)
        arp_busy <= 1'b0;
    else ;
end

//ARP请求挂起标志：收到ARP请求后一直保持，直到真正发起ARP应答
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        arp_pending <= 1'b0;
    else if(arp_rx_done && (arp_rx_type == 1'b0))
        arp_pending <= 1'b1;
    else if(arp_tx_en)
        arp_pending <= 1'b0;
    else ;
end

//ICMP请求挂起标志：收到ping请求后一直保持，直到真正发起ICMP应答
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        icmp_pending <= 1'b0;
    else if(icmp_rec_pkt_done)
        icmp_pending <= 1'b1;
    else if(icmp_tx_start_en)
        icmp_pending <= 1'b0;
    else ;
end

//ARP发送使能：优先级最高，介质空闲时发起应答
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        arp_tx_en <= 1'b0;
    else if(arp_pending && (udp_tx_busy == 1'b0) && (icmp_tx_busy == 1'b0))
        arp_tx_en <= 1'b1;
    else
        arp_tx_en <= 1'b0;
end

//ICMP发送使能：优先级次之
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        icmp_tx_start_en <= 1'b0;
    else if(icmp_pending && (arp_pending == 1'b0) && (arp_busy == 1'b0) && (udp_tx_busy == 1'b0))
        icmp_tx_start_en <= 1'b1;
    else
        icmp_tx_start_en <= 1'b0;
end

//控制protocol_sw信号
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        protocol_sw <= 2'b00;
    else if(udp_tx_start_en)
        protocol_sw <= 2'b01;
    else if(icmp_tx_start_en)
        protocol_sw <= 2'b10;
    else if(arp_tx_en)
        protocol_sw <= 2'b00;
    else ;
end

endmodule
