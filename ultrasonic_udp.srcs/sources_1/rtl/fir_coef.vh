//****************************************************************************************//
// fir_coef.vh  ---  自动生成, 请勿手工修改
// 生成脚本: design_filters.py
//   fs = 50 MHz
//   级1 带通 BPF : 63 tap, 0.80 ~ 4.50 MHz, Hamming 窗, 线性相位
//   级2 包络 LPF : 95 tap, 截止 1.50 MHz, Hamming 窗, 线性相位
//   系数格式: 18bit 有符号 Q1.17 (实际值 = coef / 131072)
//****************************************************************************************//
// 超声带通 FIR 系数 (0.8~4.5MHz)
// taps = 63 , 系数为 Q1.17 定点 (实际值 = coef / 131072)
function signed [17:0] bpf_coef;
    input integer i;
    begin
        case(i)
              0: bpf_coef = -18'sd108;
              1: bpf_coef = -18'sd126;
              2: bpf_coef = -18'sd116;
              3: bpf_coef = -18'sd76;
              4: bpf_coef = -18'sd12;
              5: bpf_coef = 18'sd54;
              6: bpf_coef = 18'sd82;
              7: bpf_coef = 18'sd18;
              8: bpf_coef = -18'sd183;
              9: bpf_coef = -18'sd529;
             10: bpf_coef = -18'sd977;
             11: bpf_coef = -18'sd1428;
             12: bpf_coef = -18'sd1746;
             13: bpf_coef = -18'sd1813;
             14: bpf_coef = -18'sd1577;
             15: bpf_coef = -18'sd1105;
             16: bpf_coef = -18'sd591;
             17: bpf_coef = -18'sd317;
             18: bpf_coef = -18'sd570;
             19: bpf_coef = -18'sd1531;
             20: bpf_coef = -18'sd3172;
             21: bpf_coef = -18'sd5206;
             22: bpf_coef = -18'sd7108;
             23: bpf_coef = -18'sd8225;
             24: bpf_coef = -18'sd7946;
             25: bpf_coef = -18'sd5894;
             26: bpf_coef = -18'sd2073;
             27: bpf_coef = 18'sd3072;
             28: bpf_coef = 18'sd8713;
             29: bpf_coef = 18'sd13812;
             30: bpf_coef = 18'sd17362;
             31: bpf_coef = 18'sd18634;
             32: bpf_coef = 18'sd17362;
             33: bpf_coef = 18'sd13812;
             34: bpf_coef = 18'sd8713;
             35: bpf_coef = 18'sd3072;
             36: bpf_coef = -18'sd2073;
             37: bpf_coef = -18'sd5894;
             38: bpf_coef = -18'sd7946;
             39: bpf_coef = -18'sd8225;
             40: bpf_coef = -18'sd7108;
             41: bpf_coef = -18'sd5206;
             42: bpf_coef = -18'sd3172;
             43: bpf_coef = -18'sd1531;
             44: bpf_coef = -18'sd570;
             45: bpf_coef = -18'sd317;
             46: bpf_coef = -18'sd591;
             47: bpf_coef = -18'sd1105;
             48: bpf_coef = -18'sd1577;
             49: bpf_coef = -18'sd1813;
             50: bpf_coef = -18'sd1746;
             51: bpf_coef = -18'sd1428;
             52: bpf_coef = -18'sd977;
             53: bpf_coef = -18'sd529;
             54: bpf_coef = -18'sd183;
             55: bpf_coef = 18'sd18;
             56: bpf_coef = 18'sd82;
             57: bpf_coef = 18'sd54;
             58: bpf_coef = -18'sd12;
             59: bpf_coef = -18'sd76;
             60: bpf_coef = -18'sd116;
             61: bpf_coef = -18'sd126;
             62: bpf_coef = -18'sd108;
            default: bpf_coef = 18'sd0;
        endcase
    end
endfunction

