using System.Diagnostics;

namespace UltrasoundHost;

/// <summary>仿真波形类型。</summary>
public enum SimulatedWaveform
{
    /// <summary>逼真的超声波 A 扫回波(表面波 + 缺陷波 + 底面波)。</summary>
    UltrasoundEcho,

    /// <summary>0,1,2,...,511 的自增斜坡 —— 和你 FPGA 里 data_gen 现在发的一模一样。</summary>
    RampTest
}

/// <summary>
/// 【通信层】假数据源 —— 没有 FPGA、没有网线也能把上位机跑起来。
///
/// 它刻意做到两件事:
///   1. 产出的字节流格式和 FPGA 完全相同(1024 字节、大端、9 位有效)
///      这样整条解析链路都能被真实验证,包括最容易错的字节序。
///   2. 支持 RampTest 模式,发 0~511 的斜坡。
///      你可以先用仿真跑一遍,看到一条从左下到右上的完美斜线;
///      等 FPGA 接上网线,如果也是同一条斜线,就说明两边完全对上了。
/// </summary>
public sealed class SimulatedSource : IUdpSource
{
    private readonly SimulatedWaveform _waveform;
    private readonly int _intervalMs;
    private readonly Random _random = new();

    private CancellationTokenSource? _cts;
    private Task? _pumpTask;
    private bool _disposed;
    private int _frameIndex;

    /// <param name="waveform">要仿真哪种波形。</param>
    /// <param name="intervalMs">
    /// 发包间隔(毫秒)。你的 FPGA 是 1ms 一个包,这里默认也设成 1,
    /// 用来复现真实的接收压力(每秒 1000 包)。
    /// </param>
    public SimulatedSource(SimulatedWaveform waveform, int intervalMs = 1)
    {
        _waveform = waveform;
        _intervalMs = Math.Max(1, intervalMs);
    }

    public string Name => _waveform == SimulatedWaveform.RampTest
        ? $"仿真测试斜坡(0~511,{_intervalMs}ms/包)"
        : $"仿真超声波回波({_intervalMs}ms/包)";

    public bool IsRunning { get; private set; }

    public event Action<byte[]>? DatagramReceived;
    public event Action<string>? Log;

    public void Start()
    {
        if (IsRunning)
        {
            return;
        }

        _cts = new CancellationTokenSource();
        IsRunning = true;
        _pumpTask = Task.Run(() => PumpLoopAsync(_cts.Token));

        Log?.Invoke($"仿真数据源已启动:{Name}");
    }

    private async Task PumpLoopAsync(CancellationToken token)
    {
        // 为什么用 Stopwatch 而不是简单地 await Task.Delay(1)?
        // 因为 Windows 的定时器精度大约是 15ms,Task.Delay(1) 实际会等 ~15ms,
        // 那样每秒只能发 60 多个包,远远达不到你 FPGA 的 1000 包/秒。
        // 用 Stopwatch 记录"应该在第几毫秒发第几个包",把误差补回来,
        // 就能得到比较准确的平均速率。这是上位机里很常用的一个技巧。
        var stopwatch = Stopwatch.StartNew();
        long packetIndex = 0;

        while (!token.IsCancellationRequested)
        {
            try
            {
                DatagramReceived?.Invoke(BuildDatagram());
            }
            catch (Exception ex)
            {
                Log?.Invoke($"仿真发包出错(已忽略):{ex.Message}");
            }

            packetIndex++;

            // 计算"第 packetIndex 个包应该在什么时刻发出",然后补足差额
            long targetMs = packetIndex * _intervalMs;
            int waitMs = (int)(targetMs - stopwatch.ElapsedMilliseconds);

            if (waitMs > 0)
            {
                try
                {
                    await Task.Delay(waitMs, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }

    /// <summary>生成一个完整的 UDP 载荷(1024 字节)。</summary>
    private byte[] BuildDatagram()
    {
        ushort[] points = _waveform == SimulatedWaveform.RampTest
            ? BuildRamp()
            : BuildUltrasoundEcho(_frameIndex++);

        // 复用主项目里的打包函数,保证字节序和协议层是同一套逻辑。
        // 这样如果仿真数据能被正确解析,就证明协议层自洽。
        return AScanProtocol.BuildPayload(points);
    }

    /// <summary>0,1,2,...,511 —— 和 FPGA 里 data_gen 生成的序列一致。</summary>
    private static ushort[] BuildRamp()
    {
        var points = new ushort[AScanFrame.PointCount];

        for (int i = 0; i < points.Length; i++)
        {
            points[i] = (ushort)i;
        }

        return points;
    }

    /// <summary>
    /// 合成一个像样的超声波 A 扫波形。
    ///
    /// 思路:把所有回波叠加起来,再加一点噪声。
    /// 每个回波都是一个"高斯包络" —— 中间高、两边低,像一个钟形,
    /// 这正是超声探头收到一个回波时检波后的形状。
    ///
    ///     幅值 = 峰值 × exp( -(距离²) / (2 × 宽度²) )
    /// </summary>
    private ushort[] BuildUltrasoundEcho(int frameIndex)
    {
        var points = new ushort[AScanFrame.PointCount];

        // 让缺陷回波随时间缓慢左右移动,看起来像探头在扫查,
        // 这样你一眼就能看出"波形是在实时更新的",而不是卡住了。
        double drift = Math.Sin(frameIndex * 0.04) * 10.0;

        for (int i = 0; i < points.Length; i++)
        {
            double value = 0;

            value += GaussianEcho(i, 12, 3.0, 470);                     // 表面回波:最强,位置固定
            value += GaussianEcho(i, 126 + drift, 6.0, 215);            // 缺陷回波 1
            value += GaussianEcho(i, 254 + drift * 1.7, 8.0, 140);      // 缺陷回波 2
            value += GaussianEcho(i, 486, 5.0, 405);                    // 底面回波

            value += _random.Next(-2, 3);                               // 随机噪声

            points[i] = (ushort)Math.Clamp(
                (int)Math.Round(value) * AScanFrame.ValueScale,
                0,
                65535);   // 限制在 0~511,模拟 9 位有效
        }

        return points;
    }

    /// <summary>一个高斯形状的回波包。</summary>
    private static double GaussianEcho(int index, double center, double width, double amplitude)
    {
        double d = index - center;
        return amplitude * Math.Exp(-(d * d) / (2 * width * width));
    }

    public void Stop()
    {
        if (!IsRunning)
        {
            return;
        }

        IsRunning = false;
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;
        _pumpTask = null;

        Log?.Invoke("仿真数据源已停止");
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Stop();
    }
}
