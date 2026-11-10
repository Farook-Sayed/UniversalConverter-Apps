import XCTest
@testable import ConverterCore

/// Removing a tool group: what is worked out first, what the confirmation says, and the real removal with Homebrew.
final class RemovalTests: XCTestCase {

    private func feature(_ id: String, formulae: [String] = [], casks: [String] = [],
                         extras: [ToolFeature.ExtraStep] = []) -> ToolFeature {
        ToolFeature(id: id, title: id, detail: "", size: "", formulae: formulae, casks: casks, extraSteps: extras,
                    installed: { _ in true })
    }

    func testOnlyWhatHomebrewInstalledIsPlannedForRemoval() {
        let plan = ToolInstaller.removalPlan(
            for: feature("v", formulae: ["ffmpeg", "x264"], casks: ["libreoffice"]),
            brewFormulae: ["ffmpeg", "jq"], brewCasks: [], downloadedModels: [],
            fontEnvironmentExists: false, typeScriptInstalled: false)
        XCTAssertEqual(plan.formulae, ["ffmpeg"])
        XCTAssertEqual(plan.installedElsewhere, ["x264", "libreoffice"], "a program Homebrew does not know is left alone")
        XCTAssertFalse(plan.isEmpty)
    }

    func testAGroupWithNothingFromHomebrewHasNothingToRemove() {
        let plan = ToolInstaller.removalPlan(for: feature("v", formulae: ["ffmpeg"]), brewFormulae: [], brewCasks: [],
                                             downloadedModels: [], fontEnvironmentExists: false, typeScriptInstalled: false)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.installedElsewhere, ["ffmpeg"])
    }

    func testModelsFontToolsAndTypeScriptAreOnlyPartOfTheGroupsThatOwnThem() {
        let code = ToolInstaller.removalPlan(for: feature("code", formulae: ["ollama"], extras: [.codeModel]),
                                             brewFormulae: ["ollama"], brewCasks: [], downloadedModels: ["qwen2.5-coder:7b"],
                                             fontEnvironmentExists: true, typeScriptInstalled: true)
        XCTAssertEqual(code.models, ["qwen2.5-coder:7b"])
        XCTAssertFalse(code.fontEnvironment, "the code group does not own the font tools")
        XCTAssertFalse(code.typeScript)
        let fonts = ToolInstaller.removalPlan(for: feature("fonts", formulae: ["python@3.12"], extras: [.fontEnvironment]),
                                              brewFormulae: ["python@3.12"], brewCasks: [], downloadedModels: ["m"],
                                              fontEnvironmentExists: true, typeScriptInstalled: true)
        XCTAssertTrue(fonts.fontEnvironment)
        XCTAssertTrue(fonts.models.isEmpty, "the font group does not own the models")
        let missingEnvironment = ToolInstaller.removalPlan(for: feature("fonts", extras: [.fontEnvironment]), brewFormulae: [],
                                                           brewCasks: [], downloadedModels: [], fontEnvironmentExists: false,
                                                           typeScriptInstalled: false)
        XCTAssertTrue(missingEnvironment.isEmpty, "nothing to delete when the environment is not there")
    }

    func testTheConfirmationListsWhatGoesAndWarnsAboutSharedTools() {
        let plan = ToolInstaller.removalPlan(
            for: feature("checks", formulae: ["node", "go"], extras: [.typeScript]),
            brewFormulae: ["node"], brewCasks: [], downloadedModels: [], fontEnvironmentExists: false, typeScriptInstalled: true)
        let text = plan.confirmation
        XCTAssertTrue(text.contains("Programs: node"))
        XCTAssertTrue(text.contains("TypeScript"))
        XCTAssertTrue(text.contains("general programming tools"), "Node.js is used by other software")
        XCTAssertTrue(text.contains("Not removed, because Homebrew did not install them: go"))
        XCTAssertTrue(text.contains("install them again"))
        XCTAssertFalse(RemovalPlan(formulae: ["ffmpeg"]).confirmation.contains("general programming tools"))
    }

    func testAnEmptyPlanRemovesNothingAndNeedsNoTools() async throws {
        // No Homebrew is needed when there is nothing for it to remove.
        let steps = Collected()
        let lines = try await ToolInstaller.uninstall(feature("none"), tools: ToolLocator(), plan: RemovalPlan()) { step in
            Task { await steps.add(step) }
        }
        XCTAssertTrue(lines.isEmpty)
    }

    private actor Collected {
        private(set) var items: [String] = []
        func add(_ item: String) { items.append(item) }
    }

    /// The real thing: install a tiny package through the app's installer, remove it through the app's remover, and check
    /// that the program and its cached download are both gone. Only runs when asked: FC_RUN_BREW=1.
    func testARealPackageIsInstalledAndThenRemovedWithItsDownload() async throws {
        guard ProcessInfo.processInfo.environment["FC_RUN_BREW"] == "1" else { throw XCTSkip("Set FC_RUN_BREW=1 to run this with Homebrew") }
        let tools = ToolLocator()
        guard let brew = tools.locate(["brew"]) else { throw XCTSkip("Homebrew is not installed") }
        let listed = try await ProcessRunner.run(brew, arguments: ["list", "--formula", "-1"])
        guard !listed.stdout.split(separator: "\n").contains("tree") else { throw XCTSkip("tree is already installed here") }
        let tree = feature("tree", formulae: ["tree"])

        _ = try await ToolInstaller.install(tree, tools: tools, codeModel: "", coordinator: InstallCoordinator()) { _ in }
        let plan = await ToolInstaller.removalPlan(for: tree, tools: tools)
        XCTAssertEqual(plan.formulae, ["tree"])
        let cache = try await ProcessRunner.run(brew, arguments: ["--cache"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedBefore = try FileManager.default.contentsOfDirectory(atPath: cache + "/downloads").filter { $0.contains("--tree-") }
        XCTAssertFalse(cachedBefore.isEmpty, "the install left a download behind")

        _ = try await ToolInstaller.uninstall(tree, tools: tools, plan: plan, coordinator: InstallCoordinator()) { _ in }
        let after = try await ProcessRunner.run(brew, arguments: ["list", "--formula", "-1"])
        XCTAssertFalse(after.stdout.split(separator: "\n").contains("tree"), "the program is gone")
        let cachedAfter = try FileManager.default.contentsOfDirectory(atPath: cache + "/downloads").filter { $0.contains("--tree-") }
        XCTAssertTrue(cachedAfter.isEmpty, "the downloaded file was deleted too: \(cachedAfter)")
    }

    func testARefusalFromHomebrewReachesTheUser() async throws {
        guard ProcessInfo.processInfo.environment["FC_RUN_BREW"] == "1" else { throw XCTSkip("Set FC_RUN_BREW=1 to run this with Homebrew") }
        let tools = ToolLocator()
        guard tools.locate(["brew"]) != nil else { throw XCTSkip("Homebrew is not installed") }
        // A package Homebrew does not have: the failure must say so rather than disappear.
        let plan = RemovalPlan(formulae: ["no-such-package-for-the-test"])
        do {
            _ = try await ToolInstaller.uninstall(feature("x"), tools: tools, plan: plan) { _ in }
            XCTFail("removing a package that is not there should fail")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("No such keg"), error.localizedDescription)
        }
    }
}
