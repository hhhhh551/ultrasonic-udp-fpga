using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace UltrasoundHost;

/// <summary>
/// 【界面层】A 扫波形显示控件。
///
/// 这是整个程序里唯一"画图"的地方。
///
/// ══════════════════════════════════════════════════════════
///  坐标系是怎么换算的(这是画图最关键的一步)
/// ══════════════════════════════════════════════════════════
///
/// 你有两套坐标,必须来回换算:
///
///   【数据坐标】横轴 = 深度 0~235.06 mm,纵轴 = 幅值 0~511
///   【屏幕坐标】横轴 = 0~控件宽度(像素),纵轴 = 0~控件高度(像素)
///
/// 而且屏幕坐标有个反直觉的地方:原点在【左上角】,y 往下增长。
/// 数据里"大"的值应该画在"上面",但屏幕上"上面"是 y 小的方向。
/// 所以换算时要反过来减:
///
///   屏幕x = 左边距 + (点序号 / 511) × 绘图区宽度
///   屏幕y = 绘图区底部 - (幅值 / 511) × 绘图区高度
///                              ↑
///                        这个减号就是"翻转"
///
/// 所有图表库、示波器软件,底层都是这么算的。理解了这一件事,
/// 你以后用任何图表库都知道参数该填什么。
/// </summary>
public sealed class WaveformPanel : Panel
{
    // 四个方向留出的空白,用来放坐标轴上的刻度数字
    private const int PadLeft = 68;
    private const int PadRight = 24;
    private const int PadTop = 26;
    private const int PadBottom = 46;

    /// <summary>横轴刻度间隔(毫米)。</summary>
    private const double DepthTickStep = 25.0;

    /// <summary>纵轴刻度间隔(幅值)。</summary>
    private const int AmplitudeTickStep = 200;

    /// <summary>余辉保留多少帧。</summary>
    private const int TrailDepth = 8;

    /// <summary>找峰值时跳过开头多少个点(躲开表面回波)。</summary>
    private const int PeakSearchStart = 20;

    /// <summary>最多标注几个回波。</summary>
    private const int PeakMaxCount = 8;

    /// <summary>回波检测门限 = 本帧最大值 × 该比例。</summary>
    private const double PeakThresholdRatio = 0.20;

    /// <summary>小于这个间距(mm)的回波合并成一个。</summary>
    private const double PeakMinSeparationMm = 5.0;

    private readonly Font _tickFont = new("Microsoft YaHei UI", 8.5F);
    private readonly SolidBrush _textBrush = new(Color.FromArgb(110, 108, 102));

    /// <summary>纵轴满量程。按当前帧峰值自动缩放, 不再是固定的 0~1023。</summary>
    private int _fullScale = 400;

    /// <summary>纵轴刻度步长(随满量程自动选, 让网格保持 4~5 条)。</summary>
    private int _tickStep = 100;

    private AScanFrame? _frame;
    private readonly List<AScanFrame> _trails = new();

    private int _hoverX = -1;
    private int _hoverY = -1;

    public WaveformPanel()
    {
        // 双缓冲:先画在内存里,再一次性贴到屏幕。
        // 不加这个,波形刷新时会闪得没法看。
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint |
            ControlStyles.OptimizedDoubleBuffer,
            true);

