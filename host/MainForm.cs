using System.Collections.Concurrent;

namespace UltrasoundHost;

/// <summary>
/// 【界面层】主窗口。
///
/// ══════════════════════════════════════════════════════════
///  界面和数据是怎么配合的(这是整个程序的核心机制)
/// ══════════════════════════════════════════════════════════
///
///  一条铁律:WinForms 的控件只能被"创建它的那个线程"访问。
///  而数据是在后台线程收到的。所以后台线程绝对不能直接写控件:
///
///      ❌ _lblPeak.Text = frame.FindPeak().DepthMm;   // 这样写必然崩
///
///  正确做法是"过桥":
///
///      后台线程  →  把数据丢进队列  →  UI 线程的定时器  →  写控件
///
///  队列就是两座桥(_frameQueue 和 _logQueue),
///  UI 定时器就是那个"唯一被允许上屏"的时刻。
///
///  这样做还有个额外好处:界面刷新频率(200ms)和采集频率(1ms)可以完全不一样。
///  你 FPGA 每秒发 1000 包,界面照样稳稳地每秒刷 5 次,不会卡。
/// </summary>
public sealed class MainForm : Form
{
    private const int SourceSimulatedEcho = 0;
    private const int SourceSimulatedRamp = 1;
    private const int SourceRealUdp = 2;

    // ── 界面控件 ──
    private readonly TextBox _txtPort = new();
    private readonly ComboBox _cboSource = new();
    private readonly Button _btnStart = new();
    private readonly CheckBox _chkTrail = new();
    private readonly WaveformPanel _waveform = new();
    private readonly Label _lblStats = new();
    private readonly Label _lblPeak = new();
    private readonly ListBox _lstLog = new();

    // ── 数据通道 ──
    private readonly ConcurrentQueue<AScanFrame> _frameQueue = new();
    private readonly ConcurrentQueue<string> _logQueue = new();

    private readonly System.Windows.Forms.Timer _uiTimer = new();

    // ── 状态与统计 ──
    private AcquisitionSession? _session;
    private DateTime _startTime;
    private DateTime _rateWindowStart = DateTime.Now;
    private long _rateWindowFrames;
    private double _packetRate;
    private bool _rampHintShown;
    private bool _timeoutHintShown;

    public MainForm()
    {
        BuildUi();

        // 界面刷新定时器:每 200ms 一次。
        // 5 次/秒对人眼来说已经足够流畅,再快只是浪费 CPU。
        _uiTimer.Interval = 200;
        _uiTimer.Tick += (_, _) => RefreshFromQueues();
        _uiTimer.Start();
    }

    // ═══════════════════════════════════════════════════════════
    //  界面搭建
    // ═══════════════════════════════════════════════════════════

    private void BuildUi()
    {
        Text = "超声波 A 扫上位机 · FPGA UDP 采集";
        ClientSize = new Size(1000, 700);
        Font = new Font("Microsoft YaHei UI", 9F);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(820, 600);

        // ───────── 顶部:接收设置 ─────────

        Controls.Add(new Label
        {
            Text = "监听端口",
            Location = new Point(16, 22),
            AutoSize = true
        });

        _txtPort.Location = new Point(88, 18);
        _txtPort.Size = new Size(70, 25);
        _txtPort.Text = "1234";          // 你 FPGA 里的目的端口就是 6666
        _txtPort.TextAlign = HorizontalAlignment.Center;
        Controls.Add(_txtPort);

        Controls.Add(new Label
        {
            Text = "数据源",
            Location = new Point(174, 22),
            AutoSize = true
        });

        _cboSource.Location = new Point(232, 18);
        _cboSource.Size = new Size(210, 25);
        _cboSource.DropDownStyle = ComboBoxStyle.DropDownList;
        _cboSource.Items.AddRange(new object[]
        {
            "仿真超声波回波（无需 FPGA）",
            "仿真测试斜坡 0~511（对照 FPGA）",
            "真实 UDP 数据（FPGA）"
        });
        _cboSource.SelectedIndex = SourceSimulatedEcho;
        Controls.Add(_cboSource);

        _btnStart.Location = new Point(462, 16);
        _btnStart.Size = new Size(118, 30);
        _btnStart.Text = "开始接收";
        _btnStart.Click += OnStartButtonClick;
        Controls.Add(_btnStart);

        _chkTrail.Location = new Point(596, 20);
        _chkTrail.AutoSize = true;
        _chkTrail.Text = "余辉叠加";
        _chkTrail.CheckedChanged += (_, _) => _waveform.ShowTrail = _chkTrail.Checked;
        Controls.Add(_chkTrail);

        // ───────── 中部:波形显示 ─────────

        _waveform.Location = new Point(16, 62);
        _waveform.Size = new Size(968, 420);
        _waveform.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        Controls.Add(_waveform);

        // ───────── 统计 ─────────

        _lblStats.Location = new Point(16, 492);
        _lblStats.Size = new Size(968, 20);
        _lblStats.Text = "包速率 --    总包数 0    有效帧 0    解析失败 0";
        _lblStats.Font = new Font("Consolas", 9.5F);
        _lblStats.ForeColor = Color.FromArgb(95, 94, 90);
        Controls.Add(_lblStats);

        _lblPeak.Location = new Point(16, 518);
        _lblPeak.Size = new Size(968, 20);
        _lblPeak.Text = "峰值 --";
        _lblPeak.Font = new Font("Consolas", 9.5F);
        _lblPeak.ForeColor = Color.FromArgb(153, 60, 29);
        Controls.Add(_lblPeak);

        // ───────── 底部:日志 ─────────

        Controls.Add(new Label
        {
            Text = "运行日志",
            Location = new Point(16, 548),
            AutoSize = true,
            ForeColor = Color.FromArgb(95, 94, 90)
        });

        _lstLog.Location = new Point(16, 570);
        _lstLog.Size = new Size(968, 114);
        _lstLog.Font = new Font("Consolas", 8.5F);
        _lstLog.IntegralHeight = false;
        _lstLog.HorizontalScrollbar = true;
        _lstLog.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        Controls.Add(_lstLog);
    }

