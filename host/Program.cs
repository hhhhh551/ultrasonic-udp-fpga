using System.Windows.Forms;

namespace UltrasoundHost;

/// <summary>
/// 程序入口。
///
/// 这三行是所有 WinForms 程序的固定开头,记住就行:
///   1. 开启视觉样式(让控件是 Windows 原生外观)
///   2. 设置文字渲染方式
///   3. 打开主窗体,进入消息循环
///
/// 第 3 行的 Application.Run 会一直阻塞在这里,
/// 直到用户关掉窗口。你之后写的所有按钮点击、定时器到期,
/// 都是被它内部那个"消息循环"派发调用的。
/// </summary>
internal static class Program
{
    [STAThread]   // WinForms 要求 UI 线程必须是单线程单元(STA),这是硬性规定
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}
