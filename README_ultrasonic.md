# ultrasonic_udp —— 超声检测工程（激励 + 50MHz ADC 采集 + 滤波/包络检波 + UDP 上传）

> Vivado 2018.3 · xc7a100tfgg484-2 · 顶层 `ultrasonic_udp`
> bit：`ultrasonic_udp.runs\impl_1\ultrasonic_udp.bit`

---

## 一、系统结构

```
sys_clk 50MHz ─┬─ pulse_gen ──► pulse_n (E16) ──► 高压激励打探头
               │       └── trig（单周期，与脉冲同时）
               │
               ├─ ad_clk = ~sys_clk ──► AB11 ──► 10bit ADC
               │   ad_data[9:0] ◄── Y16/AA16/AB16/AB17/AA15/AB15/Y13/AA14/AA13/AB13
               │
               ├─ dsp_chain（50MHz 采样域）
               │    带通FIR 0.8~4.5MHz  →  |x| 全波整流  →  包络低通FIR 1.5MHz
               │    →  8:1 抽取  →  512 点 × 16bit
               │
               ├─ frame_ram 乒乓双缓冲（写 50MHz / 读 125MHz）
               │
               └─ eth_udp_tx ── 每帧一包 UDP，1024 字节 ──► 电脑
                       └── 1000M RGMII + ARP + ICMP(ping)
```

## 二、关键参数与换算

| 项目 | 值 |
|------|-----|
| ADC 采样率 | **50 MHz**（20ns） |
| 抽取比 | **8**（每 8 个采样取 1 个包络点） |
| 每帧点数 | **512** 点 |
| 每点位数 | **16 bit**（2 字节，大端） |
| UDP 载荷 | **1030 字节/包**（6 字节包头 + 512×2 数据） |
| 每点时间 | 8 × 20ns = **160 ns** |
| 整帧时长 | 512 × 160ns = **81.92 µs** |
| 深度（钢铁纵波 5900 m/s） | **24.2 cm**，每点 **0.472 mm** |
| 帧率 | 18 ms/帧 ≈ **55 帧/秒** |
| 带宽 | 约 0.45 Mbps |

### 数据格式（PC 端解析）

```
偏移 0    : 0xAA                     帧头
偏移 1    : 0x55
偏移 2..3 : 帧序号(16bit 大端)        每包 +1，可用来判丢包
偏移 4..5 : 点数 = 512(16bit 大端)
偏移 6..  : 1024 字节 = 512 个 16bit 包络点(大端)

第 k 点（k = 0..511）:
    b      = payload[6 + 2k] , payload[7 + 2k]
    value  = (b[0] << 8) | b[1]
    env_lsb = value / 64.0        // 换算回 ADC LSB 单位的包络幅值
    depth_mm = k * 0.472          // 该点对应的深度
```

> **⚠️ 上位机最容易踩的坑**：`value` 的低 6 位恒为 0（FPGA 故意留的 6 位小数），
> **不能**用 `& 0x1FF` 之类的掩码去截位，必须右移 6 位。否则每加 1，
> 截出来的值就在 0~511 之间乱跳，波形会全是毛刺。

包络输出是 **64 × ADC LSB**：探头回波幅度 ±300 LSB 时，`value ≈ 12160`。
满量程（±512 LSB）时 `value ≈ 21000`，内部有饱和保护（`0xFFFF`）。

### 直流偏置

**不用标定。** 实测 0V 采样 502（不是 512），这个直流分量被带通滤波器直接滤掉了 ——
仿真验证：纯直流 502 输入时，带通输出稳态值为 **0 LSB**。

## 三、网络与使用方法

| 项目 | 值 |
|------|-----|
| 板子 MAC / IP | `00-11-22-33-44-55` / `192.168.1.10` |
| 目的 MAC | 默认广播 `ff-ff-ff-ff-ff-ff` |
| 目的 IP | `192.168.0.145`（参数 `DES_IP_DEFAULT`） |
| 端口 | 源 = 目的 = **1234** |

1. 电脑网卡设成 `192.168.0.x`（当前是 `192.168.0.145`），**这个 IP 必须和 `DES_IP_DEFAULT` 一致**
2. 下载 `ultrasonic_udp.bit`
3. Wireshark 过滤 `udp.port == 1234`，应每 18ms 一包，帧长 1078 字节
4. 写接收程序：绑 `0.0.0.0:1234`，缓冲区 2048

> 板子 IP 是 `192.168.1.10`，和电脑不在同一网段，所以 **ping 不通是正常的**。
> 上传走的是广播 MAC，不依赖 ping。想把 ping 弄通就把 `BOARD_IP` 改成 `192.168.0.x`。

PC 端 Python 示例：

```python
import socket, numpy as np
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', 1234))
while True:
    pkt, _ = s.recvfrom(2048)
    if len(pkt) < 1024:
        continue
    v = np.frombuffer(pkt[:1024], dtype='>u2') / 64.0   # 大端 16bit
    depth = np.arange(512) * 0.472                      # mm
    # 画 depth-v 就是 A 扫波形
```

