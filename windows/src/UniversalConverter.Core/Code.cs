using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace UniversalConverter.Core;

/// <summary>Splits a long source file into parts the model can handle, and joins the translated parts back together.
/// Cuts happen only between top-level definitions, so each part keeps its functions and classes whole.</summary>
public static class CodeChunker
{
    /// <summary>The most source text sent to the model in one request.</summary>
    public const int PartBytes = 6 * 1024;
    /// <summary>Files up to this size are translated in one request. Larger files are split into parts.</summary>
    public const int WholeFileBytes = 8 * 1024;
    /// <summary>The largest file that is sent back to the model for repair.</summary>
    public const int RepairBytes = 8 * 1024;

    private static int Bytes(string s) => Encoding.UTF8.GetByteCount(s);

    public static List<string> Split(string code, int limit = PartBytes)
    {
        if (Bytes(code) <= limit) return [code];
        var lines = code.Split('\n');

        var sections = new List<List<string>>();
        var current = new List<string>();
        for (int i = 0; i < lines.Length; i++)
        {
            if (IsTopLevelStart(lines, i) && current.Count > 0) { sections.Add(current); current = []; }
            current.Add(lines[i]);
        }
        if (current.Count > 0) sections.Add(current);

        var parts = new List<string>();
        var buffer = new List<string>();
        int bufferBytes = 0;
        foreach (var section in sections)
        {
            int size = Bytes(string.Join('\n', section)) + 1;
            if (size > limit)
            {
                if (buffer.Count > 0) { parts.Add(string.Join('\n', buffer)); buffer = []; bufferBytes = 0; }
                parts.AddRange(CutByLine(section, limit));
                continue;
            }
            if (bufferBytes + size > limit && buffer.Count > 0) { parts.Add(string.Join('\n', buffer)); buffer = []; bufferBytes = 0; }
            buffer.AddRange(section);
            bufferBytes += size;
        }
        if (buffer.Count > 0) parts.Add(string.Join('\n', buffer));
        return parts;
    }

    /// <summary>Joins translated parts. Import lines that appear in more than one part are kept once.</summary>
    public static string Join(IEnumerable<string> parts)
    {
        var seen = new HashSet<string>();
        var output = new List<string>();
        foreach (var part in parts)
        {
            foreach (var line in part.Split('\n'))
            {
                if (IsTopLevelImport(line) && !seen.Add(line.Trim())) continue;
                output.Add(line);
            }
            output.Add("");
        }
        while (output.Count > 0 && output[^1] == "") output.RemoveAt(output.Count - 1);
        return string.Join('\n', output) + "\n";
    }

    public sealed record JavaClass(string ClassName, string Header, List<string> Parts);

    /// <summary>A Java file that holds one class, cut between its members. Null for anything else.</summary>
    public static JavaClass? SplitJavaClass(string code, int limit = PartBytes)
    {
        var lines = code.Split('\n');
        int headerIndex = Array.FindIndex(lines, IsClassHeader);
        if (headerIndex < 0) return null;
        var className = JavaClassName(lines[headerIndex]);
        int closing = Array.FindLastIndex(lines, l => l.Trim().Length > 0);
        if (className is null || closing <= headerIndex || lines[closing].Trim() != "}") return null;
        var body = lines[(headerIndex + 1)..closing];
        // Anything unindented in the body is another top-level declaration, so this is not a single class.
        foreach (var line in body)
            if (line.Length > 0 && !(line.StartsWith(' ') || line.StartsWith('\t') || line.StartsWith("//"))) return null;
        var first = body.FirstOrDefault(l => l.Trim().Length > 0);
        if (first is null) return null;
        var indent = new string(first.TakeWhile(c => c is ' ' or '\t').ToArray());
        if (indent.Length == 0) return null;

        // A member starts at the member indent, after a blank line or the end of the previous member.
        bool StartsMember(int i)
        {
            var line = body[i];
            if (!line.StartsWith(indent) || line.Length <= indent.Length) return false;
            var next = line[indent.Length];
            if (next is ' ' or '\t' or '}') return false;
            if (i == 0) return true;
            var previous = body[i - 1];
            return previous.Trim().Length == 0 || (previous.StartsWith(indent) && previous.Trim() == "}");
        }
        var sections = new List<List<string>>();
        var current = new List<string>();
        for (int i = 0; i < body.Length; i++)
        {
            if (StartsMember(i) && current.Count > 0) { sections.Add(current); current = []; }
            current.Add(body[i]);
        }
        if (current.Count > 0) sections.Add(current);

        var parts = new List<string>();
        var buffer = new List<string>();
        int bytes = 0;
        foreach (var section in sections)
        {
            int size = Bytes(string.Join('\n', section)) + 1;
            // A member is never cut in two. A method longer than the limit becomes a part of its own.
            if (bytes + size > limit && buffer.Count > 0) { parts.Add(string.Join('\n', buffer)); buffer = []; bytes = 0; }
            buffer.AddRange(section);
            bytes += size;
        }
        if (buffer.Count > 0) parts.Add(string.Join('\n', buffer));
        return new JavaClass(className, string.Join('\n', lines[..headerIndex]), parts);
    }

