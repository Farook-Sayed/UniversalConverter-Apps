# Contributing

Thanks for helping. This is a small project, so the rules are short.

## Set up

Install the tools in the [README](README.md), then:

```bash
swift test
./scripts/make-app.sh
```

## Before you open a pull request

1. **Run the tests:** `swift test`. All of them should pass. Tests that need a missing tool skip.
2. **Add a test** for what you changed. Routing and detection are plain functions and easy to test.
3. **If you add a format,** add it in four places: detection (`FileDetection.swift`), the routing tables (`FormatCatalog.swift`), a sample in `scripts/make-test-files.sh`, and the conversion matrix will then cover it. Run the matrix.
4. **If you change the interface,** run `./scripts/snapshot.sh` and look at the pictures in `build/snapshots`, in light and dark mode. Follow [DESIGN.md](DESIGN.md).
5. **No new warnings.** The project builds with none.

## Code style

- Swift 6 with strict concurrency. Types that cross threads are `Sendable`.
- Plain functions for logic, so it can be tested without the app running.
- Comments explain *why*. Names explain *what*.
- Never build shell command strings. Pass arguments as an array to `ProcessRunner`.

## Reporting a problem

Open an issue with the file type, the format you chose, and what the app said. The **Details** popover on a file shows the exact commands that ran.
