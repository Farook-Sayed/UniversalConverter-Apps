# Third-party notices

Universal Converter is MIT licensed (see [LICENSE](LICENSE)). The macOS and Windows apps differ in what they contain, so this file has two parts.

Each component is licensed by its own authors. These tables are a guide, not legal advice. Check each project for its current licence before you redistribute anything that includes it.

## Programs the apps run (not included in either app)

Both apps run these as separate programs that you install yourself (with Homebrew on macOS, or winget on Windows) and call through their command-line interfaces. The apps do not include or link them. The one exception is the Windows app, which ships ImageMagick and Assimp as libraries instead (see the next section).

| Program | Used for | License (as published by the project) |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) | Video, audio, subtitles | LGPL 2.1+ or GPL 2+, depending on how it is built |
| [ImageMagick](https://imagemagick.org) | Images | ImageMagick License |
| [LibreOffice](https://www.libreoffice.org) | Documents, spreadsheets, slides | MPL 2.0 |
| [Pandoc](https://pandoc.org) | Markdown, HTML, EPUB | GPL 2+ |
| [Calibre](https://calibre-ebook.com) | E-books | GPL 3 |
| [Poppler](https://poppler.freedesktop.org) | PDF text and images | GPL 2+ |
| [Ghostscript](https://ghostscript.com) | PostScript and EPS | AGPL 3, or a commercial license |
| [Assimp](https://github.com/assimp/assimp) | 3D models | BSD 3-Clause |
| [7-Zip](https://www.7-zip.org) | ZIP and 7z archives | LGPL, with restrictions on its RAR code |
| [fontTools](https://github.com/fonttools/fonttools) | Fonts | MIT |
| [Ollama](https://ollama.com) | Runs the code model | MIT |
| Qwen2.5-Coder | The code model the app is set up to use | Apache 2.0 for the 7B model. Check the model card |

If you ship a build of an app together with any of these programs, their licences apply to what you ship.

## Libraries included in the Windows app

`UniversalConverter.exe` is one file that **contains** the libraries below, so their licence terms (mostly to keep the copyright notice and licence text) apply to the file. The macOS app is a separate program and does not contain them.

| Component | Used for | Licence |
|---|---|---|
| [.NET runtime](https://github.com/dotnet/runtime) | Runs the app | MIT |
| [Avalonia](https://avaloniaui.net) (with its Fluent theme) | The windows and controls | MIT |
| [Inter](https://rsms.me/inter/) font, through Avalonia.Fonts.Inter | The app's text | SIL Open Font License 1.1 |
| [SkiaSharp](https://github.com/mono/SkiaSharp), [HarfBuzzSharp](https://github.com/mono/SkiaSharp) | Drawing and text layout | MIT (Skia: BSD 3-Clause; HarfBuzz: MIT) |
| [CommunityToolkit.Mvvm](https://github.com/CommunityToolkit/dotnet) | Application structure | MIT |
| [Magick.NET](https://github.com/dlemstra/Magick.NET) (ImageMagick) | Reading, changing and writing pictures | Apache 2.0 (ImageMagick: ImageMagick licence). It bundles ImageMagick's image libraries, some of which, such as libheif and libde265, are LGPL; see Magick.NET's own notices. |
| [PdfPig](https://github.com/UglyToad/PdfPig) | Reading PDF text, joining PDFs | Apache 2.0 |
| [PDFtoImage](https://github.com/sungaila/PDFtoImage) and [PDFium](https://pdfium.googlesource.com/pdfium/) (PDFium binaries by Benoît Blanchon) | Drawing PDF pages as pictures | MIT (PDFtoImage); Apache 2.0 (PDFium) |
| [SharpCompress](https://github.com/adamhathcock/sharpcompress) | Reading and writing archives | MIT |
| [AssimpNet](https://bitbucket.org/Starnick/assimpnet) and [Assimp](https://github.com/assimp/assimp) | 3D models | MIT (AssimpNet); BSD 3-Clause (Assimp) |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Runs the background-removal model | MIT |
| [U²-Net](https://github.com/xuebinqin/U-2-Net) (the small `u2netp` model) | Removing picture backgrounds | Apache 2.0 |

The Windows app also uses Windows' own text recognition (Windows.Media.Ocr). That is part of Windows and is not included in the app.

## Names and trademarks

FFmpeg, ImageMagick, LibreOffice, Pandoc, Calibre, Poppler, Ghostscript, Assimp, 7-Zip, fontTools, Ollama, Qwen, Homebrew, winget, macOS, Windows, Microsoft and the other names in this file belong to their owners. They are used only to say which programs Universal Converter works with. Universal Converter is an independent project, and is not affiliated with, endorsed by, or sponsored by any of them.
