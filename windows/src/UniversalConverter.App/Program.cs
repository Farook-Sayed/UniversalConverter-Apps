using System.Runtime.InteropServices;
using Avalonia;
using UniversalConverter.Core;

namespace UniversalConverter.App;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            Converter.RemoveStaleWork();
            ResourcePlan.ApplyPictureThreads();
#if WINDOWS
            ToolLocator.OcrAvailable = WindowsOcr.IsSupported;
            if (ToolLocator.OcrAvailable) Ocr.Engine = new WindowsOcr();
#endif
            if (args.Contains("--selftest")) return SelfTest.Run();
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        catch (Exception ex)
        {
            ReportCrash(ex);
            return 1;
        }
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UsePlatformDetect().WithInterFont().LogToTrace();

    /// <summary>A Windows program has no console, so a failure at start-up would show nothing at all. This saves the
    /// error in the temp folder and, on Windows, says so in a message box.</summary>
    private static void ReportCrash(Exception ex)
    {
        var path = Path.Combine(Path.GetTempPath(), "UniversalConverter-error.txt");
        var text = $"{DateTime.Now}\n{ex}\n";
        try { File.WriteAllText(path, text); } catch { path = "(it could not be saved)"; }
        Console.Error.WriteLine(text);
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return;
        var hint = ex.ToString().Contains("DllNotFoundException") || ex.ToString().Contains("0x8007007E") || ex.ToString().Contains("vcruntime", StringComparison.OrdinalIgnoreCase)
            ? "\n\nA library the program needs is missing. Install the Microsoft Visual C++ Redistributable by running this in a terminal:\nwinget install Microsoft.VCRedist.2015+.x64"
            : "";
        MessageBoxW(IntPtr.Zero, $"Universal Converter could not start.\n\n{ex.GetType().Name}: {ex.Message}{hint}\n\nThe details were saved in:\n{path}", "Universal Converter", 0x10);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
}
