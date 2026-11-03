namespace UltrasoundHost;

/// <summary>解析结果。用枚举而不是 bool,是为了让界面能告诉你"具体错在哪"。</summary>
public enum AScanParseResult
{
    /// <summary>解析成功。</summary>
    Ok,

    /// <summary>包太短,连 512 个点都装不下。</summary>
    TooShort,

    /// <summary>长度不是预期的两种之一,通常是把别的程序的 UDP 包也收进来了。</summary>
    UnexpectedLength,

    /// <summary>带包头模式下,开头的 0xAA 0x55 对不上。</summary>
    BadHeader,

    /// <summary>带包头模式下,包里的点数不是 512。</summary>
    BadPointCount
}

/// <summary>
/// 【协议层】把 FPGA 发来的 UDP 载荷翻译成 AScanFrame。
///
/// ══════════════════════════════════════════════════════════
///  你的 FPGA 实际发出的格式(从 udp_tx.v / data_gen.v 得到)
/// ══════════════════════════════════════════════════════════
///
/// UDP 载荷 = 1024 字节,里面就是 512 个 16 位采样值,连续排列:
///
///     字节偏移   0    1    2    3    4    5   ...  1022 1023
///               ┌────┬────┬────┬────┬────┬────┬───┬────┬────┐
///               │点0H│点0L│点1H│点1L│点2H│点2L│...│点511H│点511L│
///               └────┴────┴────┴────┴────┴────┴───┴────┴────┘
///
/// 每个点都是"高字节先发"(大端序)。
/// 这是 udp_tx.v 里这段代码决定的:
///     tx_bit_sel == 0 → gmii_txd <= tx_data[31:24]   ← 高字节先出去
///     tx_bit_sel == 1 → gmii_txd <= tx_data[23:16]
///     tx_bit_sel == 2 → gmii_txd <= tx_data[15:8]
///     tx_bit_sel == 3 → gmii_txd <= tx_data[7:0]
///
/// 注意:你的包里没有自定义帧头,前面只有标准的以太网头/IP头/UDP头,
/// 那些头在被系统交给你的 UdpClient 之前就已经剥掉了,所以你拿到的
/// 就是这纯纯的 1024 字节。
///
/// ══════════════════════════════════════════════════════════
///  同时也兼容"带包头"格式(为了方便你以后改造 FPGA)
/// ══════════════════════════════════════════════════════════
/// 如果以后你在 FPGA 里加了帧头和序号,变成 1030 字节:
///     偏移 0    : 0xAA
///     偏移 1    : 0x55
///     偏移 2~3  : 帧序号(大端)
///     偏移 4~5  : 点数 = 512(大端)
///     偏移 6~   : 1024 字节数据
/// 上位机这边会自动识别 —— 你不改上位机,它也能继续用。
/// </summary>
public static class AScanProtocol
{
    /// <summary>一帧的点数。</summary>
    public const int PointCount = 512;

    /// <summary>纯数据部分的字节数 = 512 × 2 = 1024。这就是你 FPGA 现在发的长度。</summary>
    public const int PayloadBytes = PointCount * 2;

    /// <summary>带包头格式的帧头。</summary>
    public const byte FrameHead0 = 0xAA;
    public const byte FrameHead1 = 0x55;

    /// <summary>可选包头长度(帧头2 + 序号2 + 点数2)。</summary>
    public const int HeaderBytes = 6;

    /// <summary>带包头时的总长度 = 6 + 1024 = 1030。</summary>
    public const int FramedBytes = HeaderBytes + PayloadBytes;

    /// <summary>
    /// 解析一个 UDP 载荷。
    ///
    /// 为什么这里用 ReadOnlySpan&lt;byte&gt; 而不是 byte[]?
    /// 因为 Span 是一段"数组的视图",传它不会复制数据、也不会产生额外的堆分配。
    /// 你的数据每秒来 1000 包,能不复制就不复制,这是性能习惯。
    /// </summary>
    public static AScanParseResult Parse(ReadOnlySpan<byte> payload, out AScanFrame? frame, out string error)
    {
        frame = null;
        error = string.Empty;

        // ── 判断是哪种格式 ──
        bool hasHeader = payload.Length >= FramedBytes
                         && payload[0] == FrameHead0
                         && payload[1] == FrameHead1;

        int dataOffset;

        if (hasHeader)
        {
            ushort pointCount = ReadBigEndianUInt16(payload, 4);

            if (pointCount != PointCount)
            {
                error = $"包里的点数写的是 {pointCount},但上位机期望 {PointCount}";
                return AScanParseResult.BadPointCount;
            }

            dataOffset = HeaderBytes;
        }
        else if (payload.Length == PayloadBytes)
        {
            // 这是你 FPGA 现在的格式:纯 1024 字节
            dataOffset = 0;
        }
        else
        {
            error = $"收到 {payload.Length} 字节,期望 {PayloadBytes}(纯数据)或 {FramedBytes}(带包头)";
            return AScanParseResult.UnexpectedLength;
        }

        // ── 读取 512 个 16 位采样值 ──
        var raw = new ushort[PointCount];

        for (int i = 0; i < PointCount; i++)
        {
            // 每个点占 2 个字节:高字节在前
            raw[i] = ReadBigEndianUInt16(payload, dataOffset + i * 2);
        }

        frame = new AScanFrame
        {
            // 带包头格式才有序号;纯数据格式没有,就填 0
            Sequence = hasHeader ? ReadBigEndianUInt16(payload, 2) : (ushort)0,
            Raw = raw,
            ReceivedAt = DateTime.Now
        };

        return AScanParseResult.Ok;
    }

    /// <summary>
    /// 从指定位置读出两个字节,拼成一个 16 位无符号数(高字节在前)。
    ///
    /// 这两行是整个文件里最关键的地方,值得单独说清楚:
    ///
    ///   FPGA 先发的是高字节。所以 data[offset] 是高 8 位,data[offset+1] 是低 8 位。
    ///   拼装方式:(高字节 &lt;&lt; 8) | 低字节
    ///
    /// 对比一下你在单片机里的写法,是完全一样的:
    ///     uint16_t v = (buf[0] &lt;&lt; 8) | buf[1];   // 大端
    ///     uint16_t v = buf[0] | (buf[1] &lt;&lt; 8);   // 小端
    ///
    /// ⚠️ 千万不要用 BitConverter.ToUInt16()。
    /// 那个方法按 CPU 的字节序来解释,而 x86/x64 是小端,
    /// 结果会把高低字节反过来 —— 数值 1 会变成 256,你从波形上要排查半天。
    /// 跨设备通信时,自己动手拼字节比调用现成方法可靠得多。
    /// </summary>
    private static ushort ReadBigEndianUInt16(ReadOnlySpan<byte> data, int offset)
    {
        return (ushort)((data[offset] << 8) | data[offset + 1]);
    }

    /// <summary>
    /// 反向操作:把 512 个值打包成 FPGA 格式的 1024 字节。
    /// 只被"仿真数据源"使用 —— 让模拟出来的包和 FPGA 发的一模一样,
    /// 这样整条解析链路(包括字节序)都能在没有硬件的情况下被验证。
    /// </summary>
    public static byte[] BuildPayload(ReadOnlySpan<ushort> points)
    {
        var payload = new byte[points.Length * 2];

        for (int i = 0; i < points.Length; i++)
        {
            payload[i * 2] = (byte)(points[i] >> 8);          // 高字节在前
            payload[i * 2 + 1] = (byte)(points[i] & 0xFF);    // 低字节在后
        }

        return payload;
    }
}