        BackColor = Color.White;
        BorderStyle = BorderStyle.FixedSingle;
        Cursor = Cursors.Cross;
    }

    /// <summary>是否显示余辉(之前几帧的淡淡残影),用来观察波形稳不稳定。</summary>
    public bool ShowTrail { get; set; }

    /// <summary>显示一帧新波形。必须在 UI 线程调用。</summary>
    public void SetFrame(AScanFrame frame)
    {
        _frame = frame;
        UpdateFullScale(frame);

        if (ShowTrail)
        {
            _trails.Add(frame);

            while (_trails.Count > TrailDepth)
            {
                _trails.RemoveAt(0);
            }
        }

        // 告诉系统"这块区域脏了,需要重画"。
        // 不是立刻重画,而是排队等界面空闲时统一处理,所以连续调用也不会卡。
        Invalidate();
    }

    /// <summary>
    /// 按当前帧的峰值自动选纵轴满量程, 让波形填满绘图区。
    /// 带滞回到: 峰值超出当前量程才放大, 掉到 60% 以下才缩小,
    /// 避免每帧峰值抖动导致纵轴跟着来回跳。
    /// </summary>
    private void UpdateFullScale(AScanFrame frame)
    {
        int peak = 0;
        for (int i = 0; i < frame.Raw.Length; i++)
        {
            int v = frame.AmplitudeAt(i);
            if (v > peak)
            {
                peak = v;
            }
        }

        if (peak > _fullScale || peak < _fullScale * 0.6)
        {
            _fullScale = PickFullScale(peak);
            _tickStep  = PickTickStep(_fullScale);
        }
    }

    /// <summary>从一组"整"档位里挑一个刚好装得下 peak 的满量程(留 20% 余量)。</summary>
    private static int PickFullScale(int peak)
    {
        int target = peak + peak / 5 + 10;
        int[] ladder = { 100, 150, 200, 250, 300, 400, 500, 600, 800, 1000, AScanFrame.MaxAmplitude };

        foreach (int f in ladder)
        {
            if (f >= target)
            {
                return f;
            }
        }

        return AScanFrame.MaxAmplitude;
    }

    /// <summary>让纵轴大约有 4~5 条网格线。</summary>
    private static int PickTickStep(int full)
    {
        int[] steps = { 50, 100, 200, 250, 500 };

        foreach (int s in steps)
        {
            if (full / s <= 5)
            {
                return s;
            }
        }

        return 500;
    }
    public void Clear()
    {
        _frame = null;
        _trails.Clear();
        Invalidate();
    }

    // ═══════════════════════════════════════════════════
    //  鼠标交互:悬停读数
    // ═══════════════════════════════════════════════════

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        _hoverX = e.X;
        _hoverY = e.Y;
        Invalidate();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        _hoverX = -1;
        _hoverY = -1;
        Invalidate();
    }

    // ═══════════════════════════════════════════════════
    //  绘制
    // ═══════════════════════════════════════════════════

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);

        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

        Rectangle plot = GetPlotArea();
        if (plot.Width < 20 || plot.Height < 20)
        {
            return;
        }

        DrawGrid(g, plot);
        DrawAxes(g, plot);

        if (_frame is null)
        {
            DrawEmptyHint(g, plot);
            return;
        }

        if (ShowTrail && _trails.Count > 1)
        {
            DrawTrails(g, plot);
        }

        DrawWaveform(g, plot, _frame);

        List<PeakInfo> echoes = _frame.FindPeaks(
            PeakMaxCount, PeakSearchStart, PeakThresholdRatio, PeakMinSeparationMm);
        DrawEchoMarkers(g, plot, echoes);

        if (_hoverX >= plot.Left && _hoverX <= plot.Right && _hoverY >= plot.Top && _hoverY <= plot.Bottom)
        {
            DrawHoverCrosshair(g, plot, _frame);
        }
    }

    /// <summary>算出真正用来画波形的那块矩形。</summary>
    private Rectangle GetPlotArea() => new(
        PadLeft,
        PadTop,
        Math.Max(0, Width - PadLeft - PadRight),
        Math.Max(0, Height - PadTop - PadBottom));

    /// <summary>数据点序号 → 屏幕 X 坐标。</summary>
    private static float IndexToScreenX(Rectangle plot, int index) =>
        plot.Left + plot.Width * index / (float)(AScanFrame.PointCount - 1);

    /// <summary>幅值 → 屏幕 Y 坐标(注意这里的减号就是坐标翻转)。</summary>
    private float ValueToScreenY(Rectangle plot, int value) =>
        plot.Bottom - plot.Height * Math.Clamp(value, 0, _fullScale) / (float)_fullScale;

    /// <summary>屏幕 X 坐标 → 数据点序号(鼠标悬停时用)。</summary>
    private static int ScreenXToIndex(Rectangle plot, int screenX)
    {
        double ratio = (screenX - plot.Left) / (double)plot.Width;
        int index = (int)Math.Round(ratio * (AScanFrame.PointCount - 1));
        return Math.Clamp(index, 0, AScanFrame.PointCount - 1);
    }

    /// <summary>画网格线。</summary>
    private void DrawGrid(Graphics g, Rectangle plot)
    {
        using var gridPen = new Pen(Color.FromArgb(236, 236, 232), 1f);
        using var borderPen = new Pen(Color.FromArgb(200, 200, 194), 1f);

        // 横向网格:按幅值刻度
        for (int value = 0; value <= _fullScale; value += _tickStep)
        {
            float y = ValueToScreenY(plot, value);
            g.DrawLine(gridPen, plot.Left, y, plot.Right, y);
        }

        // 纵向网格:按深度刻度
        for (double mm = 0; mm <= AScanFrame.MaxDepthMm; mm += DepthTickStep)
        {
            float x = plot.Left + (float)(mm / AScanFrame.MaxDepthMm * plot.Width);
            g.DrawLine(gridPen, x, plot.Top, x, plot.Bottom);
        }

        // 外框
        g.DrawRectangle(borderPen, plot);
    }

    /// <summary>画坐标轴上的刻度数字和单位。</summary>
    private void DrawAxes(Graphics g, Rectangle plot)
    {
        // ── 纵轴(幅值) ──
        using (var rightAlign = new StringFormat
        {
            Alignment = StringAlignment.Far,
            LineAlignment = StringAlignment.Center
        })
        {
            for (int value = 0; value <= _fullScale; value += _tickStep)
            {
                float y = ValueToScreenY(plot, value);
                g.DrawString(value.ToString(), _tickFont, _textBrush,
                    new RectangleF(0, y - 8, PadLeft - 10, 16), rightAlign);
            }
        }

        g.DrawString("幅值", _tickFont, _textBrush, new PointF(4, 4));

        // ── 横轴(深度,单位毫米) ──
        using (var centerAlign = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Near
        })
        {
            for (double mm = 0; mm <= AScanFrame.MaxDepthMm; mm += DepthTickStep)
            {
                float x = plot.Left + (float)(mm / AScanFrame.MaxDepthMm * plot.Width);
                g.DrawString(mm.ToString("F0"), _tickFont, _textBrush,
                    new RectangleF(x - 20, plot.Bottom + 5, 40, 16), centerAlign);
            }
        }

        string axisTitle = string.Format(
            System.Globalization.CultureInfo.InvariantCulture,
            "深度 (mm) · 每点 {0:F3} mm", AScanFrame.MmPerPoint);
        g.DrawString(axisTitle, _tickFont, _textBrush,
            new PointF(plot.Left, plot.Bottom + 24));
    }

    /// <summary>没有数据时的提示。</summary>
    /// <summary>
    /// 把检测到的所有回波都标出来。
    /// 最强的那一个画竖线 + 数值; 其余只画小圆圈 + 深度, 避免画面太乱。
    /// </summary>
    private void DrawEchoMarkers(Graphics g, Rectangle plot, List<PeakInfo> echoes)
    {
        if (echoes.Count == 0)
        {
            return;
        }

        int best = 0;
        for (int i = 1; i < echoes.Count; i++)
        {
            if (echoes[i].Amplitude > echoes[best].Amplitude)
            {
                best = i;
            }
        }

        using var strongPen = new Pen(Color.FromArgb(216, 90, 48), 1.2f);
        using var weakPen   = new Pen(Color.FromArgb(216, 90, 48), 1.0f);
        using var strongBrush = new SolidBrush(Color.FromArgb(216, 90, 48));
        using var weakBrush   = new SolidBrush(Color.FromArgb(150, 110, 90));

        for (int i = 0; i < echoes.Count; i++)
        {
            PeakInfo p = echoes[i];
            float x = IndexToScreenX(plot, p.Index);
            float y = ValueToScreenY(plot, p.Amplitude);

            if (i == best)
            {
                g.DrawLine(strongPen, x, plot.Top, x, plot.Bottom);
                g.DrawEllipse(strongPen, x - 4.5f, y - 4.5f, 9f, 9f);
                g.DrawString(
                    string.Format(System.Globalization.CultureInfo.InvariantCulture,
                        "最强 {0:F1} mm / {1}", p.DepthMm, p.Amplitude),
                    _tickFont, strongBrush, new PointF(x + 6f, y - 17f));
            }
            else
            {
                g.DrawEllipse(weakPen, x - 3f, y - 3f, 6f, 6f);
                g.DrawString(
                    string.Format(System.Globalization.CultureInfo.InvariantCulture,
                        "{0:F1}", p.DepthMm),
                    _tickFont, weakBrush, new PointF(x + 5f, y - 14f));
            }
        }
    }
    private void DrawEmptyHint(Graphics g, Rectangle plot)
    {
        using var hintFont = new Font("Microsoft YaHei UI", 11F);
        using var hintBrush = new SolidBrush(Color.FromArgb(170, 168, 160));
        using var centerAlign = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center
        };

        g.DrawString("等待数据…\n\n点上方「开始接收」按钮\n选择「仿真」可以在没有 FPGA 的情况下先看效果",
            hintFont, hintBrush, plot, centerAlign);
    }

    /// <summary>画余辉:之前几帧的淡淡残影,越旧的越淡。</summary>
    private void DrawTrails(Graphics g, Rectangle plot)
    {
        int count = _trails.Count;

        for (int t = 0; t < count - 1; t++)
        {
            // 越早的帧越透明(alpha 越小)
            int alpha = 12 + 40 * t / Math.Max(1, count - 1);

            using var pen = new Pen(Color.FromArgb(alpha, 24, 95, 165), 1f);
            DrawPolyline(g, pen, plot, _trails[t]);
        }
    }

    /// <summary>画主波形:一条折线 + 下方淡填充。</summary>
    private void DrawWaveform(Graphics g, Rectangle plot, AScanFrame frame)
    {
        using var linePen = new Pen(Color.FromArgb(24, 95, 165), 1.4f)
        {
            LineJoin = LineJoin.Round
        };

        // ── 淡填充:让波形下面填一层很浅的蓝色,视觉上更像示波器 ──
        var filled = new PointF[AScanFrame.PointCount + 2];
        filled[0] = new PointF(plot.Left, plot.Bottom);

        for (int i = 0; i < AScanFrame.PointCount; i++)
        {
            filled[i + 1] = new PointF(
                IndexToScreenX(plot, i),
                ValueToScreenY(plot, frame.AmplitudeAt(i)));
        }

        filled[^1] = new PointF(plot.Right, plot.Bottom);

        using (var fillBrush = new SolidBrush(Color.FromArgb(28, 24, 95, 165)))
        {
            g.FillPolygon(fillBrush, filled);
        }

        // ── 折线 ──
        DrawPolyline(g, linePen, plot, frame);
    }

    private void DrawPolyline(Graphics g, Pen pen, Rectangle plot, AScanFrame frame)
    {
        var points = new PointF[AScanFrame.PointCount];

        for (int i = 0; i < AScanFrame.PointCount; i++)
        {
            points[i] = new PointF(
                IndexToScreenX(plot, i),
                ValueToScreenY(plot, frame.AmplitudeAt(i)));
        }

        g.DrawLines(pen, points);
    }

    /// <summary>标出峰值的位置 —— 这是超声波检测最关心的数字。</summary>
    private void DrawPeakMarker(Graphics g, Rectangle plot, PeakInfo peak)
    {
        float x = IndexToScreenX(plot, peak.Index);
        float y = ValueToScreenY(plot, peak.Amplitude);

        using var markerPen = new Pen(Color.FromArgb(216, 90, 48), 1.2f);
        using var markerBrush = new SolidBrush(Color.FromArgb(216, 90, 48));

        // 一个小圆圈套在峰值点上
        g.DrawEllipse(markerPen, x - 4.5f, y - 4.5f, 9f, 9f);
        g.DrawLine(markerPen, x, plot.Top, x, plot.Bottom);

        // 文字标签。靠右边太近的话就改到左边显示,免得被裁掉。
        string label = $"峰值 {peak.DepthMm:F1} mm / {peak.Amplitude}";
        using var labelFont = new Font("Microsoft YaHei UI", 8.5F);
        SizeF size = g.MeasureString(label, labelFont);

        float labelX = x + 8;
        if (labelX + size.Width > plot.Right)
        {
            labelX = x - 8 - size.Width;
        }

        float labelY = Math.Max(plot.Top + 2, y - size.Height - 6);

        using var backBrush = new SolidBrush(Color.FromArgb(240, 255, 255, 255));
        g.FillRectangle(backBrush, labelX - 3, labelY - 1, size.Width + 6, size.Height + 2);
        g.DrawString(label, labelFont, markerBrush, labelX, labelY);
    }

    /// <summary>鼠标悬停时的十字线和读数。</summary>
    private void DrawHoverCrosshair(Graphics g, Rectangle plot, AScanFrame frame)
    {
        int index = ScreenXToIndex(plot, _hoverX);
        int value = frame.AmplitudeAt(index);

        float x = IndexToScreenX(plot, index);
        float y = ValueToScreenY(plot, value);

        using var crossPen = new Pen(Color.FromArgb(120, 136, 135, 128), 1f)
        {
            DashStyle = DashStyle.Dot
        };

        g.DrawLine(crossPen, x, plot.Top, x, plot.Bottom);
        g.DrawLine(crossPen, plot.Left, y, plot.Right, y);

        using var dotBrush = new SolidBrush(Color.FromArgb(24, 95, 165));
        g.FillEllipse(dotBrush, x - 3f, y - 3f, 6f, 6f);

        // 在控件右上角固定显示读数,跟着鼠标跑容易挡住波形
        string text = $"第 {index} 点 · {AScanFrame.IndexToMm(index):F2} mm · 幅值 {value}";

        using var infoFont = new Font("Microsoft YaHei UI", 8.5F);
        SizeF size = g.MeasureString(text, infoFont);

        using var backBrush = new SolidBrush(Color.FromArgb(235, 241, 239, 232));
        g.FillRectangle(backBrush, plot.Right - size.Width - 12, plot.Top + 6, size.Width + 8, size.Height + 2);
        g.DrawString(text, infoFont, _textBrush, plot.Right - size.Width - 8, plot.Top + 7);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tickFont.Dispose();
            _textBrush.Dispose();
        }

        base.Dispose(disposing);
    }
}
