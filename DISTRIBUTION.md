# Publishing and distribution

Notes on how Universal Converter can be shared, what Apple and Microsoft require, and what has and has not been done.
This is practical guidance, not legal advice.

## macOS: share it outside the Mac App Store

The app **cannot go on the Mac App Store as it is**, and it should be shared directly instead:

- Mac App Store apps must be sandboxed, and **Guideline 2.4.5** (as I read it) does not let an app download or install other software to add features. Universal Converter's main idea is to run tools that Homebrew installs (FFmpeg, LibreOffice and others), which is exactly that. The app is therefore built **without** the App Sandbox (`ENABLE_APP_SANDBOX: NO` in `project.yml`).
- Direct download is fine for this. Apple only asks that a downloaded app is signed with a **Developer ID** certificate and **notarized**. Then it opens on any Mac without a Gatekeeper block. macOS still asks once, "Are you sure you want to open it?", for an app downloaded from the internet.

**What you need**
1. Membership in the Apple Developer Program. The author is a personal brand, so enrol as an **individual** ($99 a year). The signing certificate comes only with membership.
2. A **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates).
3. An app-specific password and a saved notary login. The steps are at the top of `scripts/sign-and-notarize.sh`.

**Then**
```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/sign-and-notarize.sh
```
This builds with the hardened runtime, sends the app to Apple, staples the result and checks it with `spctl`. The output is `build/Universal Converter.zip`. **The script has not been run yet**, because it needs a paid account. Run it once and fix anything it reports.

**Already set in the project**
| Setting | Value |
|---|---|
| Bundle identifier | `dev.cosmion.converter` (the reverse of cosmion.dev) |
| Hardened runtime | On (needed for notarization) |
| Category | Utilities |
| Encryption declaration | `ITSAppUsesNonExemptEncryption` = false: the app has no encryption of its own |
| Privacy manifest | `Resources/PrivacyInfo.xcprivacy`: no tracking, no data collected, and the three kinds of required-reason API the code uses (user defaults, the modification date of its own temp folders, free disk space) |
| Copyright | © 2026 Farook Sayed, matching `LICENSE` |

Changing the bundle identifier resets the app's saved settings, because they are stored under that name.

**If you ever want a Mac App Store edition**, it would need a different, smaller app: sandboxed, with only the conversions that need no outside tools (pictures, PDF, Word and text, WAV and M4A audio, archives). It would also need an App Privacy answer of "Data Not Collected", the privacy manifest above and a live privacy-policy URL (`PRIVACY.md` can be hosted).

## Windows

- Share `UniversalConverter.exe` from GitHub Releases or a website.
- The file is not signed with a publisher certificate, so Windows SmartScreen warns on first run ("More info → Run anyway"). A code-signing certificate removes the warning, but costs money each year and is not required.
- Nothing like the Mac App Store rules applies to a download. If it is ever put in the Microsoft Store, that needs a separate review.

## Names, brands and screenshots

- The app names the programs it works with (FFmpeg, LibreOffice, Pandoc, Calibre, Ollama, Homebrew, and the operating systems) only to say what it works with. See `THIRD_PARTY_NOTICES.md`: the names belong to their owners, and the app is not affiliated with, endorsed by or sponsored by any of them.
- "Universal Converter" is a descriptive name, and several other products use similar ones. Before putting it on a store, search the store and the trademark register of the countries you sell in.
- The icon is original artwork (`Icon/`), and does not copy another company's logo or style.
- Screenshots in `docs/images` show only sample files made by `scripts/make-test-files.sh`. Keep it that way: do not show films, music or other people's photos in screenshots or demo videos.

## Privacy and law

- The app collects nothing, so it has no privacy-law duties for collected data (for example India's DPDP Act, 2023, or the EU's GDPR). The policy is in `PRIVACY.md`. **Do not add analytics or crash-reporting libraries** without updating the policy, the privacy manifest and the privacy label.
- Network use is limited to the tools you ask it to install and the local code model, as `PRIVACY.md` explains.
- If you charge for the app later, the EU's Digital Services Act makes you a "trader" on Apple's stores, and your name and address are shown on the EU listing.
- The app uses no encryption of its own, so US export rules for encryption do not need a filing.

## Open-source licences and AI-written code

- `LICENSE` is MIT. `THIRD_PARTY_NOTICES.md` lists what each app runs or ships, with licences. The macOS app ships none of the tools it runs. **The Windows app does ship libraries**, and the notices cover them.
- Code written with an AI tool may not be protected by copyright on its own in the US, but the design, the feature choices and the edits a person directs can be. `DESIGN_LOG.md` records those decisions.