    // ═══════════════════════════════════════════════════════════
    //  开始 / 停止
    // ═══════════════════════════════════════════════════════════

    private void OnStartButtonClick(object? sender, EventArgs e)
    {
        if (_session is { IsRunning: true })
        {
            StopAcquisition();
        }
        else
        {
            StartAcquisition();
        }
    }

    private void StartAcquisition()
    {
        if (!int.TryParse(_txtPort.Text.Trim(), out int port) || port is < 1 or > 65535)
        {
            MessageBox.Show(this, "端口号必须是 1~65535 之间的整数。", "输入有误",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        // ── 这一步就是"接口"的价值所在 ──
        // 下面三行决定了数据从哪来,而之后所有代码都完全不知道区别。
        IUdpSource source = _cboSource.SelectedIndex switch
        {
            SourceSimulatedRamp => new SimulatedSource(SimulatedWaveform.RampTest),
            SourceRealUdp => new UdpSource(port),
            _ => new SimulatedSource(SimulatedWaveform.UltrasoundEcho)
        };

        var session = new AcquisitionSession(source);

        // ⚠️ 这两个订阅的回调都在后台线程执行。
        //    所以里面只能做一件事:入队。绝对不许出现任何控件。
        session.FrameReceived += frame => _frameQueue.Enqueue(frame);
        session.Log += message => _logQueue.Enqueue(message);

        try
        {
            session.Start();
        }
        catch (Exception ex)
        {
            session.Dispose();
            MessageBox.Show(this, ex.Message, "启动失败",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        _session = session;
        _startTime = DateTime.Now;
        _rateWindowStart = DateTime.Now;
        _rateWindowFrames = 0;
        _packetRate = 0;
        _rampHintShown = false;
        _timeoutHintShown = false;

        _waveform.Clear();
        _lstLog.Items.Clear();
        _lblPeak.Text = "峰值 --";

        _btnStart.Text = "停止接收";
        _txtPort.Enabled = false;
        _cboSource.Enabled = false;

        EnqueueLog($"===== 开始接收 · {session.SourceName} =====");
    }

    private void StopAcquisition()
    {
        _session?.Dispose();
        _session = null;

        _btnStart.Text = "开始接收";
        _txtPort.Enabled = true;
        _cboSource.Enabled = true;

        // 清掉队列里的残留,免得重新开始时先闪一下旧数据
        while (_frameQueue.TryDequeue(out _))
        {
            // 故意空循环
        }

        EnqueueLog("===== 已停止 =====");
    }

    // ═══════════════════════════════════════════════════════════
    //  定时刷新界面(唯一允许碰控件的地方)
    // ═══════════════════════════════════════════════════════════

    private void RefreshFromQueues()
    {
        // ── 1. 把后台收到的波形搬上屏幕 ──

        AScanFrame? latest = null;
        long received = 0;

        while (_frameQueue.TryDequeue(out var frame))
        {
            if (frame is null)
            {
                continue;
            }

            latest = frame;
            received++;
        }

        if (latest is not null)
        {
            _rateWindowFrames += received;

            // 只画最新那一帧。
            // 200ms 内可能来了 200 个包,把 200 帧都画一遍纯属浪费 ——
            // 屏幕上反正只看得到最后一帧。让"人看得懂"优先于"一帧不落"。
            _waveform.SetFrame(latest);

            PeakInfo peak = latest.FindPeak(20);
            List<PeakInfo> echoes = latest.FindPeaks(6, 20, 0.20, 5.0);

            string echoText = "";
            foreach (PeakInfo e in echoes)
            {
                echoText += string.Format(
                    System.Globalization.CultureInfo.InvariantCulture,
                    "{0,6:F1}mm/{1,4}   ", e.DepthMm, e.Amplitude);
            }

            _lblPeak.Text = string.Format(
                System.Globalization.CultureInfo.InvariantCulture,
                "最强 {0,6:F1} mm / {1,4}  (第 {2,3} 点)      回波({3}个): {4}",
                peak.DepthMm, peak.Amplitude, peak.Index, echoes.Count, echoText);

            // 识别出 FPGA 的测试斜坡时,明确告诉用户链路是好的
            if (!_rampHintShown && latest.LooksLikeRamp())
            {
                _rampHintShown = true;
                EnqueueLog("✔ 检测到 0~511 测试斜坡信号 —— 512 个点全部正确,链路完全正常!");
                EnqueueLog("   （这是你 FPGA 里 data_gen 发的测试数据。换上真实采集数据后,这里就是波形了）");
            }
        }

        // ── 2. 搬日志 ──

        int logCount = 0;
        while (logCount < 15 && _logQueue.TryDequeue(out var line))
        {
            if (string.IsNullOrEmpty(line))
            {
                continue;
            }

            _lstLog.Items.Add(line);
            logCount++;
        }

        if (logCount > 0)
        {
            while (_lstLog.Items.Count > 300)
            {
                _lstLog.Items.RemoveAt(0);
            }

            _lstLog.TopIndex = Math.Max(0, _lstLog.Items.Count - 1);
        }

        // ── 3. 每秒算一次包速率 ──

        DateTime now = DateTime.Now;
        double elapsed = (now - _rateWindowStart).TotalSeconds;

        if (elapsed >= 1.0)
        {
            _packetRate = _rateWindowFrames / elapsed;
            _rateWindowFrames = 0;
            _rateWindowStart = now;
        }

        UpdateStatsLabel();

        // ── 4. 启动后 3 秒还收不到包,给出排查指引 ──
        // 这个提示能省掉你大量瞎猜的时间 —— 收不到数据几乎总是这 4 个原因之一。
        if (_session is { IsRunning: true } && !_timeoutHintShown
            && _cboSource.SelectedIndex == SourceRealUdp
            && _session.TotalDatagrams == 0
            && (now - _startTime).TotalSeconds > 3)
        {
            _timeoutHintShown = true;

            EnqueueLog("⚠ 3 秒内一个包都没收到,按顺序检查这 4 项:");
            EnqueueLog("   1. PC 网卡的 IP 是不是设成了 192.168.0.145(子网掩码 255.255.255.0)");
            EnqueueLog("   2. Windows 防火墙是否拦截了 UDP 6666 端口(最常见的原因)");
            EnqueueLog("   3. 网线是否插好、网卡是否显示\"已连接\"");
            EnqueueLog("   4. 用 Wireshark 过滤 udp.port==6666 看网口到底有没有收到包");
        }
    }

    private void UpdateStatsLabel()
    {
        long total = _session?.TotalDatagrams ?? 0;
        long frames = _session?.ParsedFrames ?? 0;
        long errors = _session?.ParseErrors ?? 0;
        long stuck = _session?.StuckFrames ?? 0;

        _lblStats.Text =
            $"包速率 {_packetRate,7:F0} pkt/s    总包数 {total,9}    " +
            $"有效帧 {frames,9}    解析失败 {errors,6}    数据停滞 {stuck,6}";
    }

    private void EnqueueLog(string message)
    {
        _logQueue.Enqueue($"[{DateTime.Now:HH:mm:ss.fff}] {message}");
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _uiTimer.Stop();
        _session?.Dispose();
        _session = null;
        base.OnFormClosing(e);
    }
}
