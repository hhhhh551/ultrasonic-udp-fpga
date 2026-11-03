"""
超声检测 FIR 滤波器设计与定点仿真
  fs = 50 MHz
  级1 带通 : 0.8 ~ 4.5 MHz   (去掉 502 的直流偏置 + 抑制带外噪声)
  级2 包络 : 全波整流后 1.5 MHz 低通
输出: Verilog 系数函数文件 + 定点仿真验证
"""
import numpy as np

FS = 50e6            # 采样率
COEF_BITS = 18       # 系数位宽 (Q1.17)
COEF_SCALE = (1 << (COEF_BITS - 1))   # 131072

def sinc(x):
    return np.where(np.abs(x) < 1e-12, 1.0, np.sin(np.pi * x) / (np.pi * x))

def lp_design(n, fc, fs, win="hamming"):
    """加窗 sinc 低通, 返回长度 n(奇数)的系数, 直流增益 1"""
    m = n - 1
    k = np.arange(n)
    w = np.hamming(n) if win == "hamming" else np.kaiser(n, 8.0) if win == "kaiser" else np.ones(n)
    h = 2 * fc / fs * sinc(2 * fc / fs * (k - m / 2)) * w
    h = h / h.sum()
    return h

def bp_design(n, f1, f2, fs, win="hamming"):
    """带通 = LP(f2) - LP(f1)"""
    h = lp_design(n, f2, fs, win) - lp_design(n, f1, fs, win)
    return h

def resp(h, fs, freqs):
    """计算频响幅度(dB)"""
    w = 2 * np.pi * np.array(freqs) / fs
    n = np.arange(len(h))
    H = np.array([np.sum(h * np.exp(-1j * wi * n)) for wi in w])
    return 20 * np.log10(np.abs(H) + 1e-12)

def quantize(h):
    """量化成 18bit 定点, 并做直流增益修正"""
    hi = np.round(h * COEF_SCALE).astype(int)
    hi = np.clip(hi, -(1 << (COEF_BITS - 1)), (1 << (COEF_BITS - 1)) - 1)
    return hi

def verilog_signed(v, bits=COEF_BITS):
    """Verilog 有符号常量字面量: 负数必须写成 -18'sd123 而不是 18'sd-123"""
    if v < 0:
        return "-%d'sd%d" % (bits, -v)
    return "%d'sd%d" % (bits, v)

def to_verilog_fn(name, h_int, comment):
    """生成 Verilog function 形式的系数表"""
    n = len(h_int)
    out = []
    out.append("// %s" % comment)
    out.append("// taps = %d , 系数为 Q1.17 定点 (实际值 = coef / 131072)" % n)
    out.append("function signed [%d:0] %s;" % (COEF_BITS - 1, name))
    out.append("    input integer i;")
    out.append("    begin")
    out.append("        case(i)")
    for i, v in enumerate(h_int):
        out.append("            %3d: %s = %s;" % (i, name, verilog_signed(int(v))))
    out.append("            default: %s = %d'sd0;" % (name, COEF_BITS))
    out.append("        endcase")
    out.append("    end")
    out.append("endfunction")
    return "\n".join(out)

# ---------------------------------------------------------------- 设计
NB = 63      # 带通窗口长度(奇数, 对称 -> 32 个乘法器)
NL = 95      # 包络低通长度(奇数, 对称 -> 48 个乘法器)
F1, F2 = 0.8e6, 4.5e6
FC_ENV = 1.5e6

hb = bp_design(NB, F1, F2, FS)
hl = lp_design(NL, FC_ENV, FS)

probe = [0, 0.2e6, 0.5e6, 0.8e6, 1.0e6, 1.5e6, 2.0e6, 2.5e6, 3.0e6, 4.0e6, 4.5e6, 6e6, 10e6, 20e6]
print("带通 %d tap  频响:" % NB)
for f, g in zip(probe, resp(hb, FS, probe)):
    print("   %6.2f MHz : %7.2f dB" % (f / 1e6, g))
print("   直流增益(系数和) = %.6f" % hb.sum())

