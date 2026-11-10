import Foundation

/// What removing a tool group would take away. It is worked out before anything is deleted, so the user can see it first.
public struct RemovalPlan: Equatable, Sendable {
    /// Programs Homebrew installed that this group needs.
    public var formulae: [String] = []
    /// Apps Homebrew installed, such as LibreOffice.
    public var casks: [String] = []
    /// Code models that are downloaded, as Ollama names them.
    public var models: [String] = []
    public var fontEnvironment = false
    public var typeScript = false
    /// Programs of this group that Homebrew did not install. The app leaves them alone.
    public var installedElsewhere: [String] = []

    public init(formulae: [String] = [], casks: [String] = [], models: [String] = [], fontEnvironment: Bool = false,
                typeScript: Bool = false, installedElsewhere: [String] = []) {
        self.formulae = formulae
        self.casks = casks
        self.models = models
        self.fontEnvironment = fontEnvironment
        self.typeScript = typeScript
        self.installedElsewhere = installedElsewhere
    }

    public var isEmpty: Bool {
        formulae.isEmpty && casks.isEmpty && models.isEmpty && !fontEnvironment && !typeScript
    }

    /// Programming languages and tools that other software on this Mac may also use.
    public static let generalTools: Set<String> = ["node", "go", "rust", "python@3.12"]
    public var touchesGeneralTools: Bool { !Set(formulae).isDisjoint(with: Self.generalTools) }

    /// What the confirmation says is about to be removed.
    public var items: [String] {
        var lines: [String] = []
        if !formulae.isEmpty { lines.append("Programs: " + formulae.joined(separator: ", ")) }
        if !casks.isEmpty { lines.append("Apps: " + casks.joined(separator: ", ")) }
        if !models.isEmpty { lines.append("Downloaded models: " + models.joined(separator: ", ")) }
        if fontEnvironment { lines.append("The font tools environment") }
        if typeScript { lines.append("TypeScript") }
        return lines
    }

    public var confirmation: String {
        var text = "This removes:\n" + items.map { "• " + $0 }.joined(separator: "\n")
        text += "\n\nIt also removes them for any other program that uses them, including ones you installed yourself. You can install them again from here."
        if touchesGeneralTools {
            text += "\n\nNode.js, Go, Rust and Python are general programming tools, so other software on this Mac may need them."
        }
        if !installedElsewhere.isEmpty {
            text += "\n\nNot removed, because Homebrew did not install them: " + installedElsewhere.joined(separator: ", ") + "."
        }
        return text
    }
}

extension ToolInstaller {

    /// Works out what removing a feature would take away. `brewFormulae` and `brewCasks` are what Homebrew has installed.
    public static func removalPlan(for feature: ToolFeature, brewFormulae: Set<String>, brewCasks: Set<String>,
                                   downloadedModels: [String], fontEnvironmentExists: Bool,
                                   typeScriptInstalled: Bool) -> RemovalPlan {
        var plan = RemovalPlan()
        for formula in feature.formulae {
            if brewFormulae.contains(formula) { plan.formulae.append(formula) } else { plan.installedElsewhere.append(formula) }
        }
        for cask in feature.casks {
            if brewCasks.contains(cask) { plan.casks.append(cask) } else { plan.installedElsewhere.append(cask) }
        }
        if feature.extraSteps.contains(.codeModel) { plan.models = downloadedModels }
        plan.fontEnvironment = feature.extraSteps.contains(.fontEnvironment) && fontEnvironmentExists
        plan.typeScript = feature.extraSteps.contains(.typeScript) && typeScriptInstalled
        return plan
    }

