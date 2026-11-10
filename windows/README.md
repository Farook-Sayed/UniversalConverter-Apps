# Universal Converter for Windows

The Windows version of Universal Converter. It does the same job as the Mac app: drop in a file, the app looks inside it to see what it really is, and offers the formats it can become, in up to three steps. Everything runs on your PC. Nothing is uploaded.

It is a C# app (.NET 10, Avalonia) in this folder, `windows/`. The macOS app lives in the rest of the repository.

## Get it

Download `UniversalConverter.exe` and double-click it. It is one file, about 85 MB, and needs nothing else installed, not even .NET. It runs on Windows 10 (version 1903 or later) and Windows 11 on 64-bit PCs, including Arm PCs through Windows' built-in x64 support.

**Windows may say "Windows protected your PC".** The file is not signed with a publisher certificate, which costs money each year, so SmartScreen does not know it. Choose **More info**, then **Run anyway**. Because of the same missing signature, some antivirus programs are cautious about new, unsigned programs.

**If it does not start**, install the Microsoft Visual C++ Redistributable: `winget install Microsoft.VCRedist.2015+.x64`. Some PCs that never installed other software do not have it.

## What works with nothing to install

| | |
|---|---|
| Pictures | PNG, JPEG, WebP, AVIF, GIF, BMP, TIFF, SVG, and PDF output. HEIC and camera RAW can be read. |
| PDF | Text, and every page as PNG or JPEG. |
| Scanned PDFs and pictures | Text is read with Windows' own text recognition (Windows.Media.Ocr). |
| Archives | Read ZIP, 7z, RAR, tar and tar.gz. Write ZIP, tar and tar.gz. |
| 3D models | OBJ, STL, PLY, COLLADA, glTF and GLB. |
| Merging | Several pictures and PDFs into one PDF (A4, Letter or each picture's own size). |
| Picture adjustments | Size, compression to a size you type, a draggable crop box, background removal, sketch, and removing camera and location details. |

## Merging files

When the queue holds two or more files of the same kind, a **Merge…** button appears. It opens a window where you choose the order with the arrows, the format, and the name, and then joins them into one file:

| Files | Result | Needs |
|---|---|---|
| Pictures and PDFs, mixed | One PDF, one page per picture, and every page of each PDF | Nothing to install |
| Audio files | One audio file (MP3, WAV, FLAC, M4A or Ogg), even when the files differ in format or sample rate | FFmpeg |
| Videos | One video (MP4, MKV, WebM or MOV), scaled to the first video's size | FFmpeg |
| Documents (Markdown, text, HTML, Word, OpenDocument, RTF) | One document (Word, Markdown, text, HTML, RTF or EPUB) | Pandoc |

Password-protected PDFs and unreadable pictures stop the merge with a message that names the file. If one video has no sound, the merged video has none, and the app says so. Merging does not change the files in the queue.

## What needs a free program

Open **Settings and tools**, then **Tools**. Each group installs with one click through the Windows Package Manager (winget). Windows may ask you to allow it.

Several tools can be installed at the same time, or all at once with **Install everything**. Windows runs one installer at a time for the whole PC, so the installs take turns, but model downloads, the font tools and TypeScript download while other tools install, and each row shows its own step and percentage.

An installed group has a **Remove…** button. It shows what will be removed, asks you to confirm, and then removes it with winget. A downloaded code model has a **Remove…** button too, in the Code translation tab, and it deletes the model through Ollama. winget removes programs one at a time, so a removal takes its turn with installs. Python, Node.js, Go and Java are general programming tools, so the confirmation warns you before removing them. Programs that winget does not list are left alone.

| Group | Program | Adds |
|---|---|---|
| Video, audio and subtitles | FFmpeg | MP4, MKV, WebM, WMV, FLV, 3GP, MOV, AVI, GIF, MP3, WAV, FLAC, M4A, Ogg, SRT, VTT, ASS |
| Office documents | LibreOffice | PDF from Word, spreadsheets and slides, XLSX, ODS, CSV, PPTX, ODP, PDF to Word |
| Markdown, HTML and EPUB | Pandoc | Markdown, HTML, RTF, EPUB, Jupyter notebooks |
| E-books | Calibre | MOBI, AZW3, FB2 |
| PDF compression, PostScript | Ghostscript | Smaller PDFs (Original, Low, Medium, High, or a size you type), PostScript and EPS |
| 7-Zip archives | 7-Zip | Saving as 7z |
| Fonts | Python and fontTools | TTF, OTF, WOFF, WOFF2 |
| Code translation | Ollama and a model | Translates between Python, Java, C, C++, Rust, JavaScript, TypeScript, Ruby, Go and C# on this PC |
| Code checks | Node.js, Go, a JDK, TypeScript | Checks translated code before it is saved |

## Differences from the Mac app

- **No HEIC output.** HEIC can be opened and converted to other formats, but not written. Windows has no encoder that an app can use without the user installing one.
- **Camera RAW** uses the full-size preview that nearly every camera stores inside the file, not a fresh development of the raw sensor data. It is a good picture, but not the same as developing the RAW in a photo editor.
- **Background removal** uses a small model (U²-Net, built into the app) rather than the Mac's Vision framework. It works best with one clear subject.
- **No Shortcuts action.** The Mac app adds one to Shortcuts. On Windows, files can be given on the command line (`UniversalConverter.exe a.png b.mp4`).
- **Text recognition** reads the languages in Windows Settings under Time and language. Add a language there to read it.

## Build it yourself

You need the .NET 10 SDK. The build works on Windows, macOS and Linux.

```sh
cd windows
./scripts/build-exe.sh          # makes dist/UniversalConverter.exe
dotnet test tests/UniversalConverter.Tests
```

The tests use the sample files that `scripts/make-test-files.sh` makes in the folder above. Tests that need a conversion tool skip themselves when it is not installed. `UC_RUN_MATRIX=1 dotnet test --filter EverySample` converts every sample to every format it is offered.

The same code runs on macOS for development (`dotnet run --project src/UniversalConverter.App`), without Windows' text recognition. Pass `--demo TestFiles --snapshot out` to save pictures of the windows.

## How it is organised

- `src/UniversalConverter.Core` is the library: file detection, the format catalog and routing, the conversion engines, code translation, picture processing, and the checks made before a conversion.
- `src/UniversalConverter.App` is the Avalonia app: the queue, the Adjust panel with its crop box, and Settings and tools. `WindowsOcr.cs` is the only part that is Windows only.
- `tests/UniversalConverter.Tests` holds the tests.

## Known limits

- The Windows runner on GitHub builds the app, runs its tests and starts it (`.github/workflows/windows.yml`). **It has not yet been run on a real Windows PC**, and the interactive parts of the app (drag and drop, the Adjust panel, the merge window) need that test.
- The winget package ids and the Windows install folders were written from documentation and have not been run.
- Code over 256 KB is refused. Longer files are split, translated part by part and joined.
- Translated code is checked for syntax. It is not tested for behaviour.
- Conversions run side by side: two to four at a time, depending on the processor cores (one for every three cores). Each FFmpeg run and each picture conversion gets its share of the cores, so they do not fight over them. Other files wait in the queue.
