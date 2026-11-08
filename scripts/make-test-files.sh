#!/bin/bash
# Creates one sample file for every input type the converter supports, plus edge cases.
# Output goes to ./TestFiles, grouped by category. Re-running replaces the folder.
set -u

cd "$(dirname "$0")/.."
OUT="TestFiles"
rm -rf "$OUT"
mkdir -p "$OUT"/{video,audio,images,vector,documents,spreadsheets,presentations,markup,code,archives,unknown,mislabelled,edge-cases,subtitles,notebooks,fonts,postscript,models,ebooks}

MAGICK=$(command -v magick || command -v convert)
SOFFICE=$(command -v soffice || echo /Applications/LibreOffice.app/Contents/MacOS/soffice)
PROFILE="file:///tmp/fc-testfiles-profile"
FAILED=()

# Runs a command and records a failure without stopping the script.
step() {
    local label="$1"; shift
    if ! "$@" >/tmp/fc-testfiles.log 2>&1; then
        FAILED+=("$label")
        echo "  ! could not create $label (see /tmp/fc-testfiles.log)"
    fi
}

lo() { "$SOFFICE" --headless --norestore "-env:UserInstallation=$PROFILE" "$@"; }

echo "Creating video..."
step "video/sample.mp4" ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=3:size=320x240:rate=25 -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/video/sample.mp4"
step "video/sample.mkv" ffmpeg -hide_banner -loglevel error -y -i "$OUT/video/sample.mp4" -c copy "$OUT/video/sample.mkv"
step "video/sample.webm" ffmpeg -hide_banner -loglevel error -y -i "$OUT/video/sample.mp4" -c:v libvpx-vp9 -b:v 0 -crf 45 -c:a libopus "$OUT/video/sample.webm"
step "video/sample.avi" ffmpeg -hide_banner -loglevel error -y -i "$OUT/video/sample.mp4" -c:v mpeg4 -q:v 5 -c:a libmp3lame "$OUT/video/sample.avi"
step "video/sample.mov" ffmpeg -hide_banner -loglevel error -y -i "$OUT/video/sample.mp4" -c:v libx264 -c:a aac "$OUT/video/sample.mov"
# A video with no audio track. Converting it to MP3 should give a clear message, not an FFmpeg error.
step "video/silent.mp4" ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=3:size=320x240:rate=25 -c:v libx264 -pix_fmt yuv420p "$OUT/video/silent.mp4"

echo "Creating audio..."
step "audio/sample.mp3" ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=330:duration=3 -c:a libmp3lame "$OUT/audio/sample.mp3"
step "audio/sample.wav" ffmpeg -hide_banner -loglevel error -y -i "$OUT/audio/sample.mp3" -c:a pcm_s16le "$OUT/audio/sample.wav"
step "audio/sample.flac" ffmpeg -hide_banner -loglevel error -y -i "$OUT/audio/sample.mp3" -c:a flac "$OUT/audio/sample.flac"
step "audio/sample.m4a" ffmpeg -hide_banner -loglevel error -y -i "$OUT/audio/sample.mp3" -c:a aac "$OUT/audio/sample.m4a"
step "audio/sample.ogg" ffmpeg -hide_banner -loglevel error -y -i "$OUT/audio/sample.mp3" -c:a libopus "$OUT/audio/sample.ogg"

echo "Creating images..."
# plasma: needs no fonts, which this Mac's ImageMagick does not have.
step "images/sample.png" $MAGICK -size 320x240 plasma:blue-red "$OUT/images/sample.png"
step "images/sample.jpg" $MAGICK "$OUT/images/sample.png" "$OUT/images/sample.jpg"
step "images/sample.gif" $MAGICK "$OUT/images/sample.png" "$OUT/images/sample.gif"
step "images/sample.webp" $MAGICK "$OUT/images/sample.png" "$OUT/images/sample.webp"
step "images/sample.bmp" $MAGICK "$OUT/images/sample.png" "$OUT/images/sample.bmp"
step "images/sample.tiff" $MAGICK "$OUT/images/sample.png" "$OUT/images/sample.tiff"
step "images/sample.avif" $MAGICK "$OUT/images/sample.png" "$OUT/images/sample.avif"
# An animated GIF with two frames. The converter should use only the first frame.
step "images/animated.gif" $MAGICK -size 200x200 xc:red xc:green -delay 50 -loop 0 "$OUT/images/animated.gif"