    /// The same, using what is installed on this Mac now.
    public static func removalPlan(for feature: ToolFeature, tools: ToolLocator) async -> RemovalPlan {
        let formulae = await brewNames(tools, ["list", "--formula", "-1"])
        let casks = await brewNames(tools, ["list", "--cask", "-1"])
        return removalPlan(
            for: feature, brewFormulae: formulae, brewCasks: casks,
            downloadedModels: CodeModels.catalog.filter(\.isInstalled).map(\.name),
            fontEnvironmentExists: FileManager.default.fileExists(atPath: ToolFeature.fontEnvironment.path),
            typeScriptInstalled: tools.locate(["tsc"]) != nil)
    }

    private static func brewNames(_ tools: ToolLocator, _ arguments: [String]) async -> Set<String> {
        guard let brew = tools.locate(["brew"]),
              let result = try? await ProcessRunner.run(brew, arguments: arguments, environment: brewEnvironment),
              result.exitCode == 0 else { return [] }
        return Set(result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Removes what the plan lists. Models go first, because Ollama is needed to remove them. Homebrew refuses to remove
    /// a program that another installed program needs, and that message is passed on.
    public static func uninstall(_ feature: ToolFeature, tools: ToolLocator, plan: RemovalPlan,
                                 coordinator: InstallCoordinator = .shared,
                                 progress: @escaping @Sendable (String) -> Void) async throws -> [String] {
        let log = InstallLog()

        if !plan.models.isEmpty {
            for model in plan.models {
                progress("Removing \(model)…")
                try await removeModel(model, tools: tools, log: log)
            }
        }
        if plan.typeScript, let npm = tools.locate(["npm"]) {
            progress("Removing TypeScript…")
            try await run(npm, ["uninstall", "-g", "typescript"], named: "npm", log: log)
        }
        if plan.fontEnvironment {
            progress("Removing the font tools…")
            log.add("removed \(ToolFeature.fontEnvironment.path)")
            try FileManager.default.removeItem(at: ToolFeature.fontEnvironment)
        }
        if !plan.formulae.isEmpty || !plan.casks.isEmpty {
            guard let brew = tools.locate(["brew"]) else {
                throw ConversionError.toolNotFound("Homebrew. It is needed to remove what it installed")
            }
            // Removing changes Homebrew's own folders, so it takes its turn like an install.
            try await coordinator.installs.withSlot(onWait: { progress("Waiting for another install to finish…") }) {
                if !plan.formulae.isEmpty {
                    progress("Removing \(plan.formulae.joined(separator: ", "))…")
                    try await run(brew, ["uninstall", "--formula"] + plan.formulae, named: "Homebrew",
                                  environment: brewEnvironment, log: log)
                }
                if !plan.casks.isEmpty {
                    progress("Removing \(plan.casks.joined(separator: ", "))…")
                    try await run(brew, ["uninstall", "--cask"] + plan.casks, named: "Homebrew",
                                  environment: brewEnvironment, log: log)
                }
                // The downloads stay in Homebrew's cache after an uninstall, and can be hundreds of megabytes.
                progress("Deleting the downloaded files…")
                log.add("Homebrew: brew cleanup --prune=all " + (plan.formulae + plan.casks).joined(separator: " "))
                _ = try? await ProcessRunner.run(brew, arguments: ["cleanup", "--prune=all"] + plan.formulae + plan.casks,
                                                 environment: brewEnvironment)
            }
        }
        return log.lines
    }

    /// Deletes one downloaded code model through Ollama.
    public static func removeModel(_ name: String, tools: ToolLocator) async throws -> [String] {
        let log = InstallLog()
        try await removeModel(name, tools: tools, log: log)
        return log.lines
    }

    private static func removeModel(_ name: String, tools: ToolLocator, log: InstallLog) async throws {
        guard let ollama = tools.locate(["ollama"]) else { throw ConversionError.toolNotFound("Ollama") }
        guard await OllamaClient(model: name).ensureRunning(tools: tools) else {
            throw ConversionError.ollamaUnavailable("Could not start Ollama, which is needed to remove \(name). Open the Ollama app, then try again.")
        }
        try await run(ollama, ["rm", name], named: "Ollama", log: log)
    }
}
