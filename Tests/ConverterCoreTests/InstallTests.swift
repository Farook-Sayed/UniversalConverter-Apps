import XCTest
@testable import ConverterCore

/// How tools are installed: downloads at the same time, installs one after another, and work sized to the processor.
final class InstallTests: XCTestCase {

    /// Counts how many tasks are inside a section at once, and the most there ever were.
    private actor Gauge {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    func testASemaphoreNeverAllowsMoreTasksThanItHasSlots() async throws {
        let semaphore = AsyncSemaphore(3)
        let gauge = Gauge()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await semaphore.withSlot {
                        await gauge.enter()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await gauge.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await gauge.peak
        XCTAssertEqual(peak, 3, "all three slots should be used, and never a fourth")
    }

    func testASlotIsGivenBackWhenTheWorkFails() async throws {
        let semaphore = AsyncSemaphore(1)
        struct Boom: Error {}
        do {
            try await semaphore.withSlot { throw Boom() }
            XCTFail("the error should come out")
        } catch is Boom {}
        // The only slot must be free again, or this would wait forever.
        try await semaphore.withSlot { }
    }

    func testATaskCancelledWhileWaitingStopsWaitingAndLeaksNoSlot() async throws {
        let semaphore = AsyncSemaphore(1)
        try await semaphore.acquire()
        let waiter = Task { try await semaphore.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled wait should throw")
        } catch is CancellationError {}
        await semaphore.release()
        // The slot went back to the pool, not to the cancelled task.
        try await semaphore.withSlot { }
    }

    func testWaitersAreServedInTheOrderTheyArrived() async throws {
        let semaphore = AsyncSemaphore(1)
        try await semaphore.acquire()
        let order = OrderLog()
        var tasks: [Task<Void, Error>] = []
        for number in 1...4 {
            tasks.append(Task {
                try await semaphore.withSlot { await order.add(number) }
            })
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await semaphore.release()
        for task in tasks { try await task.value }
        let seen = await order.items
        XCTAssertEqual(seen, [1, 2, 3, 4])
    }

    private actor OrderLog {
        private(set) var items: [Int] = []
        func add(_ number: Int) { items.append(number) }
    }

    /// Six features: all of them download at the same time (up to four at once), and no two ever install together.
    func testDownloadsOverlapButInstallsTakeTurns() async throws {
        let coordinator = InstallCoordinator()
        let downloads = Gauge(), installs = Gauge()
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await coordinator.downloads.withSlot {
                        await downloads.enter()
                        try await Task.sleep(nanoseconds: 150_000_000)
                        await downloads.leave()
                    }
                    try await coordinator.installs.withSlot {
                        await installs.enter()
                        try await Task.sleep(nanoseconds: 30_000_000)
                        await installs.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let downloadPeak = await downloads.peak, installPeak = await installs.peak
        XCTAssertEqual(downloadPeak, ResourcePlan.parallelDownloads)
        XCTAssertEqual(installPeak, 1, "two installs at once collide when they share a dependency")
        // One after another this would take 6 x 180 ms. Overlapping the downloads is clearly faster.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
    }

    func testTheInstallerReportsThatItIsWaitingForAnotherInstall() async throws {
        let semaphore = AsyncSemaphore(1)
        try await semaphore.acquire()
        let told = OrderLog()
        let task = Task {
            try await semaphore.withSlot(onWait: { Task { await told.add(1) } }, { })
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeRelease = await told.items
        XCTAssertEqual(beforeRelease, [1], "the waiting caller is told while it waits")
        await semaphore.release()
        try await task.value
    }


    func testTheDryRunReportBecomesAListOfPackages() {
        let report = """
        ==> Would install 2 formulae:
        pandoc   3.13
        poppler  26.11.0
        ==> Downloading https://ghcr.io/v2/homebrew/core/pandoc/manifests/3.13
        ==> Would install 1 dependency for pandoc:
        gmp 6.3.0
        ==> Downloading https://ghcr.io/v2/homebrew/core/poppler/manifests/26.11.0
        Already downloaded: /Users/x/Library/Caches/Homebrew/downloads/4afa--poppler-26.11.0.bottle_manifest.json
        ==> Would install 3 dependencies for poppler:
        json-c        0.19
        gmp           6.3.0
        openjpeg      2.5.4_1
        """
        XCTAssertEqual(ToolInstaller.packageNames(fromDryRun: report),
                       ["pandoc", "poppler", "gmp", "json-c", "openjpeg"], "each package once, in order, with no download lines")
        XCTAssertEqual(ToolInstaller.packageNames(fromDryRun: "==> Would install 1 cask:\ncalibre\n"), ["calibre"])
        XCTAssertEqual(ToolInstaller.packageNames(fromDryRun: ""), [])
        XCTAssertEqual(ToolInstaller.packageNames(fromDryRun: "Error: No available formula\n"), [])
    }

    private actor Fetched {
        private(set) var batches: [[String]] = []
        func add(_ batch: [String]) { batches.append(batch) }
    }

    func testTheLedgerSplitsAFeatureIntoBatchesAndFetchesEachPackageOnce() async {
        let ledger = DownloadLedger()
        let fetched = Fetched()
        let names = (1...10).map { "pkg\($0)" }
        let first = await ledger.reserve(names, groups: 4, kind: "formula") { batch in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await fetched.add(batch)
        }
        XCTAssertEqual(first.count, 4, "ten packages are dealt into four batches that download side by side")
        // A second feature that needs three of the same packages and one more.
        let second = await ledger.reserve(["pkg2", "pkg3", "pkg4", "other"], groups: 4, kind: "formula") { batch in
            await fetched.add(batch)
        }
        for task in first + second { await task.value }
        let all = await fetched.batches.flatMap { $0 }
        XCTAssertEqual(all.sorted(), (names + ["other"]).sorted(), "nothing is downloaded twice")
        XCTAssertGreaterThanOrEqual(second.count, 4, "the second feature also waits for the packages the first one started")
    }

    func testAFormulaAndACaskWithTheSameNameAreKeptApart() async {
        let ledger = DownloadLedger()
        let fetched = Fetched()
        let formula = await ledger.reserve(["calibre"], groups: 1, kind: "formula") { await fetched.add($0) }
        let cask = await ledger.reserve(["calibre"], groups: 1, kind: "cask") { await fetched.add($0) }
        for task in formula + cask { await task.value }
        let count = await fetched.batches.count
        XCTAssertEqual(count, 2)
    }

    func testWorkIsSizedToTheProcessorCores() {
        XCTAssertEqual(ResourcePlan.parallelConversions(cores: 2), 2, "two always run, so files and processor overlap")
        XCTAssertEqual(ResourcePlan.parallelConversions(cores: 8), 2)
        XCTAssertEqual(ResourcePlan.parallelConversions(cores: 10), 3)
        XCTAssertEqual(ResourcePlan.parallelConversions(cores: 16), 4)
        XCTAssertEqual(ResourcePlan.parallelConversions(cores: 64), 4, "more than four only competes for the same disk")
        XCTAssertEqual(ResourcePlan.threadsPerConversion(cores: 8, parallel: 2), 4)
        XCTAssertEqual(ResourcePlan.threadsPerConversion(cores: 16, parallel: 4), 4)
        XCTAssertEqual(ResourcePlan.threadsPerConversion(cores: 2, parallel: 4), 2, "a conversion never gets fewer than two threads")
        XCTAssertGreaterThanOrEqual(ResourcePlan.parallelConversions(), 2)
    }

    func testHomebrewIsToldNotToDoSlowExtraWork() {
        let environment = ToolInstaller.brewEnvironment
        XCTAssertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
        XCTAssertEqual(environment["HOMEBREW_NO_INSTALL_UPGRADE"], "1")
    }

    func testBrewOutputBecomesAShortStep() {
        XCTAssertEqual(ToolInstaller.step(fromBrewLine: "==> Pouring ffmpeg--8.1.1.arm64_tahoe.bottle.tar.gz"), "Installing ffmpeg…")
        XCTAssertNil(ToolInstaller.step(fromBrewLine: "==> Downloading https://ghcr.io/v2/homebrew/core/ffmpeg"))
        XCTAssertNil(ToolInstaller.step(fromBrewLine: "🍺  /opt/homebrew/Cellar/ffmpeg/8.1.1: 300 files, 40MB"))
    }

    func testFFmpegGetsItsShareOfTheCores() async throws {
        // The options helper is shared, so the thread count must not leak into it.
        XCTAssertFalse(Converter.ffmpegOptions(for: "mp4").contains("-threads"))
    }

    /// The real thing. Two features that share a dependency are installed at the same moment with Homebrew. Without the
    /// turn-taking this fails with "Bottle destination already exists". It installs and removes two tiny packages, so it
    /// only runs when asked: FC_RUN_BREW=1.
    func testTwoFeaturesThatShareADependencyInstallTogether() async throws {
        guard ProcessInfo.processInfo.environment["FC_RUN_BREW"] == "1" else { throw XCTSkip("Set FC_RUN_BREW=1 to run this with Homebrew") }
        let tools = ToolLocator()
        guard let brew = tools.locate(["brew"]) else { throw XCTSkip("Homebrew is not installed") }
        let listed = try await ProcessRunner.run(brew, arguments: ["list", "--formula"])
        let installed = Set(listed.stdout.split(separator: "\n").map(String.init))
        guard installed.isDisjoint(with: ["jq", "oniguruma"]) else { throw XCTSkip("jq or oniguruma is already installed here") }
        defer { Task { _ = try? await ProcessRunner.run(brew, arguments: ["uninstall", "--formula", "jq", "oniguruma"]) } }

        let jq = ToolFeature(id: "t1", title: "jq", detail: "", size: "", formulae: ["jq"], installed: { _ in false })
        let onig = ToolFeature(id: "t2", title: "onig", detail: "", size: "", formulae: ["oniguruma"], installed: { _ in false })
        let coordinator = InstallCoordinator()
        let steps = OrderLog()
        async let first = ToolInstaller.install(jq, tools: tools, codeModel: "", coordinator: coordinator) { _ in Task { await steps.add(1) } }
        async let second = ToolInstaller.install(onig, tools: tools, codeModel: "", coordinator: coordinator) { _ in Task { await steps.add(2) } }
        _ = try await (first, second)
        let after = try await ProcessRunner.run(brew, arguments: ["list", "--formula"])
        XCTAssertTrue(after.stdout.contains("jq"))
        XCTAssertTrue(after.stdout.contains("oniguruma"))
    }
}
