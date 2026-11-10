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

## 2. Get started

The app works right after you open it. Images, Word and text documents, audio (WAV, M4A) and archives (ZIP, TAR) need nothing else.

For more formats, open **Settings → Tools**. Each group says what it adds and roughly how big it is. Click **Install** next to the ones you want, or **Install everything**. You can start several at once: the app downloads them together, then installs them one after another, because Homebrew cannot install two at the same time. Each row shows its own step, and the status bar at the bottom of the window says how many are running. When an install finishes, a message appears above the file list and the new formats show up in the menus.

If you do not have Homebrew, the Tools tab links to [brew.sh](https://brew.sh). Install it once, then come back.

Code translation downloads a model of about 4.7 GB the first time. It works best with 16 GB of memory.

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
- **Settings** (⌘,): choose a folder for results, choose whether several PDF pages are saved as a folder or a ZIP file, change the Ollama model, turn the syntax-check repair on or off, and check the installed tools.
- **Open With:** you can right-click a file in Finder and choose **Open With → Universal Converter**, or drop files on the Dock icon.
- **Notifications:** when a file finishes while the app is in the background, you get a notification. Turn this off in Settings.
- **Shortcuts and Siri:** the **Convert File** action takes a file and a format, and returns the converted file. It always returns one file, so several PDF pages come back as a ZIP file.

## 4b. Conversions in several steps

Some conversions need two or three tools in a row. For example, Markdown to PDF goes through Word: Pandoc makes a DOCX file, then LibreOffice makes the PDF. The app finds these chains for you. They appear in the format menu with the formats they pass through, such as **PDF document (via DOCX)**.

- Each step uses its own tool, so the tools for every step must be installed. The warnings list them.
- Quality can drop a little at each step. Check the result for anything important.
- The log under **Details** shows each step as it runs.
- A chain never ends in a format of the same kind as the file you started with. For example, a font is not converted to another font through a web font.

## 4c. Making files smaller and adjusting pictures

**PDF:** choose **PDF, smaller file** in the format menu. Original, Low, Medium and High set how far images are reduced. Custom takes a size such as `2 MB`, for a website that sets a limit. Text-only PDFs have little to compress, so the original is kept if the result would not be smaller.

**Pictures:** to keep a picture in its format, choose the entry that ends in **adjusted**, such as **JPEG image, adjusted**. Under each picture, **Adjust…** opens the controls. They apply when the result is PNG, JPEG, HEIC, TIFF, GIF or BMP.

- **Compression:** for JPEG and HEIC, Low keeps the most detail and High makes the smallest file. Custom takes a size such as `500 KB`. The app lowers the quality until the file fits, then makes the picture smaller in pixels if it still does not. PNG, TIFF, GIF and BMP keep every detail, so for these Custom only makes the picture smaller in pixels.
- **Size:** 75%, 50%, 25% or a longest side in pixels. A picture is never made larger.
- **Crop:** drag the box, or one of its corners, over the part to keep. Or choose a shape, such as square, 4:3, 16:9 or 3:4, to crop from the centre. **Reset crop** removes the crop.
- **Remove background:** keeps the main subject and makes the rest transparent. PNG, HEIC, TIFF and GIF stay transparent, and JPEG and BMP get a white background. It works best with a clear subject.
- **Sketch:** a pencil drawing of the picture on white paper.
- **Keep camera and location details:** on by default. Turn it off before sharing a picture publicly, because these details can include where the photo was taken.

The original is never changed. If nothing would improve, the result is an exact copy of the original and the row says so. If you change a setting after converting, the row offers **Convert** again.

## 4d. Reading text from pictures and scans

**Pictures:** choose **Text (OCR)** in the format menu. The app reads the text with Vision, which comes with macOS, so there is nothing to install. The result is a TXT file.

**Scanned PDFs:** choose **Plain text** for the PDF. Pages with a text layer give that text. Pages with no text layer are read as pictures, and the row tells you so. This needs Poppler, because Poppler reads the text layer.

Check the result for mistakes. Printed text reads best. Handwriting and unusual fonts read less well. Columns are kept together, but a table is read column by column, so its rows do not stay lined up.

## 5. What converts to what

| From | To |
|---|---|
| Video (MP4, MKV, WebM, AVI, MOV, WMV, FLV, 3GP, M2TS, MPG, VOB) | MP4, MKV, WebM, AVI, MOV, WMV, FLV, 3GP, GIF, MP3, WAV |
| Subtitles (SRT, VTT, ASS) | The other two subtitle formats |
| Fonts (TTF, OTF, WOFF, WOFF2) | TTF and OTF are converted to WOFF or WOFF2, and back. A TrueType font cannot be saved as OTF, and an OpenType font cannot be saved as TTF. The app says so. |
| Jupyter notebooks (IPYNB) | DOCX, HTML, Markdown, TXT, RTF, EPUB |
| PDF | A smaller PDF (Original, Low, Medium, High, or a size you type), text (TXT), every page as PNG or JPEG, one image per page, Word (DOCX), OpenDocument text (ODT), HTML. Layouts from PDF are approximate. |
| PostScript and EPS | PDF, every page as PNG or JPEG, one image per page |
| 3D models (OBJ, STL, PLY, COLLADA, glTF, GLB) | The other 3D formats |
| E-books (MOBI, AZW3, FB2) | EPUB, MOBI, AZW3, FB2, PDF, DOCX, TXT, HTML |
| EPUB | MOBI, AZW3, FB2 and PDF, in addition to the document formats |
| Audio (MP3, WAV, FLAC, M4A, OGG) | Any other audio format |
| Images (PNG, JPEG, GIF, WebP, BMP, TIFF, AVIF, HEIC) and camera RAW (CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2) | PNG, JPEG, HEIC, GIF, BMP, TIFF and text (OCR) work with nothing to install. WebP, AVIF and PDF need ImageMagick. |
| SVG | PNG, JPEG, PDF |
| Word (DOCX, DOC, ODT, RTF) | PDF, the other word formats, HTML, TXT. DOCX also to Markdown |
| Spreadsheets (XLSX, XLS, ODS, CSV) | PDF, XLSX, ODS, CSV |
| Presentations (PPTX, PPT, ODP) | PDF, PPTX, ODP |
| Markdown, HTML, TXT, EPUB | DOCX, HTML, RTF, TXT, Markdown, EPUB. HTML also to PDF |
| ZIP, 7z, RAR, tar.gz, tar | The other archive formats, except RAR |
| Code (Python, Java, C, C++, Rust, JavaScript, TypeScript, Ruby, Go, C#) | Any other language, translated by the local model |

**Not supported yet:** plain `.gz` files, and RAR as an output.

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

Files up to 8 KB are translated in one go. Larger files are split at their top-level definitions, each part is translated on its own, and the parts are joined. Files over 256 KB are refused. Pick the model in Settings → Code. Larger models are more careful but need more memory, and the list shows how much each one needs.

## 7. Troubleshooting

| Message | What to do |
|---|---|
| "X is not installed" | Install X with the command in section 2, then press **Recheck** in the Tools panel. |
| "has no sound track" | The video has no audio. Choose GIF or a video format instead. |
| "Could not start Ollama" | Open the Ollama app, or run `ollama serve` in Terminal. |
| "fontTools … not installed" | Run the fontTools commands in section 2. |
| "Calibre is not installed" | Install it with: brew install --cask calibre |
| "This font has TrueType outlines…" | The font can be saved as WOFF or WOFF2, but not OTF. |
| "The model … is not installed" | Download the model in Settings → Code. |
| "Syntax check … not checked" | Install that language's tool. The result is still saved. |
| "This file is N KB. The code limit is 256 KB." | Split the file into smaller files. |

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
- Progress shows a percentage for videos, audio, scanned PDFs, translated code parts and custom PDF sizes. A chain of several steps also shows a percentage, in which each finished step counts. Other conversions show a spinner.
- Conversions run side by side: two to four at a time, depending on the processor cores (one for every three cores). Each FFmpeg run gets its share of the cores, so they do not fight over them. Other files wait in the queue.
- Camera RAW depends on macOS supporting the camera. It is tested with a generated DNG file, not with files from each brand.
