# Privacy policy

*Last updated: 14 November 2026*

Universal Converter is an app for macOS and Windows that converts files on your own computer.

## What we collect

**Nothing.** The app has no accounts, no analytics, no advertising and no crash reporting, and it does not send your files, your file names or anything about your computer to the author or to anyone else. There is no server that belongs to this app.

## What stays on your computer

- **Your files.** They are read from where you keep them, converted on your computer, and the result is saved in the output folder you choose. Temporary work files are deleted when a conversion ends, and any an earlier run left behind (for example after a crash) are deleted after 24 hours.
- **PDF passwords.** A password you type for a PDF is used to open it on your computer and kept in memory only until you quit the app. It is never saved or sent. The app never tries to guess a password. The unlocked copy it works from is a temporary file that is deleted when you remove the file from the list.
- **Your settings** (the output folder, the chosen code model and a few switches) are saved on your computer: in the macOS user defaults, or in `%APPDATA%\Universal Converter\settings.json` on Windows.
- **Text recognition** is done by your computer's own system (Vision on macOS, Windows' built-in recognition on Windows). Nothing is uploaded.
- **Code translation** uses a model that runs on your computer through [Ollama](https://ollama.com). The app talks to Ollama only at `localhost`.

## When the app uses the network

The app makes no network requests of its own. It starts other programs when you ask it to, and those programs may use the network under their own privacy policies:

- **Installing tools.** When you click **Install** in the Tools list, the app runs Homebrew (macOS) or winget (Windows), which download the tool from their sources. Some tools need a helper: the Fonts feature uses pip (Python packages) and the Code checks use npm (TypeScript), so those also download from their own sources. The app tells Homebrew not to send its usage analytics. Removing a tool deletes it again.
- **Downloading a code model.** The app runs `ollama pull`, which downloads the model from Ollama's registry.
- **Opening a link.** "Get Homebrew" opens a web page in your browser.

## Permissions

- **Files.** The app opens the files you drop on it or choose, and writes into your output folder. On macOS it is not sandboxed, so that it can run the tools you installed.
- **Notifications** (macOS, optional). To tell you when a conversion finishes while the app is in the background.

## Children

The app collects no data from anyone, including children.

## Changes

If this policy changes, the new version will be posted here with an updated date.

## Contact

Open an issue at <https://github.com/Farook-Sayed/UniversalConverter-Apps/issues>.
