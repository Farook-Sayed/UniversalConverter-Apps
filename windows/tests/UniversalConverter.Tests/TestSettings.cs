using System.Runtime.CompilerServices;

namespace UniversalConverter.Tests;

internal static class TestSettings
{
    /// <summary>Runs before any test. The app's settings go to a file of their own, so a test that changes the output folder
    /// never changes the real one.</summary>
    [ModuleInitializer]
    internal static void UseAPrivateSettingsFile() =>
        Environment.SetEnvironmentVariable("UC_SETTINGS_FILE", Path.Combine(Path.GetTempPath(), $"uc-test-settings-{Environment.ProcessId}.json"));
}
