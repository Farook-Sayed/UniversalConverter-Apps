# Universal Converter: user guide

Universal Converter is a macOS app. Drop a file on it, or choose one, and it offers the formats that file can be converted to. Results are saved next to the original file. Nothing is overwritten: a second conversion becomes `name (2).ext`.

The app reads a file's real contents, so a file with the wrong extension is still identified correctly. It shows a warning when the name and the contents disagree.

## 1. Requirements

| Item | Needed for | Size |
|---|---|---|
| Mac with Apple silicon, macOS 14 or later | Running the app | |
| 16 GB RAM recommended (8 GB minimum) | Code translation, which loads a 4.8 GB model | |
| About 6 GB of disk space | The tools and the code model | |
| Homebrew | Installing the tools below | |

Keep about 10 GB free for conversions. Each conversion needs room for its input and its output.

## 2. Install the tools

Run these in Terminal. Each one is needed only for the formats it converts.

```bash
brew install ffmpeg imagemagick pandoc p7zip ollama poppler ghostscript assimp xcodegen
brew install --cask libreoffice calibre
ollama pull qwen2.5-coder:7b
```

For the code checks, also install the language tools you want checked:

```bash
brew install python@3.12 node go rust
npm install -g typescript
```

C and C++ use clang, which comes with the Xcode command line tools (`xcode-select --install`). Java needs a JDK, for example `brew install openjdk`.

Font conversion needs fontTools in its own Python environment. Run these once:

```bash
python3.12 -m venv ~/.venvs/converter
~/.venvs/converter/bin/pip install fonttools brotli
```

The app's **Tools** panel (at the bottom of the window) shows which tools it found. If one is marked "Not installed", the matching conversions are unavailable.

## 3. Build and open the app

You need Xcode installed (from the App Store). From the `FileConverter` folder in Terminal:

```bash
./scripts/make-app.sh && open "build/Universal Converter.app"
```

The script generates the Xcode project with XcodeGen and builds it with Xcode. Building with Xcode is what registers the Shortcuts action.

The first run may ask you to confirm opening an app from an unidentified developer. Right-click the app, choose **Open**, then confirm.

## 4. Convert a file

1. Drop a file onto the window, or click **Choose File…**.
2. Pick a format in the **Convert to** menu.
3. Click **Convert**.
4. When the result says "Saved", click **Show in Finder** to see the file.

**Details** shows the commands that were run. If a conversion fails, the error appears there in full.

## 4a. Several files, settings and shortcuts