print("\n包络低通 %d tap 频响:" % NL)
for f, g in zip([0, 0.5e6, 1.0e6, 1.5e6, 2.0e6, 3.0e6, 4.0e6, 5e6, 6e6, 10e6], resp(hl, FS, [0, 0.5e6, 1.0e6, 1.5e6, 2.0e6, 3.0e6, 4.0e6, 5e6, 6e6, 10e6])):
    print("   %6.2f MHz : %7.2f dB" % (f / 1e6, g))
print("   直流增益(系数和) = %.6f" % hl.sum())

hb_i = quantize(hb)
hl_i = quantize(hl)
print("\n带通量化后系数和 = %.6f (应为 ~0, 即直流被抑制)" % (hb_i.sum() / COEF_SCALE))
print("低通量化后直流增益 = %.6f (应为 ~1)" % (hl_i.sum() / COEF_SCALE))
print("带通系数最大绝对值 = %d , 低通 = %d" % (np.abs(hb_i).max(), np.abs(hl_i).max()))

# ---------------------------------------------------------------- 定点仿真
def fir_fixed(x, h_int, bits=COEF_BITS):
    """定点 FIR (与 RTL 一致: 累加后 >> (bits-1) 四舍五入)"""
    n = len(h_int)
    acc = np.convolve(x.astype(np.int64), h_int.astype(np.int64))
    # 与流水线一致, 输出取整
    out = (acc + (1 << (bits - 2))) >> (bits - 1)
    return out[:len(x)]

def simulate(freq, amp, dc=502, n=4096 + 512, noise=2.0, seed=1):
    rng = np.random.default_rng(seed)
    t = np.arange(n) / FS
    # 探头脉冲: 高斯包络 x 正弦, 中心 4us 处
    t0 = 4e-6
    tau = 1.2e-6
    env = np.exp(-((t - t0) ** 2) / (2 * tau ** 2))
    sig = amp * env * np.sin(2 * np.pi * freq * (t - t0))
    x = np.clip(np.round(512 + dc - 512 + sig + rng.normal(0, noise, n)), 0, 1023).astype(np.int64)

    y1 = fir_fixed(x, hb_i)          # 带通
    y2 = np.abs(y1)                   # 全波整流
    y3 = fir_fixed(y2, hl_i)          # 包络低通
    return x, y1, y2, y3

for f in [1.5e6, 2.0e6, 2.5e6, 3.0e6]:
    x, y1, y2, y3 = simulate(f, amp=300)
    # 找包络峰位置
    seg = y3[600:]                    # 跳过流水线暂态
    k = np.argmax(seg) + 600
    print("\n%4.1f MHz : 包络峰值 = %6d (输入幅度 300 LSB), 峰值位置 = %.3f us"
          % (f / 1e6, y3[k], k / FS * 1e6))
    # 检查直流残留
    print("            带通输出直流残留(前 0.5us 均值) = %.1f LSB" % np.mean(y1[10:35]))

# 直流抑制检查: 纯直流输入
x = np.full(4096, 502, dtype=np.int64)
y1 = fir_fixed(x, hb_i)
print("\n纯直流(502) 输入 -> 带通输出稳态值 = %.1f LSB (越接近0越好)" % np.mean(y1[2000:4000]))

# ---------------------------------------------------------------- 输出文件
hdr = """//****************************************************************************************//
// fir_coef.vh  ---  自动生成, 请勿手工修改
// 生成脚本: design_filters.py
//   fs = 50 MHz
//   级1 带通 BPF : %d tap, %.2f ~ %.2f MHz, Hamming 窗, 线性相位
//   级2 包络 LPF : %d tap, 截止 %.2f MHz, Hamming 窗, 线性相位
//   系数格式: 18bit 有符号 Q1.17 (实际值 = coef / 131072)
//****************************************************************************************//
""" % (NB, F1 / 1e6, F2 / 1e6, NL, FC_ENV / 1e6)

with open("rtl/fir_coef.vh", "w", encoding="utf-8") as fh:
    fh.write(hdr)
    fh.write(to_verilog_fn("bpf_coef", hb_i,
             "超声带通 FIR 系数 (0.8~4.5MHz)") + "\n\n")
    fh.write(to_verilog_fn("env_coef", hl_i,
             "包络低通 FIR 系数 (1.5MHz)") + "\n")

print("\n已生成 fir_coef.vh")
