using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using UniversalConverter.App.ViewModels;

namespace UniversalConverter.App.Views;

/// <summary>
/// Asks for the password of the PDFs in the list that have one. One password is tried on all of them, so files that share
/// a password need it only once. Nothing is stored: the password is kept in memory until the app quits.
/// </summary>
public sealed class PasswordWindow : Window
{
    public PasswordWindow(MainViewModel model)
    {
        Title = "Password";
        Width = 460;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var names = model.Items.Where(i => i.NeedsPassword).Select(i => i.Name).ToList();
        var heading = new TextBlock
        {
            Text = names.Count == 1 ? "This PDF has a password" : $"{names.Count} PDFs have a password",
            FontSize = 17, FontWeight = FontWeight.SemiBold,
        };
        var explanation = new TextBlock
        {
            Text = "Enter it to open them. If several files share one password, you only type it once.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75,
        };
        var list = new TextBlock
        {
            Text = string.Join("\n", names.Take(5).Select(n => "📄 " + n)) + (names.Count > 5 ? $"\nand {names.Count - 5} more" : ""),
            FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var box = new TextBox { PasswordChar = '•', Watermark = "Password" };
        Avalonia.Automation.AutomationProperties.SetName(box, "PDF password");
        var message = new TextBlock { Foreground = Brushes.DarkOrange, TextWrapping = TextWrapping.Wrap, FontSize = 12, IsVisible = false };
        var privacy = new TextBlock
        {
            Text = "The file is opened on this PC. The password is not saved or sent anywhere. The original file is not changed.",
            TextWrapping = TextWrapping.Wrap, FontSize = 11, Opacity = 0.65,
        };
        var open = new Button { Content = "Open", MinWidth = 100, HorizontalContentAlignment = HorizontalAlignment.Center };
        open.Classes.Add("accent");
        var later = new Button { Content = "Not now", MinWidth = 100, HorizontalContentAlignment = HorizontalAlignment.Center, IsCancel = true };
        later.Click += (_, _) => Close();

        async Task Unlock()
        {
            var password = box.Text ?? "";
            if (password.Length == 0) return;
            open.IsEnabled = box.IsEnabled = false;
            var (opened, waiting) = await model.UnlockPdfsAsync(password);
            open.IsEnabled = box.IsEnabled = true;
            box.Text = "";
            var remaining = model.LockedCount;
            if (remaining == 0) { Close(); return; }
            message.IsVisible = true;
            message.Text = opened == 0
                ? (remaining == 1 ? "That password does not open this PDF." : "That password does not open these PDFs.")
                : $"That password opened {opened} of {waiting}. Enter the password for the other {remaining}.";
            list.Text = string.Join("\n", model.Items.Where(i => i.NeedsPassword).Take(5).Select(i => "📄 " + i.Name));
            heading.Text = remaining == 1 ? "This PDF has a password" : $"{remaining} PDFs have a password";
            box.Focus();
        }
        open.Click += async (_, _) => await Unlock();
        box.KeyDown += async (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { e.Handled = true; await Unlock(); } };
        Opened += (_, _) => box.Focus();

        Content = new StackPanel
        {
            Margin = new Thickness(24, 20), Spacing = 12,
            Children =
            {
                heading, explanation, list, box, message, privacy,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { later, open } },
            },
        };
    }
}