    /// <summary>Joins translated Java members into one class named after the file. Import lines move to the top and are
    /// kept once. A package line is dropped. A class the model wrapped around a part is unwrapped, and a class named
    /// in <paramref name="keeping"/> is one the source really has, so it stays as a static class.</summary>
    public static string JoinJavaClass(IEnumerable<string> parts, string className, ISet<string>? keeping = null)
    {
        keeping ??= new HashSet<string>();
        var imports = new List<string>();
        var seen = new HashSet<string>();
        var members = new List<string>();
        foreach (var part in parts)
        {
            int? nestedDepth = null;
            foreach (var line in part.Split('\n'))
            {
                var trimmed = line.Trim();
                if (nestedDepth is null && IsNestedClassDeclaration(trimmed))
                {
                    var name = JavaClassName(trimmed);
                    if (name is not null && name != className && keeping.Contains(name))
                    {
                        members.Add(StaticClassLine(line));
                        continue;
                    }
                    nestedDepth = BraceDifference(trimmed);
                    continue;
                }
                if (nestedDepth is int depth)
                {
                    var updated = depth + BraceDifference(trimmed);
                    nestedDepth = updated;
                    if (updated <= 0)
                    {
                        nestedDepth = null;
                        if (trimmed.StartsWith('}')) continue;
                    }
                }
                if (trimmed.StartsWith("package ")) continue;
                if (trimmed.StartsWith("import "))
                {
                    if (seen.Add(trimmed)) imports.Add(trimmed);
                    continue;
                }
                bool indented = line.Length == 0 || line.StartsWith(' ') || line.StartsWith('\t');
                members.Add(indented ? line : "    " + line);
            }
            members.Add("");
        }
        while (members.Count > 0 && members[0].Trim().Length == 0) members.RemoveAt(0);
        while (members.Count > 0 && members[^1].Trim().Length == 0) members.RemoveAt(members.Count - 1);
        var output = imports.Count == 0 ? "" : string.Join('\n', imports) + "\n\n";
        return output + $"public class {className} {{\n" + string.Join('\n', members) + "\n}\n";
    }

    private static string StaticClassLine(string line)
    {
        var trimmed = line.Trim();
        var indent = line.StartsWith(' ') || line.StartsWith('\t') ? new string(line.TakeWhile(c => c is ' ' or '\t').ToArray()) : "    ";
        if (JavaTypeWords(trimmed).Contains("static")) return indent + trimmed;
        if (trimmed.StartsWith("class ")) return indent + "static " + trimmed;
        return indent + trimmed.Replace(" class ", " static class ");
    }

    /// <summary>The names of the classes, structs and interfaces a source file defines.</summary>
    public static HashSet<string> TypeNames(string code)
    {
        string[] keywords = ["class", "struct", "interface", "trait"];
        var names = new HashSet<string>();
        foreach (var line in code.Split('\n'))
        {
            var words = line.Split([' ', '\t', '(', ':', '<', '{'], StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0 || words[0].StartsWith("//") || words[0].StartsWith('#') || words[0].StartsWith('*')) continue;
            int index = Array.FindIndex(words, 0, Math.Min(4, words.Length), w => keywords.Contains(w));
            if (index >= 0 && index + 1 < words.Length) names.Add(words[index + 1]);
        }
        return names;
    }

    internal static bool IsNestedClassDeclaration(string trimmed) =>
        trimmed.EndsWith('{') && JavaTypeWords(trimmed).Contains("class") && !trimmed.StartsWith("//");