## 四、调试指示灯（V9/Y8/Y7/W7，只看闪不闪）

| 灯 | 含义 |
|----|------|
| led[0] | 以太网 RXC 心跳 —— **闪 = 网口链路正常**（不闪 = 网线/网口/PHY 问题，整个设计不跑） |
| led[1] | sys_clk 心跳（MMCM 锁定后）—— 闪 = FPGA 已配置 |
| led[2] | 每 256 包 UDP 发完翻转 —— **闪 = UDP 在发** |
| led[3] | 每 256 帧采集完翻转（约 4.6 s 一次）—— **闪 = 采集在跑** |

## 五、资源与时序

| 资源 | 用量 | 占比 |
|------|------|------|
| DSP48 | **77** / 240 | 32% |
| LUT | 4797 / 63400 | 7.6% |
| FF | 6990 / 126800 | 5.5% |
| BRAM | 1 / 135 | 0.7% |
| IOB | 32 / 285 | 11% |

**WNS = +1.868 ns**，`All user specified timing constraints are met.`

## 六、仿真验证（`tb_dsp_chain`）

注入 2.5MHz / 300 LSB 高斯包络回波，直流偏置 502：

```
写入包络点数        = 512  (期望 512)
包络峰值            = 12160  @ 第 113 点
期望峰值点号        = 112
峰值点误差          = 1 点 = 8 个采样 = 160 ns   (≈0.47 mm)
包络幅值(期望~12224) = 12160
包络最小值          = 0
================ TEST PASS ================
```

实测整条链路延时 **92 个采样点 = 1.84 µs**，已作为 `LATENCY` 参数补偿，
点 0 严格对齐激励脉冲时刻。

## 七、想改什么改哪里

| 需求 | 位置 |
|------|------|
| 激励周期 / 脉宽 | `ultrasonic_udp.v` 的 `PERIOD_NS` / `PULSE_WIDTH_NS` |
| 目的 IP / MAC / 板子 IP | `ultrasonic_udp.v` 的 `DES_IP_DEFAULT` / `DES_MAC_DEFAULT` / `BOARD_IP` |
| 抽取比 / 点数 | `ultrasonic_udp.v` 里 `dsp_chain` 例化的 `DECIM` / `POINTS` |
| 链路延时补偿 | 同上 `LATENCY`（改滤波器后要重新仿真标定） |
| 滤波器指标 | 改 `design_filters.py` 里的 `NB/NL/F1/F2/FC_ENV`，跑一遍重新生成 `fir_coef.vh` |
| 包络增益 | `dsp_chain` 的 `ENV_GAIN_SHIFT`（默认 6 = ×64） |

> 改完滤波器系数后：`python design_filters.py` 会重新生成 `rtl/fir_coef.vh`，
> 然后要重新跑 `tb_dsp_chain` 标定 `LATENCY`（延时 = 两个滤波器的抽头数一半之和 + 流水线级数）。

## 八、文件清单

```
ultrasonic_udp.srcs/sources_1/rtl/
    ultrasonic_udp.v      顶层：合并激励/ADC/DSP/以太网，乒乓缓冲控制
    pulse_gen.v           18ms 周期 / 200ns 激励脉冲 + trig
    dsp_chain.v           带通 → 整流 → 包络 → 8:1 抽取 → 512×16bit
    fir_sym.v             通用对称线性相位 FIR（先加后乘，乘法器减半）
    fir_coef.vh           自动生成的 18bit Q1.17 系数（带通 63tap / 包络 95tap）
    frame_ram.v           乒乓双缓冲（50MHz 写 / 125MHz 读）
    frame_src.v           UDP 数据源（512 点 × 2 字节大端）
    eth_udp_tx.v          以太网：RGMII + ARP + ICMP + UDP 发送
    eth_ctrl.v            发送仲裁（ARP > ICMP > UDP）
    arp/ icmp/ udp/ gmii_to_rgmii/   正点原子原例程
    ultrasonic_udp.xdc    引脚约束（以太网 14 + ADC 12 + 激励 1 + LED 4）
build_ultrasonic.tcl      一键重建脚本
design_filters.py         滤波器设计与定点仿真脚本（numpy）
sim/tb_dsp_chain.v        DSP 链路测试台
```

## 九、已知限制 / 后续可做

1. **激励后 0 延时采集**：高压脉冲的余振会把前几个点打饱和（这是按你要求做的）。
   想避开就把 `dsp_chain` 的采集起点加个盲区延时。
2. **ADC 与激励的模拟通路**建议加限幅/保护，否则发射余振可能超过 ±5V 量程。
3. 当前是**单次回波 A 扫**，还没做多帧平均降噪 —— 需要的话可以在 `frame_ram` 前面加个累加器。
4. 探头的**前沿时刻**（表面回波）可以用来做自动测厚/测距，需要的话再加个峰值检测。
