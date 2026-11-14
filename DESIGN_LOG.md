# Universal Converter — design log

A running record of the product and engineering decisions behind the project: what it is for, what it does, and why. It documents the human direction of the work (scope, behaviour, trade-offs, naming and publishing), which is what the project's copyright rests on where code was written with an AI assistant. Keep adding to it.

## Purpose and scope
- A native app that converts files on the user's own computer. Everything is local; nothing is uploaded. Code translation uses a model that runs locally through Ollama.
- The file's contents decide its format, not its name. A conversion may take up to three steps (for example Markdown to PDF through Word), and the app finds the chain and shows it in the format menu.
- Work out of the box, add formats on demand. Pictures, Word and text documents, WAV and M4A audio and archives work with nothing installed. Other formats use a free tool that the user installs from Settings → Tools with one click.
- Two native apps from one idea: SwiftUI for macOS, and C# with Avalonia for Windows. They share behaviour, and differ only where the platforms differ (no HEIC output and no Shortcuts action on Windows; Windows' own text recognition; winget instead of Homebrew).

## Features, in the order they were asked for
- RAR input, a local-model picker, and splitting long files for translation.
- PDF to pictures (a folder or one ZIP), and PDF compression (Original, Low, Medium, High, or a size the user types).
- Picture adjustments: size, compression to a size, a draggable crop box, background removal, sketch, and removing camera and location details; HEIC and camera RAW as input.
- Percentage progress, text from pictures and scanned PDFs, and Java translation that produces one class.
- Several tools installing at once, with downloads in parallel and installs taking turns (two installs that share a dependency collide in Homebrew); a Remove button for every tool and model, with a confirmation first; conversions sized to the processor cores.
- Merging: pictures and PDFs into one PDF, audio into one audio file, videos into one video, and documents into one document, with a window for the order, format and name.

## Decisions and trade-offs
- **Safety first.** Nothing overwrites an existing file. Removing a tool shows what goes and asks first, and warns about general programming tools. A merge stops with a message that names the bad file instead of skipping it.
- **Honest limits.** Translated code is checked for syntax, not behaviour. The Windows app was tested on a Mac and on GitHub's Windows runner, not on a real Windows PC. These are stated in the README.
- **Local first, no analytics.** No analytics, crash reporting or advertising, and no network requests of the app's own. This keeps the privacy policy short and the app outside the privacy-law duties for collected data. Adding any of these needs a policy change first.
- **Distribution.** Direct download, signed with a Developer ID and notarized, not the Mac App Store: the app runs tools that Homebrew installs, which a sandboxed store app may not do. Bundle identifier `dev.cosmion.converter`. The author is a personal brand, so the Apple enrolment is as an individual.
- **Third-party names.** Other programs are named only to say what the app works with, with a disclaimer of affiliation. The Windows app ships libraries, so its licences are listed in `THIRD_PARTY_NOTICES.md`.
- **Screenshots** show only generated sample files, never other people's media.

## Process
- Code was reviewed over several rounds. Every finding was checked against the code and the tests before it was applied or rejected, and each change is covered by tests where it can be.