    internal static int BraceDifference(string line) => line.Count(c => c == '{') - line.Count(c => c == '}');

    internal static bool IsClassHeader(string line)
    {
        if (line.StartsWith(' ') || line.StartsWith('\t') || !line.Contains('{')) return false;
        return JavaTypeWords(line).Any(w => w is "class" or "interface" or "enum" or "record");
    }

    internal static string? JavaClassName(string line)
    {
        var words = JavaTypeWords(line);
        int index = Array.FindIndex(words, w => w is "class" or "interface" or "enum" or "record");
        return index >= 0 && index + 1 < words.Length ? words[index + 1] : null;
    }

    private static string[] JavaTypeWords(string line) => line.Split([' ', '\t', '{'], StringSplitOptions.RemoveEmptyEntries);

    // MARK: Helpers

    /// <summary>A line starts a new top-level definition when it is not indented, comes after a blank line or the end
    /// of a block, and is not itself the end of a block.</summary>
    internal static bool IsTopLevelStart(string[] lines, int index)
    {
        if (index == 0) return false;
        var line = lines[index];
        if (line.Length == 0 || line[0] is ' ' or '\t') return false;
        if (line[0] is '}' or ')' or ']') return false;
        var previous = lines[index - 1];
        bool afterBlank = previous.Trim().Length == 0;
        bool afterClose = previous.StartsWith('}') || previous.StartsWith(')') || previous.StartsWith(']');
        return afterBlank || afterClose;
    }

    internal static bool IsTopLevelImport(string line)
    {
        if (line.Length == 0 || line[0] is ' ' or '\t') return false;
        return new[] { "import ", "from ", "#include", "use ", "using ", "require " }.Any(line.StartsWith);
    }

    private static IEnumerable<string> CutByLine(List<string> lines, int limit)
    {
        var buffer = new List<string>();
        int bytes = 0;
        foreach (var line in lines)
        {
            int size = Bytes(line) + 1;
            if (bytes + size > limit && buffer.Count > 0) { yield return string.Join('\n', buffer); buffer = []; bytes = 0; }
            buffer.Add(line);
            bytes += size;
        }
        if (buffer.Count > 0) yield return string.Join('\n', buffer);
    }
}

/// <summary>The instruction sent to the code model.</summary>
public static class CodePrompt
{
    public static string Make(CodeLanguage source, CodeLanguage target, string code, string className)
    {
        var classRule = target.Id == "java" ? $"The public class must be named {className}." : "";
        return $"""
            You are a source-code translator. Translate the {source.Label} program below into {target.Label}.
            Keep the same behaviour and the same output. Use idiomatic {target.Label}. Where the source uses a third-party library, use the standard library or the closest {target.Label} equivalent. Include every import the code needs. {classRule}
            Return ONLY the {target.Label} source code. No explanations and no markdown code fences.

            {source.Label} source:
            {code}
            """;
    }

    /// <summary>The instruction for one part of a longer file. The model translates only that part.</summary>
    public static string Part(CodeLanguage source, CodeLanguage target, string code, string className, int index, int count)
    {
        var classRule = target.Id == "java"
            ? "Write only the members of the class: its fields and methods. Do not write the class declaration or the package line. Put any import lines the members need first."
            : "";
        return $"""
            You are a source-code translator. This is part {index} of {count} of a longer {source.Label} program. Translate ONLY the code in this part into {target.Label}. Keep the same behaviour and the same output. Keep every name exactly as in the source, because other parts use the same names. Include the imports this part needs. Do not add code that is not in this part. {classRule}
            Return ONLY the {target.Label} source code. No explanations and no markdown code fences.

            {source.Label} source (part {index} of {count}):
            {code}
            """;
    }

    /// <summary>The instruction for one group of members from a Java class. The class declaration is not in the part.</summary>
    public static string Members(CodeLanguage source, CodeLanguage target, string code, string className, string imports, int index, int count)
    {
        var context = imports.Trim();
        var contextBlock = context.Length == 0 ? "" : $"\nThe source file starts with these lines. Do not translate them, they only show which types the code uses:\n{context}\n";
        return $"""
            You are a source-code translator. The code below is part {index} of {count} of the body of a {source.Label} class named {className}: its fields and methods, without the class declaration. Translate ONLY these members into {target.Label}, as top-level functions and variables with no indentation and no surrounding class. Keep every name exactly as in the source, because other parts use the same names. Return ONLY the {target.Label} source code. No explanations and no markdown code fences.
            {contextBlock}
            {source.Label} source (part {index} of {count}):
            {code}
            """;
    }

