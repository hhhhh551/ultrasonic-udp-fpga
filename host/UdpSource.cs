using System.Net;
using System.Net.Sockets;

namespace UltrasoundHost;

/// <summary>
/// 【通信层】真实的 UDP 接收。
///
/// ══════════════════════════════════════════════════════════
///  先科普:UDP 数据是怎么从 FPGA 流到你程序里的
/// ══════════════════════════════════════════════════════════
///
///   FPGA 的 GMII/RGMII 发出一个以太网帧
///        ↓
///   经过交换机或直连网线,到达 PC 的网卡
///        ↓
///   网卡把帧收下来,检查目的 MAC 是否是本机(或广播),是就交给操作系统
///        ↓
///   操作系统的网络协议栈逐层剥掉:先剥以太网头,再剥 IP 头,再剥 UDP 头
///        ↓
///   剩下 UDP 载荷,放进"该端口的接收队列"
///        ↓
///   你程序里的 ReceiveAsync() 醒来,把这一坨字节交给你
///
/// 所以你在 C# 里拿到的 byte[],已经是"纯载荷"了 ——
/// 以太网头、IP 头、UDP 头都不在里面。你的 1024 字节就是这 1024 字节。
///
/// ══════════════════════════════════════════════════════════
///  UDP 的两个特性,做上位机必须知道
/// ══════════════════════════════════════════════════════════
///
/// 1. UDP 是"无连接"的。你不需要先跟 FPGA 握手,直接 bind 端口就能收。
///    这跟 TCP 完全不一样(TCP 要先三次握手建连)。
///
/// 2. UDP 是"不可靠"的:包可能丢、可能乱序、可能重复。
///    - 乱序/重复:你这套系统里几乎不会发生(直连一根网线)
///    - 丢包:会!PC 忙不过来的时候,操作系统的接收队列满了,新来的包直接被丢弃,
///            而且**不会通知你**。所以下面的 ReceiveBufferSize 调大了。
///
///    这也是为什么你 FPGA 每秒发 1000 个包,上位机可能只收到 990 个。
///    如果你的应用对丢包敏感,正确做法是在 FPGA 里加"帧序号",
///    上位机靠序号跳跃来判断丢了几个 —— 以后可以加上。
/// </summary>
public sealed class UdpSource : IUdpSource
{
    private readonly int _port;

    private UdpClient? _client;
    private CancellationTokenSource? _cts;
    private Task? _pumpTask;
    private bool _disposed;

    public UdpSource(int port)
    {
        _port = port;
    }

    public string Name => $"UDP 监听 :{_port}";

    public bool IsRunning { get; private set; }

    public event Action<byte[]>? DatagramReceived;
    public event Action<string>? Log;

    public void Start()
    {
        if (IsRunning)
        {
            return;
        }

        // 绑定到"本机所有网卡的 6666 端口"。
        // IPAddress.Any = 0.0.0.0,意思是"不管数据从哪块网卡进来我都要"。
        // 这样你插哪根网线都能收到,不用去关心本机 IP 到底是多少 ——
        // 只要它是发往 6666 端口的 UDP 包就行。
        var client = new UdpClient();

        // ReuseAddress:允许多个程序绑同一个端口。
        // 好处是你可以同时开着 Wireshark 或者另一个调试工具一起收包,互不干扰。
        client.Client.SetSocketOption(
            SocketOptionLevel.Socket,
            SocketOptionName.ReuseAddress,
            true);

        // ⚠️ 这一行很关键。默认的 UDP 接收缓冲区只有 8KB 左右,
        // 而你 FPGA 每 1ms 发一个 1KB 的包,也就是 1 秒来 1000KB。
        // 如果界面刷新时程序忙了几十毫秒,队列就会满,后面的包会被内核直接丢掉,
        // 而且丢了你也不知道。把它调到 8MB,足够缓冲突发。
        client.Client.ReceiveBufferSize = 8 * 1024 * 1024;

        try
        {
            client.Client.Bind(new IPEndPoint(IPAddress.Any, _port));
        }
        catch (SocketException ex)
        {
            client.Dispose();
            // 最常见的原因:端口被别的程序占了(比如你已经开了一个本程序没关)。
            throw new InvalidOperationException(
                $"绑定 {_port} 端口失败:{ex.Message}\n\n" +
                $"排查方向:\n" +
                $"  1. 是不是已经开了一个本程序在跑?\n" +
                $"  2. 换个端口试试,或者改 FPGA 那边的目的端口。", ex);
        }

        _client = client;
        _cts = new CancellationTokenSource();
        IsRunning = true;

        // 把接收循环丢到线程池去跑,不占用 UI 线程。
        // 这就是"通信在后台线程"的具体落地。
        _pumpTask = Task.Run(() => ReceiveLoopAsync(client, _cts.Token));

        Log?.Invoke($"已开始监听 UDP 端口 {_port}(接收缓冲 {(client.Client.ReceiveBufferSize / 1024 / 1024)}MB)");
    }

    private async Task ReceiveLoopAsync(UdpClient client, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            UdpReceiveResult result;

            try
            {
                // ⭐ 这一行就是"收包"的全部。
                //    没有数据时,它会把当前线程挂起(await 不占 CPU),
                //    一旦内核队列里来了包,立刻返回,数据在 result.Buffer 里。
                //    这是真正的"事件驱动",不是死循环轮询。
                result = await client.ReceiveAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;   // 用户点了"停止",正常退出
            }
            catch (ObjectDisposedException)
            {
                break;   // 套接字已经被关掉了,正常退出
            }
            catch (SocketException ex)
            {
                // 典型场景:PC 往 FPGA 发过一个包,FPGA 不在,回了 ICMP 端口不可达,
                // Windows 会把这个错误抛给下一次接收调用。这属于正常现象,继续收就行。
                Log?.Invoke($"接收时出现网络错误({ex.SocketErrorCode}),已忽略并继续");
                continue;
            }

            try
            {
                DatagramReceived?.Invoke(result.Buffer);
            }
            catch (Exception ex)
            {
                // 订阅方(解析逻辑)万一抛异常,绝不能让它把这个接收循环打死,
                // 否则后面一个包都收不到了,而且还看不出原因。
                Log?.Invoke($"处理数据包时出错(已忽略):{ex.Message}");
            }
        }

        Log?.Invoke("接收循环已退出");
    }

    public void Stop()
    {
        if (!IsRunning)
        {
            return;
        }

        IsRunning = false;

        // 先取消,让 ReceiveAsync 抛出并退出循环
        _cts?.Cancel();

        // 再关掉套接字,释放端口。两步都要做:
        // 只 Cancel 的话,套接字还占着端口,马上重新开始会报"端口被占用"。
        _client?.Dispose();

        _cts?.Dispose();
        _client = null;
        _cts = null;
        _pumpTask = null;
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