- **Several files:** drop as many as you like. Each file has its own row and its own format. **Convert All** (⇧⌘R) converts every file that has a format chosen.
- **Warnings:** each row can show a note, a caution or a blocked message before you convert. A blocked file cannot be converted until the problem is fixed. For example, a missing tool, an empty file, or a folder the app cannot write to.
- **Cancel:** click **Cancel** on a running conversion. The tool is stopped straight away.
- **Settings** (⌘,): choose a folder for results, change the Ollama model, turn the syntax-check repair on or off, and check the installed tools.
- **Open With:** you can right-click a file in Finder and choose **Open With → Universal Converter**, or drop files on the Dock icon.
- **Notifications:** when a file finishes while the app is in the background, you get a notification. Turn this off in Settings.
- **Shortcuts and Siri:** the **Convert File** action takes a file and a format, and returns the converted file. It appears in Shortcuts once the app is built as an Xcode project (see the note in the project's plan).

## 4b. Conversions in several steps

Some conversions need two or three tools in a row. For example, Markdown to PDF goes through Word: Pandoc makes a DOCX file, then LibreOffice makes the PDF. The app finds these chains for you. They appear in the format menu with the formats they pass through, such as **PDF document (via DOCX)**.

- Each step uses its own tool, so the tools for every step must be installed. The warnings list them.
- Quality can drop a little at each step. Check the result for anything important.
- The log under **Details** shows each step as it runs.
- A chain never ends in a format of the same kind as the file you started with. For example, a font is not converted to another font through a web font.

## 5. What converts to what

| From | To |
|---|---|
| Video (MP4, MKV, WebM, AVI, MOV, WMV, FLV, 3GP, M2TS, MPG, VOB) | MP4, MKV, WebM, AVI, MOV, WMV, FLV, 3GP, GIF, MP3, WAV |
| Subtitles (SRT, VTT, ASS) | The other two subtitle formats |
| Fonts (TTF, OTF, WOFF, WOFF2) | TTF and OTF are converted to WOFF or WOFF2, and back. A TrueType font cannot be saved as OTF, and an OpenType font cannot be saved as TTF. The app says so. |
| Jupyter notebooks (IPYNB) | DOCX, HTML, Markdown, TXT, RTF, EPUB |
| PDF | Text (TXT), the first page as PNG or JPEG, Word (DOCX), OpenDocument text (ODT), HTML. Layouts from PDF are approximate. |
| PostScript and EPS | PDF, the first page as PNG or JPEG |
| 3D models (OBJ, STL, PLY, COLLADA, glTF, GLB) | The other 3D formats |
| E-books (MOBI, AZW3, FB2) | EPUB, MOBI, AZW3, FB2, PDF, DOCX, TXT, HTML |
| EPUB | MOBI, AZW3, FB2 and PDF, in addition to the document formats |
| Audio (MP3, WAV, FLAC, M4A, OGG) | Any other audio format |
| Images (PNG, JPEG, GIF, WebP, BMP, TIFF, AVIF, HEIC) | PNG, JPEG, WebP, GIF, BMP, TIFF, AVIF, HEIC, PDF |
| SVG | PNG, JPEG, PDF |
| Word (DOCX, DOC, ODT, RTF) | PDF, the other word formats, HTML, TXT. DOCX also to Markdown |
| Spreadsheets (XLSX, XLS, ODS, CSV) | PDF, XLSX, ODS, CSV |
| Presentations (PPTX, PPT, ODP) | PDF, PPTX, ODP |
| Markdown, HTML, TXT, EPUB | DOCX, HTML, RTF, TXT, Markdown, EPUB. HTML also to PDF |
| ZIP, 7z, tar.gz, tar | The other archive formats |
| Code (Python, Java, C, C++, Rust, JavaScript, TypeScript, Ruby, Go, C#) | Any other language, translated by the local model |

**Not supported yet:** PDF as input, RAR, Markdown to PDF, and plain `.gz` files.

## 6. The code checks

Translated code is checked with the language's own tools before it is shown to you:

| Language | Checker |
|---|---|
| Python | Python 3.12 parser |
| Ruby | Ruby's syntax check |
| C, C++ | clang |
| Java | javac |
| Rust | rustc |
| Go | gofmt |
| JavaScript | Node.js |
| TypeScript | tsc |
| C# | None yet, so the result says "not checked" |

If the checker finds errors, the app sends them back to the model once and asks for a fix. The file is saved either way. The result line says whether the check passed, failed, or was not available, and **Details** lists the errors.

A passed check means the code parses and compiles. It does not mean the code does the same thing as the original. Always test translated code.

Java class names come from the file name. A name with dashes or spaces is changed to underscores, so `hello-copy.py` becomes `hello_copy.java`.

Source files over 60 KB are refused, because the model cannot read more than that at once.

## 7. Troubleshooting

| Message | What to do |
|---|---|
| "X is not installed" | Install X with the command in section 2, then press **Recheck** in the Tools panel. |
| "has no sound track" | The video has no audio. Choose GIF or a video format instead. |
| "Could not start Ollama" | Open the Ollama app, or run `ollama serve` in Terminal. |
| "fontTools … not installed" | Run the fontTools commands in section 2. |
| "Calibre is not installed" | Install it with: brew install --cask calibre |
| "This font has TrueType outlines…" | The font can be saved as WOFF or WOFF2, but not OTF. |
| "The model … is not installed" | Run `ollama pull qwen2.5-coder:7b`. |
| "Syntax check … not checked" | Install that language's tool. The result is still saved. |
| "This file is N KB. The code model accepts up to 60 KB." | Split the file into smaller files. |

## 8. Run the tests

```bash
swift test
```

The sample files come from a script. To create them, then run every conversion on them:

```bash
./scripts/make-test-files.sh
FC_RUN_MATRIX=1 swift test --filter ConversionMatrixTests
```

The matrix takes several minutes. Its report is `build/matrix-report.txt`.

## 9. Known limits

- The app works only on the Mac it was built on. Sharing it with other people needs signing and notarization.
- Converting large video or images can take a lot of memory. The figures in the requirements are from small test files.
- One file at a time. Dropping several files uses only the first.
- No progress bar or cancel button yet. Long conversions show a spinner.
- The output folder is always the one the original file is in.