    /// <summary>Asks the model to fix code that failed the syntax check, using the checker's own messages.</summary>
    public static string Repair(CodeLanguage target, string code, IEnumerable<string> errors, string className)
    {
        var classRule = target.Id == "java" ? $"The public class must be named {className}." : "";
        return $"""
            The {target.Label} code below does not parse or compile. Fix every error and return ONLY the corrected {target.Label} source code. Keep the same behaviour. {classRule}
            No explanations and no markdown code fences.

            Errors reported by the {target.Label} checker:
            {string.Join('\n', errors)}

            Code:
            {code}
            """;
    }
}

/// <summary>Removes markdown fences and surrounding prose that models often add despite instructions.</summary>
public static class CodeOutputCleaner
{
    public static string Clean(string raw)
    {
        var lines = raw.Replace("\r\n", "\n").Split('\n').ToList();
        while (lines.Count > 0 && lines[0].Trim().Length == 0) lines.RemoveAt(0);
        while (lines.Count > 0 && lines[^1].Trim().Length == 0) lines.RemoveAt(lines.Count - 1);
        if (lines.Count > 0 && lines[0].Trim().StartsWith("```")) lines.RemoveAt(0);
        if (lines.Count > 0 && lines[^1].Trim().StartsWith("```")) lines.RemoveAt(lines.Count - 1);
        var body = string.Join('\n', lines);
        return body.Length == 0 ? "" : body + "\n";
    }
}

/// <summary>Talks to a local Ollama server (http://localhost:11434). Nothing leaves the PC.</summary>
public sealed class OllamaClient
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };
    public string BaseUrl { get; }
    public string Model { get; }

    public OllamaClient(string baseUrl = "http://127.0.0.1:11434", string? model = null)
    {
        BaseUrl = baseUrl.TrimEnd('/');
        Model = model ?? CodeModels.DefaultName;
    }

    /// <summary>True when the server answers. Short timeout, so the UI never waits long on a missing server.</summary>
    public async Task<bool> IsRunningAsync(CancellationToken cancellation = default)
    {
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            limit.CancelAfter(TimeSpan.FromSeconds(2));
            using var response = await Http.GetAsync($"{BaseUrl}/api/tags", limit.Token);
            return response.StatusCode == HttpStatusCode.OK;
        }
        catch { return false; }
    }

    /// <summary>Starts `ollama serve` if the server is not answering, then waits for it.</summary>
    public async Task<bool> EnsureRunningAsync(ToolLocator tools, int waitSeconds = 20, CancellationToken cancellation = default)
    {
        if (await IsRunningAsync(cancellation)) return true;
        var binary = tools.Locate("ollama");
        if (binary is null) return false;
        try
        {
            var info = new ProcessStartInfo(binary, "serve") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            info.Environment["PATH"] = ToolLocator.SearchPath();
            Process.Start(info);
        }
        catch { return false; }
        for (int i = 0; i < waitSeconds * 2; i++)
        {
            await Task.Delay(500, cancellation);
            if (await IsRunningAsync(cancellation)) return true;
        }
        return false;
    }

    /// <summary>Runs one non-streaming generation and returns the full text.</summary>
    public async Task<string> GenerateAsync(string prompt, CancellationToken cancellation = default)
    {
        // num_ctx is the context window. The default is too small for a translation prompt plus a part of code.
        var body = JsonSerializer.Serialize(new
        {
            model = Model, prompt, stream = false,
            options = new { temperature = 0.1, num_ctx = 8192 },
        });
        using var content = new StringContent(body, Encoding.UTF8, "application/json");
        using var response = await Http.PostAsync($"{BaseUrl}/api/generate", content, cancellation);
        if (response.StatusCode == HttpStatusCode.NotFound)
            throw ConversionException.OllamaUnavailable($"The model {Model} is not installed. Run: ollama pull {Model}");
        var text = await response.Content.ReadAsStringAsync(cancellation);
        if (response.StatusCode != HttpStatusCode.OK) throw ConversionException.OllamaUnavailable($"The server replied: {text}");
        using var document = JsonDocument.Parse(text);
        return document.RootElement.GetProperty("response").GetString() ?? "";
    }
}

