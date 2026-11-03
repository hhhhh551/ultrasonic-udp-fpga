namespace UltrasoundHost;

/// <summary>
/// 【数据模型】一帧 A 扫波形的完整描述。
///
/// 这是整个程序里唯一"认识超声波"的地方 ——
/// 它知道 0.46mm 的采样间距,知道低 9 位有效,
/// 知道怎么找峰值。所有物理含义都集中在这一个类里。
///
/// 换个传感器、改个采样间距,只改这个文件的常量即可。
/// </summary>
public sealed class AScanFrame
{
    // ═══════════════════════════════════════════════════
    //  物理常量 —— 全部来自你的需求描述
    // ═══════════════════════════════════════════════════

    /// <summary>一帧有多少个采样点。FPGA 每次采 512 个。</summary>
    public const int PointCount = 512;

    /// <summary>
    /// 相邻两个采样点之间的实际距离,单位毫米。
    ///
    ///     间距 = 声速 × 每点采样时间 ÷ 2
    /// 除以 2 是因为超声波走的是"去 + 回"双程,走过的路程是深度的两倍。
    ///
    /// 本系统实测参数:
    ///     钢材纵波声速 5900 m/s,ADC 50MHz 采样,8:1 抽取
    ///     每点时间 = 8 × 20ns = 160ns
    ///     间距 = 5900 × 160e-9 ÷ 2 = 0.000472 m = 0.472 mm
    ///
    /// ⚠️ 注意:这里原来是 0.46,是按"水中声速 1480 m/s"算的。
    ///    你探的是钢铁试块,纵波 5900 m/s,必须用 0.472,否则深度全错。
    ///    如果换成横波(3230 m/s),则应为 0.2584 mm。
    /// </summary>
    public const double MmPerPoint = 0.472;

    /// <summary>
    /// FPGA 发来的 16 位数据 = 包络幅值(单位 ADC LSB) × 64。
    ///
    ///     原始值 12160  →  包络幅值 = 12160 >> 6 = 190 LSB
    ///
    /// 低 6 位恒为 0,是 FPGA 故意留出来的 6 位小数 ——
    /// 以后做多帧平均、平滑滤波时,这 6 位能保证不丢精度。
    ///
    /// ⚠️ 千万不能再用 &amp; 0x01FF 去"取低 9 位"了。
    ///    那样每加 1,截出来的值就会在 0~511 之间来回跳,波形会全是毛刺。
    ///    正确的做法就是右移 6 位。
    /// </summary>
    public const int ValueShift = 6;

    /// <summary>原始值 → 幅值 的比例 = 64。</summary>
    public const int ValueScale = 1 << ValueShift;   // 64

    /// <summary>幅值满量程。65535 >> 6 = 1023。</summary>
    public const int MaxAmplitude = 65535 >> ValueShift;

    // ═══════════════════════════════════════════════════
    //  这一帧的数据
    // ═══════════════════════════════════════════════════

    /// <summary>
    /// 帧序号。FPGA 每发一包就加 1,用于在上位机这边判断有没有丢包。
    /// 是 16 位的,所以到 65535 之后会回绕到 0。
    /// </summary>
    public ushort Sequence { get; init; }

    /// <summary>512 个原始 16 位值,未做任何处理。</summary>
    public ushort[] Raw { get; init; } = Array.Empty<ushort>();

    /// <summary>接收到这一帧的时刻。</summary>
    public DateTime ReceivedAt { get; init; } = DateTime.Now;

    // ═══════════════════════════════════════════════════
    //  物理量换算
    // ═══════════════════════════════════════════════════

    /// <summary>
    /// 取出第 index 个点的有效幅值(0 ~ 511)。
    /// 这就是"低 9 位有效"的落地方式:一个按位与搞定。
    /// </summary>
    public int AmplitudeAt(int index) => Raw[index] >> ValueShift;

    /// <summary>第 index 个点对应的深度,单位毫米。这就是波形图的横坐标。</summary>
    public static double IndexToMm(int index) => index * MmPerPoint;

    /// <summary>深度(毫米)反算成点序号。界面上鼠标点一下要用到。</summary>
    public static int MmToIndex(double mm) => (int)Math.Round(mm / MmPerPoint);

    /// <summary>这一帧能探测到的最大深度。511 × 0.46 = 235.06 mm。</summary>
    public static double MaxDepthMm => (PointCount - 1) * MmPerPoint;

