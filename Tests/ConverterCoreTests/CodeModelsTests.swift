import XCTest
import ConverterCore

final class CodeModelsTests: XCTestCase {

    func testCatalogNamesAreUniqueAndIncludeTheDefault() {
        let names = CodeModels.catalog.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.contains(CodeModels.defaultName))
    }

    func testManifestPathSplitsNameAndTag() {
        XCTAssertTrue(CodeModels.manifestURL(for: "qwen2.5-coder:7b").path
            .hasSuffix("library/qwen2.5-coder/7b"))
        XCTAssertTrue(CodeModels.manifestURL(for: "llama3").path
            .hasSuffix("library/llama3/latest"))
    }

    func testEveryModelHasAMemoryFigure() {
        for entry in CodeModels.catalog {
            XCTAssertGreaterThan(entry.memoryGB, 0, entry.name)
        }
    }
}