echo "Creating vector..."
cat > "$OUT/vector/sample.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="160" viewBox="0 0 240 160">
  <rect x="10" y="10" width="220" height="140" rx="16" fill="#3b82f6"/>
  <circle cx="120" cy="80" r="45" fill="#fde047"/>
  <text x="120" y="152" font-size="16" text-anchor="middle" fill="white">SVG sample</text>
</svg>
SVG

echo "Creating documents..."
cat > "$OUT/markup/sample.md" <<'MD'
# Sample Document

This is a **sample** file for testing the converter. It contains a list, a table and a code block.

- First item
- Second item with *emphasis*
- Third item with a [link](https://example.com)

| Name  | Role     |
|-------|----------|
| Ada   | Engineer |
| Grace | Admiral  |

```python
print("code block")
```
MD
step "documents/sample.docx" pandoc "$OUT/markup/sample.md" -o "$OUT/documents/sample.docx"
step "documents/sample.odt" lo --convert-to odt --outdir "$OUT/documents" "$OUT/documents/sample.docx"
step "documents/sample.rtf" lo --convert-to rtf --outdir "$OUT/documents" "$OUT/documents/sample.docx"
step "documents/sample.doc" lo --convert-to doc --outdir "$OUT/documents" "$OUT/documents/sample.docx"
step "documents/sample.pdf" lo --convert-to pdf --outdir "$OUT/documents" "$OUT/documents/sample.docx"

echo "Creating spreadsheets..."
cat > "$OUT/markup/sample.csv" <<'CSV'
name,age,city
Ada,36,London
Grace,85,New York
Linus,54,Helsinki
CSV
cp "$OUT/markup/sample.csv" "$OUT/spreadsheets/sample.csv"
step "spreadsheets/sample.xlsx" lo --convert-to xlsx --outdir "$OUT/spreadsheets" "$OUT/spreadsheets/sample.csv"
step "spreadsheets/sample.xls" lo --convert-to xls --outdir "$OUT/spreadsheets" "$OUT/spreadsheets/sample.xlsx"
step "spreadsheets/sample.ods" lo --convert-to ods --outdir "$OUT/spreadsheets" "$OUT/spreadsheets/sample.xlsx"

echo "Creating presentations..."
step "presentations/sample.pptx" pandoc "$OUT/markup/sample.md" -o "$OUT/presentations/sample.pptx"
step "presentations/sample.ppt" lo --convert-to ppt --outdir "$OUT/presentations" "$OUT/presentations/sample.pptx"
step "presentations/sample.odp" lo --convert-to odp --outdir "$OUT/presentations" "$OUT/presentations/sample.pptx"

echo "Creating markup..."
step "markup/sample.html" pandoc "$OUT/markup/sample.md" --standalone -o "$OUT/markup/sample.html"
step "markup/sample.txt" cp "$OUT/markup/sample.md" "$OUT/markup/sample.txt"
step "markup/sample.epub" pandoc "$OUT/markup/sample.md" -o "$OUT/markup/sample.epub"

echo "Creating code samples..."
cat > "$OUT/code/hello.py" <<'PY'
def greet(name):
    return f"Hello, {name}!"

if __name__ == "__main__":
    print(greet("world"))
PY
cat > "$OUT/code/Hello.java" <<'JAVA'
public class Hello {
    public static void main(String[] args) {
        System.out.println("Hello, world!");
    }
}
JAVA
cat > "$OUT/code/hello.c" <<'C'
#include <stdio.h>

int main(void) {
    printf("Hello, world!\n");
    return 0;
}
C
cat > "$OUT/code/hello.cpp" <<'CPP'
#include <iostream>

int main() {
    std::cout << "Hello, world!" << std::endl;
    return 0;
}
CPP
cat > "$OUT/code/hello.rs" <<'RS'
fn main() {
    println!("Hello, world!");
}
RS
cat > "$OUT/code/hello.js" <<'JS'
function greet(name) {
  return `Hello, ${name}!`;
}
console.log(greet("world"));
JS
cat > "$OUT/code/hello.ts" <<'TS'
const greet = (name: string): string => `Hello, ${name}!`;
console.log(greet("world"));
TS
cat > "$OUT/code/hello.rb" <<'RB'
def greet(name)
  "Hello, #{name}!"
end

puts greet("world")
RB
cat > "$OUT/code/hello.go" <<'GO'
package main

import "fmt"

func main() {
	fmt.Println("Hello, world!")
}
GO
cat > "$OUT/code/hello.cs" <<'CS'
using System;

class Program
{
    static void Main()
    {
        Console.WriteLine("Hello, world!");
    }
}
CS

# A Python file of about 20 KB. It is above the 8 KB whole-file limit, so the code branch splits it into parts.
{
    echo "# Generated file of about 20 KB, translated in parts"
    for i in $(seq 1 450); do
        printf 'def func_%d(x):\n    return x * %d\n\n' "$i" "$i"
    done
} > "$OUT/code/big_script.py"

echo "Creating extra video, subtitle, notebook and font samples..."
SRC_VIDEO="$OUT/video/sample.mp4"
step "video/sample.wmv" ffmpeg -hide_banner -loglevel error -y -i "$SRC_VIDEO" -c:v wmv2 -b:v 2M -c:a wmav2 "$OUT/video/sample.wmv"
step "video/sample.flv" ffmpeg -hide_banner -loglevel error -y -i "$SRC_VIDEO" -c:v libx264 -pix_fmt yuv420p -c:a aac "$OUT/video/sample.flv"
step "video/sample.3gp" ffmpeg -hide_banner -loglevel error -y -i "$SRC_VIDEO" -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 44100 "$OUT/video/sample.3gp"
step "video/sample.m2ts" ffmpeg -hide_banner -loglevel error -y -i "$SRC_VIDEO" -c:v libx264 -c:a aac -f mpegts "$OUT/video/sample.m2ts"
step "video/sample.mpg" ffmpeg -hide_banner -loglevel error -y -i "$SRC_VIDEO" -c:v mpeg2video -c:a mp2 -f mpeg "$OUT/video/sample.mpg"
step "video/sample.vob" ffmpeg -hide_banner -loglevel error -y -i "$SRC_VIDEO" -c:v mpeg2video -c:a mp2 -f vob "$OUT/video/sample.vob"

cat > "$OUT/subtitles/sample.srt" <<'SRT'
1
00:00:00,500 --> 00:00:02,000
Hello, world.

2
00:00:02,500 --> 00:00:04,000
This is a subtitle test.
SRT
cat > "$OUT/subtitles/sample.vtt" <<'VTT'
WEBVTT

00:00:00.500 --> 00:00:02.000
Hello, world.

00:00:02.500 --> 00:00:04.000
This is a subtitle test.
VTT
cat > "$OUT/subtitles/sample.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 384
PlayResY: 288

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,Hello, world.
Dialogue: 0,0:00:02.50,0:00:04.00,Default,,0,0,0,,This is a subtitle test.
ASS

cat > "$OUT/notebooks/sample.ipynb" <<'IPYNB'
{"cells":[{"cell_type":"markdown","metadata":{},"source":["# Notebook sample\n","\n","Some text in a notebook."]},{"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"source":["print('hello')"]}],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"},"language_info":{"name":"python"}},"nbformat":4,"nbformat_minor":5}
IPYNB

# Font samples come from the Mac's own Arial. They are for local testing only and are not shipped.
PY="$HOME/.venvs/converter/bin/python"
[ -x "$PY" ] || PY=$(command -v python3.12)
if [ -f /System/Library/Fonts/Supplemental/Arial.ttf ] && [ -n "$PY" ]; then
    cp /System/Library/Fonts/Supplemental/Arial.ttf "$OUT/fonts/sample.ttf"
    step "fonts/sample.woff" "$PY" -c "from fontTools.ttLib import TTFont; f=TTFont('$OUT/fonts/sample.ttf'); f.flavor='woff'; f.save('$OUT/fonts/sample.woff')"
    step "fonts/sample.woff2" "$PY" -c "from fontTools.ttLib import TTFont; f=TTFont('$OUT/fonts/sample.ttf'); f.flavor='woff2'; f.save('$OUT/fonts/sample.woff2')"
fi
# A PostScript-outline font, if the Mac has one. Apple's own fonts are not shipped.
[ -f "/Library/Fonts/NewYorkExtraLarge-Bold.otf" ] && cp "/Library/Fonts/NewYorkExtraLarge-Bold.otf" "$OUT/fonts/sample.otf"

echo "Creating PostScript, EPS and 3D model samples..."
# PostScript and EPS are made from the sample PDF with Ghostscript.
step "postscript/sample.ps" gs -q -dBATCH -dNOPAUSE -sDEVICE=ps2write -sOutputFile="$OUT/postscript/sample.ps" "$OUT/documents/sample.pdf"
step "postscript/sample.eps" gs -q -dBATCH -dNOPAUSE -sDEVICE=eps2write -sOutputFile="$OUT/postscript/sample.eps" "$OUT/documents/sample.pdf"

cat > "$OUT/models/sample.obj" <<'OBJ'
# A unit cube
v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
f 1 2 3 4
f 5 8 7 6
f 1 5 6 2
f 2 6 7 3
f 3 7 8 4
f 4 8 5 1
OBJ
cat > "$OUT/models/sample.stl" <<'STL'
solid triangle
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 1 0 0
      vertex 0 1 0
    endloop
  endfacet
endsolid triangle
STL
cat > "$OUT/models/sample.ply" <<'PLY'
ply
format ascii 1.0
element vertex 3
property float x
property float y
property float z
element face 1
property list uchar int vertex_indices
end_header
0 0 0
1 0 0
0 1 0
3 0 1 2
PLY
# COLLADA, glTF and GLB are exported from the OBJ with Assimp.
step "models/sample.dae" assimp export "$OUT/models/sample.obj" "$OUT/models/sample.dae" -fcollada
step "models/sample.gltf" assimp export "$OUT/models/sample.obj" "$OUT/models/sample.gltf" -fgltf2
step "models/sample.glb" assimp export "$OUT/models/sample.obj" "$OUT/models/sample.glb" -fglb2

echo "Creating e-book samples..."
# Calibre writes the Kindle and FictionBook samples from the sample EPUB.
EBOOK_CONVERT=/Applications/calibre.app/Contents/MacOS/ebook-convert
if [ -x "$EBOOK_CONVERT" ]; then
    step "ebooks/sample.mobi" env QT_QPA_PLATFORM=offscreen "$EBOOK_CONVERT" "$OUT/markup/sample.epub" "$OUT/ebooks/sample.mobi"
    step "ebooks/sample.azw3" env QT_QPA_PLATFORM=offscreen "$EBOOK_CONVERT" "$OUT/markup/sample.epub" "$OUT/ebooks/sample.azw3"
    step "ebooks/sample.fb2" env QT_QPA_PLATFORM=offscreen "$EBOOK_CONVERT" "$OUT/markup/sample.epub" "$OUT/ebooks/sample.fb2"
fi

echo "Creating archives..."
step "archives/sample.zip" zip -q -j "$OUT/archives/sample.zip" "$OUT/code/hello.py" "$OUT/code/hello.js"
step "archives/sample.7z" 7z a -bd "$OUT/archives/sample.7z" "$OUT/code/hello.py"
step "archives/sample.tar.gz" tar -czf "$OUT/archives/sample.tar.gz" -C "$OUT/code" hello.py

echo "Creating unknown and mislabelled files..."
head -c 2048 /dev/urandom > "$OUT/unknown/mystery.xyz"
cp "$OUT/images/sample.png" "$OUT/mislabelled/photo-that-is-really-png.jpg"
cp "$OUT/documents/sample.docx" "$OUT/mislabelled/report-that-is-really-docx.pdf"

echo "Creating edge cases..."
: > "$OUT/edge-cases/empty.txt"
cp "$OUT/code/hello.py" "$OUT/edge-cases/hello-copy.py"
cp "$OUT/code/hello.py" "$OUT/edge-cases/hello with spaces & symbols.py"

rm -f /tmp/fc-testfiles.log
echo
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "All sample files created in $OUT/"
else
    echo "Created with ${#FAILED[@]} problem(s):"
    printf '  - %s\n' "${FAILED[@]}"
fi