    /// <summary>
    /// 在整帧里找出幅值最大的那个点。
    ///
    /// startIndex 参数用来"跳过前面的表面回波":
    /// 超声波探头贴在工件表面时,最先收到的那个回波永远是满幅的起始波,
    /// 它会把真正的缺陷回波淹没。所以实际分析时通常从第 20~30 个点之后开始找。
    /// </summary>
    public PeakInfo FindPeak(int startIndex = 0)
    {
        if (Raw.Length == 0)
        {
            return new PeakInfo(0, 0);
        }

        int bestIndex = Math.Max(0, startIndex);
        int bestValue = -1;

        for (int i = bestIndex; i < Raw.Length; i++)
        {
            int value = AmplitudeAt(i);
            if (value > bestValue)
            {
                bestValue = value;
                bestIndex = i;
            }
        }

        return new PeakInfo(bestIndex, Math.Max(bestValue, 0));
    }

    /// <summary>
    /// 判断这一帧是不是"测试斜坡信号"(0,1,2,3,...,511 依次递增)。
    ///
    /// 为什么需要这个方法?
    /// 你的 FPGA 目前 data_gen 里发的正是这个自增序列,它是用来验证链路通不通的。
    /// 上位机识别到它,就能明确告诉你"链路完全正常,512 个点一个不差",
    /// 而不会让你对着一条莫名其妙的斜线发呆。
    /// </summary>
    /// <summary>
    /// 【回波检测】一帧里往往有多个回波(表面、缺陷、底面、多次反射),
    /// 只报一个最高值会把缺陷埋掉。这里把所有明显的回波都找出来。
    ///
    /// thresholdRatio : 门限 = 本帧最大值 × 该比例, 低于它的当噪声丢掉
    /// minSeparationMm: 两个回波间隔小于这个距离就合并(一个回波包通常宽 5~10mm)
    /// 返回按【深度从小到大】排好序的回波列表。
    /// </summary>
    public List<PeakInfo> FindPeaks(
        int maxCount = 8,
        int startIndex = 0,
        double thresholdRatio = 0.20,
        double minSeparationMm = 5.0)
    {
        var result = new List<PeakInfo>();
        int n = Raw.Length;

        if (n < 3)
        {
            return result;
        }

        int from = Math.Max(1, startIndex);

        // 1. 先找本帧最大值, 用来定门限
        int frameMax = 0;
        for (int i = from; i < n; i++)
        {
            int v = AmplitudeAt(i);
            if (v > frameMax)
            {
                frameMax = v;
            }
        }

        if (frameMax <= 0)
        {
            return result;
        }

        int threshold = (int)(frameMax * thresholdRatio);
        if (threshold < 1)
        {
            threshold = 1;
        }

        int minSep = Math.Max(1, MmToIndex(minSeparationMm));

        // 2. 找所有局部极大值
        var candidates = new List<PeakInfo>();
        for (int i = from; i < n - 1; i++)
        {
            int v = AmplitudeAt(i);

            if (v < threshold)
            {
                continue;
            }

            // 必须同时不低于左右邻居(平台顶也认, 避免放过宽回波)
            if (v < AmplitudeAt(i - 1) || v < AmplitudeAt(i + 1))
            {
                continue;
            }

            candidates.Add(new PeakInfo(i, v));
        }

        if (candidates.Count == 0)
        {
            return result;
        }

        // 3. 按幅值从大到小挑, 保证彼此间距够
        candidates.Sort((a, b) => b.Amplitude.CompareTo(a.Amplitude));

        var chosen = new List<PeakInfo>();
        foreach (PeakInfo cand in candidates)
        {
            bool tooClose = false;

            foreach (PeakInfo kept in chosen)
            {
                if (Math.Abs(cand.Index - kept.Index) < minSep)
                {
                    tooClose = true;
                    break;
                }
            }

            if (!tooClose)
            {
                chosen.Add(cand);

                if (chosen.Count >= maxCount)
                {
                    break;
                }
            }
        }

        // 4. 输出前按深度排序, 这样界面上是从左到右
        chosen.Sort((a, b) => a.Index.CompareTo(b.Index));
        return chosen;
    }
    public bool LooksLikeRamp()
    {
        if (Raw.Length != PointCount)
        {
            return false;
        }

        for (int i = 0; i < Raw.Length; i++)
        {
            if ((Raw[i] >> ValueShift) != i)
            {
                return false;
            }
        }

        return true;
    }

    public override string ToString() =>
        $"序号={Sequence} 点数={Raw.Length} 接收于={ReceivedAt:HH:mm:ss.fff}";
}

/// <summary>
/// 峰值查找的结果。
/// 用 record struct 是 C# 里的语法糖:一行就替代了"定义类 + 写构造函数 + 写属性"。
/// readonly 表示它一旦创建就不可修改,比较安全,也更省内存。
/// </summary>
public readonly record struct PeakInfo(int Index, int Amplitude)
{
    /// <summary>峰值出现在哪个深度(毫米)。这是超声波检测最关心的指标。</summary>
    public double DepthMm => AScanFrame.IndexToMm(Index);
}