// 包络低通 FIR 系数 (1.5MHz)
// taps = 95 , 系数为 Q1.17 定点 (实际值 = coef / 131072)
function signed [17:0] env_coef;
    input integer i;
    begin
        case(i)
              0: env_coef = 18'sd38;
              1: env_coef = 18'sd50;
              2: env_coef = 18'sd63;
              3: env_coef = 18'sd76;
              4: env_coef = 18'sd90;
              5: env_coef = 18'sd104;
              6: env_coef = 18'sd117;
              7: env_coef = 18'sd128;
              8: env_coef = 18'sd135;
              9: env_coef = 18'sd136;
             10: env_coef = 18'sd128;
             11: env_coef = 18'sd111;
             12: env_coef = 18'sd81;
             13: env_coef = 18'sd37;
             14: env_coef = -18'sd21;
             15: env_coef = -18'sd95;
             16: env_coef = -18'sd182;
             17: env_coef = -18'sd283;
             18: env_coef = -18'sd392;
             19: env_coef = -18'sd507;
             20: env_coef = -18'sd621;
             21: env_coef = -18'sd729;
             22: env_coef = -18'sd823;
             23: env_coef = -18'sd894;
             24: env_coef = -18'sd935;
             25: env_coef = -18'sd937;
             26: env_coef = -18'sd891;
             27: env_coef = -18'sd791;
             28: env_coef = -18'sd631;
             29: env_coef = -18'sd406;
             30: env_coef = -18'sd113;
             31: env_coef = 18'sd248;
             32: env_coef = 18'sd676;
             33: env_coef = 18'sd1165;
             34: env_coef = 18'sd1709;
             35: env_coef = 18'sd2299;
             36: env_coef = 18'sd2923;
             37: env_coef = 18'sd3568;
             38: env_coef = 18'sd4219;
             39: env_coef = 18'sd4861;
             40: env_coef = 18'sd5477;
             41: env_coef = 18'sd6050;
             42: env_coef = 18'sd6566;
             43: env_coef = 18'sd7010;
             44: env_coef = 18'sd7369;
             45: env_coef = 18'sd7633;
             46: env_coef = 18'sd7794;
             47: env_coef = 18'sd7849;
             48: env_coef = 18'sd7794;
             49: env_coef = 18'sd7633;
             50: env_coef = 18'sd7369;
             51: env_coef = 18'sd7010;
             52: env_coef = 18'sd6566;
             53: env_coef = 18'sd6050;
             54: env_coef = 18'sd5477;
             55: env_coef = 18'sd4861;
             56: env_coef = 18'sd4219;
             57: env_coef = 18'sd3568;
             58: env_coef = 18'sd2923;
             59: env_coef = 18'sd2299;
             60: env_coef = 18'sd1709;
             61: env_coef = 18'sd1165;
             62: env_coef = 18'sd676;
             63: env_coef = 18'sd248;
             64: env_coef = -18'sd113;
             65: env_coef = -18'sd406;
             66: env_coef = -18'sd631;
             67: env_coef = -18'sd791;
             68: env_coef = -18'sd891;
             69: env_coef = -18'sd937;
             70: env_coef = -18'sd935;
             71: env_coef = -18'sd894;
             72: env_coef = -18'sd823;
             73: env_coef = -18'sd729;
             74: env_coef = -18'sd621;
             75: env_coef = -18'sd507;
             76: env_coef = -18'sd392;
             77: env_coef = -18'sd283;
             78: env_coef = -18'sd182;
             79: env_coef = -18'sd95;
             80: env_coef = -18'sd21;
             81: env_coef = 18'sd37;
             82: env_coef = 18'sd81;
             83: env_coef = 18'sd111;
             84: env_coef = 18'sd128;
             85: env_coef = 18'sd136;
             86: env_coef = 18'sd135;
             87: env_coef = 18'sd128;
             88: env_coef = 18'sd117;
             89: env_coef = 18'sd104;
             90: env_coef = 18'sd90;
             91: env_coef = 18'sd76;
             92: env_coef = 18'sd63;
             93: env_coef = 18'sd50;
             94: env_coef = 18'sd38;
            default: env_coef = 18'sd0;
        endcase
    end
endfunction
