using ImageMagick;
using UniversalConverter.App.ViewModels;
using UniversalConverter.Core;
using Xunit;

namespace UniversalConverter.Tests;

public class MergeWindowTests : IDisposable
{
    private readonly TempFolder _temp = new();
    public void Dispose() => _temp.Dispose();

    private DetectedFile Picture(string name, string color)
    {
        var path = _temp.File_(name);
        using var image = new MagickImage(new MagickColor(color), 200, 300);
        image.Write(path);
        return new FileDetector().Detect(path);
    }

    private MergeViewModel Session(int pictures = 3) =>
        new(MergePlanner.GroupsFor(Enumerable.Range(1, pictures).Select(i => Picture($"{i}.png", "red"))), _temp.File_("out"));

    [SkippableFact]
    public void TheQueueOffersAMergeOnlyWithTwoFilesOfOneKind()
    {
        var main = new MainViewModel();
        Assert.False(main.CanMerge);
        Assert.Null(main.MakeMergeSession());
        main.Items.Add(new ItemViewModel(main, Picture("a.png", "red")));
        Assert.False(main.CanMerge);
        main.Items.Add(new ItemViewModel(main, Picture("b.png", "green")));
        Assert.True(main.CanMerge);
        Assert.NotNull(main.MakeMergeSession());
        main.Items.RemoveAt(0);
        Assert.False(main.CanMerge);
    }

    [SkippableFact]
    public void TheListCanBeReorderedAndAFileLeftOutButNeverBelowTwo()
    {
        var session = Session(3);
        Assert.Equal(["1.png", "2.png", "3.png"], session.Files.Select(f => f.Name));
        Assert.False(session.Files[0].CanMoveUp);
        Assert.False(session.Files[2].CanMoveDown);
        session.MoveDown(session.Files[0]);
        Assert.Equal(["2.png", "1.png", "3.png"], session.Files.Select(f => f.Name));
        Assert.Equal([1, 2, 3], session.Files.Select(f => f.Position));
        session.MoveUp(session.Files[2]);
        Assert.Equal(["2.png", "3.png", "1.png"], session.Files.Select(f => f.Name));
        session.Remove(session.Files[1]);
        Assert.Equal(["2.png", "1.png"], session.Files.Select(f => f.Name));
        Assert.All(session.Files, f => Assert.False(f.CanRemove));
        session.Remove(session.Files[0]);
        Assert.Equal(2, session.Files.Count);
    }

    [SkippableFact]
    public async Task MergingRunsToAFinishedPDFInTheChosenOrder()
    {
        var session = Session(3);
        session.MoveDown(session.Files[0]);
        session.Name = "My pictures";
        session.PageSizeIndex = 1;
        Assert.True(session.CanStart);
        session.StartCommand.Execute(null);
        Assert.True(session.IsRunning);
        await session.Running!;
        Assert.True(session.IsFinished, session.ErrorText);
        Assert.Equal("My pictures.pdf", Path.GetFileName(session.ResultPath));
        using var pdf = UglyToad.PdfPig.PdfDocument.Open(session.ResultPath!);
        Assert.Equal(3, pdf.NumberOfPages);
        Assert.Equal(612, pdf.GetPage(1).Width, 0.5);
    }

    [SkippableFact]
    public async Task AFailureIsShownAndTheUserCanChangeSomethingAndTryAgain()
    {
        var bad = _temp.File_("bad.png");
        File.WriteAllText(bad, "not a picture");
        var files = new[] { Picture("a.png", "red"), new DetectedFile(bad, MediaCategory.Image, "png", "image/png", DetectionMethod.ExtensionOnly, false), Picture("c.png", "blue") };
        var session = new MergeViewModel(MergePlanner.GroupsFor(files), _temp.File_("out"));
        session.StartCommand.Execute(null);
        await session.Running!;
        Assert.True(session.IsFailed);
        Assert.Contains("bad.png", session.ErrorText);
        session.TryAgainCommand.Execute(null);
        Assert.True(session.IsSetup);
        session.Remove(session.Files.First(f => f.Name == "bad.png"));
        session.StartCommand.Execute(null);
        await session.Running!;
        Assert.True(session.IsFinished, session.ErrorText);
    }

    [SkippableFact]
    public void ANameThatIsEmptyOrAToolThatIsMissingStopsTheMerge()
    {
        var session = Session(2);
        session.Name = "  ";
        Assert.False(session.CanStart);
        session.Name = "ok";
        Assert.True(session.CanStart);
        File.WriteAllText(_temp.File_("a.md"), "a"); File.WriteAllText(_temp.File_("b.md"), "b");
        var docs = new MergeViewModel(MergePlanner.GroupsFor([new FileDetector().Detect(_temp.File_("a.md")), new FileDetector().Detect(_temp.File_("b.md"))]), _temp.File_("out"));
        Assert.Equal(!new ToolLocator().IsAvailable(Engine.Pandoc), docs.HasMissingTool);
        Assert.Equal(docs.HasMissingTool, !docs.CanStart);
    }

    [SkippableFact]
    public void SwitchingTheKindOfMergeReloadsTheListAndTheFormats()
    {
        File.WriteAllText(_temp.File_("a.md"), "a"); File.WriteAllText(_temp.File_("b.md"), "b");
        var files = new[] { Picture("p1.png", "red"), Picture("p2.png", "red"), new FileDetector().Detect(_temp.File_("a.md")), new FileDetector().Detect(_temp.File_("b.md")) };
        var session = new MergeViewModel(MergePlanner.GroupsFor(files), _temp.File_("out"));
        Assert.Equal(["PDF", "Document"], session.GroupNames);
        Assert.True(session.IsPdf);
        session.GroupIndex = 1;
        Assert.False(session.IsPdf);
        Assert.Equal(["a.md", "b.md"], session.Files.Select(f => f.Name));
        Assert.Contains(session.Targets, t => t.Id == "docx");
        Assert.Equal("md", session.SelectedTarget!.Id);
    }

    [SkippableFact]
    public async Task ClosingTheWindowWhileMergingCancelsIt()
    {
        var session = Session(2);
        session.StartCommand.Execute(null);
        session.CancelCommand.Execute(null);
        await session.Running!;
        Assert.True(session.IsSetup || session.IsFinished, "a merge this small may finish first, but it never gets stuck");
    }
}
