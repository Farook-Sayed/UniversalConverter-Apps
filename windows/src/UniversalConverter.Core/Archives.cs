using System.Formats.Tar;
using System.IO.Compression;
using SharpCompress.Archives;
using SharpCompress.Common;
using SharpCompress.Readers;

namespace UniversalConverter.Core;

/// <summary>Reads ZIP, 7z, RAR, tar and tar.gz, and writes ZIP, tar and tar.gz, without any program to install.</summary>
public static class Archives
{
    /// <summary>Unpacks an archive. A link inside it is not written, because following it could copy a file from
    /// anywhere on this PC into the result. The number of links skipped is returned.</summary>
    public static int Extract(string archive, string format, string folder, CancellationToken cancellation)
    {
        int links = 0;
        var root = Path.GetFullPath(folder) + Path.DirectorySeparatorChar;
        void Write(string key, bool isDirectory, Func<Stream> open)
        {
            cancellation.ThrowIfCancellationRequested();
            // An entry named ../x would write outside the folder, so a path that leaves it is refused.
            var destination = Path.GetFullPath(Path.Combine(folder, key.Replace('/', Path.DirectorySeparatorChar)));
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw ConversionException.Unsupported("This archive holds a file with a path that leaves its folder, so it was not opened.");
            if (isDirectory) { Directory.CreateDirectory(destination); return; }
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using var input = open();
            using var output = File.Create(destination);
            input.CopyTo(output);
        }

        if (format is "zip" or "7z" or "rar")
        {
            using var opened = ArchiveFactory.OpenArchive(archive);
            if (opened.IsSolid || format == "7z")
            {
                // A solid archive compresses all its files as one stream. Opening each file on its own would decompress
                // everything before it again, so the whole archive is read once, from start to end.
                using var all = opened.ExtractAllEntries();
                while (all.MoveToNextEntry())
                {
                    var entry = all.Entry;
                    if (entry.Key is null) continue;
                    if (entry.IsEncrypted && !entry.IsDirectory) throw new System.Security.Cryptography.CryptographicException("password");
                    if (entry.LinkTarget is not null) { links++; continue; }
                    Write(entry.Key, entry.IsDirectory, all.OpenEntryStream);
                }
                return links;
            }
            foreach (var entry in opened.Entries)
            {
                if (entry.Key is null) continue;
                if (entry.IsEncrypted && !entry.IsDirectory) throw new System.Security.Cryptography.CryptographicException("password");
                if (entry.LinkTarget is not null) { links++; continue; }
                Write(entry.Key, entry.IsDirectory, entry.OpenEntryStream);
            }
            return links;
        }
        // tar and tar.gz are read as a stream. The reader sees through the gzip layer.
        using var stream = File.OpenRead(archive);
        using var reader = ReaderFactory.OpenReader(stream);
        while (reader.MoveToNextEntry())
        {
            var entry = reader.Entry;
            if (entry.Key is null) continue;
            if (entry.LinkTarget is not null) { links++; continue; }
            Write(entry.Key, entry.IsDirectory, reader.OpenEntryStream);
        }
        return links;
    }

    public static void Pack(string folder, string target, string output)
    {
        switch (target)
        {
            case "zip":
                ZipFile.CreateFromDirectory(folder, output, CompressionLevel.Optimal, false);
                break;
            case "tar":
                TarFile.CreateFromDirectory(folder, output, false);
                break;
            case "targz":
                var tar = output + ".tar";
                TarFile.CreateFromDirectory(folder, tar, false);
                using (var source = File.OpenRead(tar))
                using (var destination = File.Create(output))
                using (var gzip = new GZipStream(destination, CompressionLevel.Optimal))
                    source.CopyTo(gzip);
                File.Delete(tar);
                break;
            default:
                throw ConversionException.Unsupported($"Cannot create a {target} archive.");
        }
    }

    /// <summary>Removes links from an unpacked archive and notes how many. Repacking would follow a link and copy the file
    /// it points to, which may be anywhere on this PC, into the result.</summary>
    public static void DropLinks(string folder, List<string> notes, int alreadySkipped = 0)
    {
        int count = RemoveLinks(folder) + alreadySkipped;
        if (count > 0) notes.Add(count == 1 ? "1 symbolic link was left out of the archive." : $"{count} symbolic links were left out of the archive.");
    }

    public static int RemoveLinks(string folder)
    {
        var links = new List<FileSystemInfo>();
        foreach (var info in new DirectoryInfo(folder).EnumerateFileSystemInfos("*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0 }))
            if (info.LinkTarget is not null || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) links.Add(info);
        foreach (var link in links)
        {
            try { link.Delete(); } catch { /* it is gone or cannot be removed */ }
        }
        return links.Count;
    }
}
