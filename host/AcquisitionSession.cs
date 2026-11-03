namespace UltrasoundHost;

/// <summary>
/// 【会话层】采集会话 —— 把"收到一包字节"变成"得到一帧超声波波形"。
///
/// 它夹在通信层和界面层中间,干三件事:
///   1. 解析:把 UDP 载荷翻译成 AScanFrame
///   2. 统计:记录收了多少包、错了多少包、数据是不是卡住了
///   3. 上报:把解析好的帧抛给界面
///
/// 注意它完全不认识 Form / Label / 控件。
/// 判断分层有没有做对:把 MainForm.cs 和 WaveformPanel.cs 全删掉,
/// 剩下的文件应该还能编译通过。能通过,就说明通信和界面真的解耦了。
/// </summary>
public sealed class AcquisitionSession : IDisposable
{
    private readonly IUdpSource _source;
    private bool _disposed;

    // ── 统计计数 ──
    // 这些字段会被两个线程同时访问:接收线程写,UI 线程读。
    // 所以用 Interlocked 做原子累加,避免读到"改了一半"的值。
    private long _totalDatagrams;
    private long _parsedFrames;
    private long _parseErrors;
    private long _stuckFrames;

    // 用来判断"数据是不是卡住了"
    private int _lastFrameHash = -1;
    private int _sameValueStreak;

    public AcquisitionSession(IUdpSource source)
    {
        _source = source;
        _source.DatagramReceived += OnDatagram;
        _source.Log += message => Log?.Invoke(message);
    }

    /// <summary>解析成功一帧时触发。⚠️ 在后台线程触发,订阅方只能入队,不能碰控件。</summary>
    public event Action<AScanFrame>? FrameReceived;

    /// <summary>提示信息。⚠️ 同样在后台线程触发。</summary>
    public event Action<string>? Log;

    public string SourceName => _source.Name;
    public bool IsRunning => _source.IsRunning;

    /// <summary>收到的 UDP 包总数(不管解析成没成功)。</summary>
    public long TotalDatagrams => Interlocked.Read(ref _totalDatagrams);

    /// <summary>成功解析出的帧数。</summary>
    public long ParsedFrames => Interlocked.Read(ref _parsedFrames);

    /// <summary>解析失败的包数。</summary>
    public long ParseErrors => Interlocked.Read(ref _parseErrors);

    /// <summary>
    /// "数据没变化"的连续帧数。
    /// 如果这个数一直涨,说明链路通着但波形是死的 ——
    /// 可能 FPGA 那边数据源停了,或者在重复发同一份数据。
    /// </summary>
    public long StuckFrames => Interlocked.Read(ref _stuckFrames);

    public void Start()
    {
        _source.Start();
    }

    public void Stop()
    {
        _source.Stop();
    }

    /// <summary>
    /// 收到一个 UDP 包。这是整个数据链路的"入口闸门"。
    /// 这个方法运行在接收线程上(真实 UDP)或仿真线程上。
    /// </summary>
    private void OnDatagram(byte[] payload)
    {
        Interlocked.Increment(ref _totalDatagrams);

        AScanParseResult result = AScanProtocol.Parse(payload, out AScanFrame? frame, out string error);

        if (result != AScanParseResult.Ok || frame is null)
        {
            long errorCount = Interlocked.Increment(ref _parseErrors);

            // 只报告前几条错误,避免刷屏。太多了反而说明是系统性问题。
            if (errorCount <= 3)
            {
                Log?.Invoke($"解析失败:{error}");
            }
            else if (errorCount == 4)
            {
                Log?.Invoke("解析失败次数过多,后续同类错误不再逐条显示");
            }

            return;
        }

        Interlocked.Increment(ref _parsedFrames);

        // ── 检测"数据卡住" ──
        // 只看每帧的第一个点就够了,不用比较全部 512 个点。
        // 采集场景下,如果有变化,第一个点通常也会变。
        // ⚠️ 不能只比较第 0 个点: 第 0 点正对着激励脉冲, 永远是饱和值,
        //    结果每帧都"完全一样", 会一直误报"数据停滞"。
        // 这里改用整帧数据的滚动校验和, 任何一个点变了都能发现。
        int frameHash = 17;
        for (int i = 0; i < frame.Raw.Length; i++)
        {
            frameHash = unchecked(frameHash * 31 + frame.AmplitudeAt(i));
        }

        if (frameHash == _lastFrameHash)
        {
            _sameValueStreak++;

            // 连续 200 帧(按 1ms 一包算就是 200ms)完全相同,才认为异常
            if (_sameValueStreak == 200)
            {
                Log?.Invoke("提示:连续 200 帧数据完全一样,波形可能已经停止更新");
            }

            if (_sameValueStreak > 200)
            {
                Interlocked.Increment(ref _stuckFrames);
            }
        }
        else
        {
            _sameValueStreak = 0;
            _lastFrameHash = frameHash;
        }

        FrameReceived?.Invoke(frame);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _source.DatagramReceived -= OnDatagram;
        _source.Dispose();
    }
}
