namespace UltrasoundHost;

/// <summary>
/// 【通信层接口】"一个能收到 UDP 包的东西"。
///
/// 和上一个项目里的 ITransport 是同一个套路 ——
/// 定义好"能力",然后给真实实现和仿真实现各写一个类。
///
/// 好处很直接:你的 FPGA 现在还没接网线的时候,
/// 就可以用仿真源把整个上位机调好;等硬件接上,只需换一个下拉框选项。
/// </summary>
public interface IUdpSource : IDisposable
{
    /// <summary>这个名字会显示在界面上,用来确认当前连的是谁。</summary>
    string Name { get; }

    bool IsRunning { get; }

    /// <summary>
    /// 收到一个 UDP 包时触发。参数是"载荷"(已经剥掉了以太网头/IP头/UDP头)。
    ///
    /// ⚠️ 这个事件在后台线程触发。订阅方必须只做"入队",不能碰界面控件。
    /// </summary>
    event Action<byte[]>? DatagramReceived;

    /// <summary>运行过程中的提示信息,同样在后台线程触发。</summary>
    event Action<string>? Log;

    void Start();

    void Stop();
}
