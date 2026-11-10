using System.Diagnostics;
using UniversalConverter.Core;

namespace UniversalConverter.App;

/// <summary>Opens folders and files in the system's file manager.</summary>
public static class Shell
{
    public static void Reveal(string path)
    {
        try
        {
            if (ToolLocator.IsWindows)
                Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { Directory.Exists(path) ? path : "/select," + path }, UseShellExecute = false });
            else if (OperatingSystem.IsMacOS())
                Process.Start(new ProcessStartInfo("open") { ArgumentList = { "-R", path }, UseShellExecute = false });
        }
        catch { /* no file manager to show it in */ }
    }

    public static void OpenFolder(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            Process.Start(new ProcessStartInfo(ToolLocator.IsWindows ? "explorer.exe" : "open") { ArgumentList = { folder }, UseShellExecute = false });
        }
        catch { /* no file manager */ }
    }
}