/// <summary>What the syntax check found for a piece of code.</summary>
public abstract record ValidationResult
{
    public sealed record Passed(string Checker) : ValidationResult;
    public sealed record Failed(string Checker, IReadOnlyList<string> Messages) : ValidationResult;
    /// <summary>The checker for this language is not installed or not set up yet.</summary>
    public sealed record NotChecked(string Reason) : ValidationResult;

    public string Summary => this switch
    {
        Passed p => $"passed ({p.Checker})",
        Failed f => $"failed ({f.Checker}): {(f.Messages.Count > 0 ? f.Messages[0] : "errors found")}",
        NotChecked n => $"not checked. {n.Reason}",
        _ => "",
    };
}

/// <summary>Checks that generated code parses, using the language's own parser or compiler.</summary>
public sealed class CodeValidator(ToolLocator tools)
{
    private const string PythonParseScript = "import ast, sys\nast.parse(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1])\n";

    public async Task<ValidationResult> ValidateAsync(string code, CodeLanguage language, string fileName, string workDir,
                                                      CancellationToken cancellation = default)
    {
        var dir = Path.Combine(workDir, "validate-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, fileName);
        await File.WriteAllTextAsync(file, code, new UTF8Encoding(false), cancellation);

        Task<ValidationResult> Run(string label, string[] names, string[] args, string install) =>
            RunAsync(label, names, args, dir, install, cancellation);

        return language.Id switch
        {
            "python" => await Run("Python", ["python3.12", "python3", "python"], ["-c", PythonParseScript, file], "Install it from Tools."),
            "ruby" => await Run("Ruby", ["ruby"], ["-c", file], "Install it with: winget install RubyInstallerTeam.Ruby.3.3"),
            "c" => await Run("clang (C)", ["clang", "gcc"], ["-fsyntax-only", "-x", "c", "-std=c11", file], "Install it with: winget install LLVM.LLVM"),
            "cpp" => await Run("clang (C++)", ["clang", "g++"], ["-fsyntax-only", "-x", "c++", "-std=c++17", file], "Install it with: winget install LLVM.LLVM"),
            "java" => await Run("javac", ["javac"], ["-proc:none", "-d", dir, file], "Install a JDK from Tools."),
            "rust" => await Run("rustc", ["rustc"], ["--edition", "2021", "--crate-type", "lib", "--emit=metadata", "-o", Path.Combine(dir, "check.rmeta"), file], "Install it with: winget install Rustlang.Rustup"),
            "go" => await Run("gofmt", ["gofmt"], ["-e", file], "Install it from Tools."),
            "typescript" => await Run("TypeScript (tsc)", ["tsc"], ["--noEmit", "--target", "ES2020", file], "Install it from Tools."),
            "javascript" => await Run("Node.js", ["node"], ["--check", file], "Install it from Tools."),
            _ => new ValidationResult.NotChecked($"No checker is set up for {language.Label} yet."),
        };
    }

    private async Task<ValidationResult> RunAsync(string label, string[] names, string[] args, string dir, string install,
                                                  CancellationToken cancellation)
    {
        var tool = tools.Locate(names);
        if (tool is null) return new ValidationResult.NotChecked($"{label} is not installed. {install}");
        var result = await ProcessRunner.RunAsync(tool, args, workingDirectory: dir, cancellation: cancellation);
        return result.ExitCode == 0
            ? new ValidationResult.Passed(label)
            : new ValidationResult.Failed(label, ErrorLines(result, dir));
    }

    /// <summary>The error lines from a checker's output, with temporary folder paths removed.</summary>
    public static List<string> ErrorLines(ProcessOutput result, string dir)
    {
        var lines = (result.StdErr + "\n" + result.StdOut).Split('\n')
            .Select(l => l.Replace(dir + Path.DirectorySeparatorChar, "").Trim())
            .Where(l => l.Length > 0).ToList();
        var errors = lines.Where(l => l.Contains("error", StringComparison.OrdinalIgnoreCase) || l.Contains("line ")).ToList();
        return (errors.Count == 0 ? lines.TakeLast(6).ToList() : errors).Take(8).ToList();
    }
}
