#!/bin/sh
# Builds the Windows app as one self-contained .exe. It runs on macOS, Linux or Windows (Git Bash) with the .NET 10 SDK.
# The result is windows/dist/UniversalConverter.exe. It needs nothing installed on the PC, not even .NET.
set -e
cd "$(dirname "$0")/.."
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
RID="${1:-win-x64}"
OUT="dist/$RID"
rm -rf "$OUT"
dotnet publish src/UniversalConverter.App -c Release -r "$RID" --self-contained \
  -p:WindowsBuild=true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o "$OUT"
# Only the program is needed. The rest are import libraries and symbols from the native packages.
find "$OUT" -type f ! -name 'UniversalConverter.exe' -delete
cp "$OUT/UniversalConverter.exe" dist/UniversalConverter.exe
ls -lh dist/UniversalConverter.exe
