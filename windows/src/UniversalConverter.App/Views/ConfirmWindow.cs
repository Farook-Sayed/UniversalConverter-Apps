using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace UniversalConverter.App.Views;

/// <summary>A small question with two buttons. Avalonia has no built-in message box.</summary>
public sealed class ConfirmWindow : Window
{
    public bool Answer { get; private set; }

    public ConfirmWindow(string title, string message, string yes, string no)
    {
        Title = title;
        Width = 440;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var ok = new Button { Content = yes, MinWidth = 100, HorizontalContentAlignment = HorizontalAlignment.Center };
        ok.Classes.Add("accent");
        var cancel = new Button { Content = no, MinWidth = 100, HorizontalContentAlignment = HorizontalAlignment.Center };
        ok.Click += (_, _) => { Answer = true; Close(); };
        cancel.Click += (_, _) => Close();
        Content = new StackPanel
        {
            Margin = new Thickness(24, 20), Spacing = 18,
            Children =
            {
                new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, ok } },
            },
        };
    }

    public static async Task<bool> AskAsync(Window owner, string title, string message, string yes, string no)
    {
        var window = new ConfirmWindow(title, message, yes, no);
        await window.ShowDialog(owner);
        return window.Answer;
    }
}
