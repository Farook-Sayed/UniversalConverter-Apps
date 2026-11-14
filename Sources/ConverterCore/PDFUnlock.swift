import Foundation
import PDFKit

/// How a PDF is protected.
public enum PDFProtection: Equatable, Sendable {
    /// Not encrypted.
    case none
    /// Encrypted, but it opens without a password. It only has restrictions, such as no printing or copying.
    case restricted
    /// A password is needed to open it.
    case needsPassword
}

/// The password was not accepted.
public struct PDFWrongPasswordError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "That password does not open this PDF." }
}

/// Opens password-protected PDFs and writes a copy without protection, with PDFKit, which comes with macOS.
/// Everything happens on this Mac. A password is never guessed: a PDF that needs one stays locked until the user types it.
public enum PDFUnlocker {

    public static func protection(of url: URL) -> PDFProtection {
        guard let document = PDFDocument(url: url) else { return .none }
        if document.isLocked { return .needsPassword }
        return document.isEncrypted ? .restricted : .none
    }

    /// True when the password opens the PDF. An empty password is tried too, for PDFs that only have restrictions.
    public static func accepts(_ password: String, for url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        return !document.isLocked || document.unlock(withPassword: password)
    }

    /// Writes a copy of the PDF without a password or restrictions.
    public static func writeUnlocked(_ url: URL, password: String, to output: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.unsupported("\(url.lastPathComponent) could not be opened as a PDF.")
        }
        if document.isLocked && !document.unlock(withPassword: password) { throw PDFWrongPasswordError() }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        // PDFKit keeps the encryption when it saves an opened document, so the pages are copied into a new one.
        // The pages keep their text, images and drawings. Bookmarks and form fields of the original are not carried over.
        let copy = PDFDocument()
        for number in 0..<document.pageCount {
            guard let page = document.page(at: number)?.copy() as? PDFPage else { continue }
            copy.insert(page, at: copy.pageCount)
        }
        guard copy.pageCount == document.pageCount, copy.write(to: output),
              PDFDocument(url: output)?.isEncrypted == false else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.unsupported("\(url.lastPathComponent) could not be saved without its password.")
        }
    }

    /// What happened when a PDF was opened for the queue.
    public enum Opened: Equatable, Sendable {
        /// Not encrypted. The original is used as it is.
        case notProtected
        /// Opened, and a copy without protection is ready to use.
        case unlocked(copy: URL, password: String?)
        /// A password is needed, and none of the passwords tried fits.
        case needsPassword
    }

    /// Opens a PDF for the queue. A PDF that only has restrictions is opened at once. For a PDF with a password, the
    /// passwords already typed for other files are tried first, so one password can open many files.
    /// The unlocked copy goes in a temporary folder with the same file name as the original.
    public static func open(_ url: URL, trying passwords: [String]) -> Opened {
        switch protection(of: url) {
        case .none:
            return .notProtected
        case .restricted:
            return writeCopy(of: url, password: "") ?? .needsPassword
        case .needsPassword:
            for password in passwords where accepts(password, for: url) {
                if let opened = writeCopy(of: url, password: password) { return opened }
            }
            return .needsPassword
        }
    }

    /// Tries one password. Returns nil when it does not open the PDF.
    public static func open(_ url: URL, password: String) -> Opened? {
        guard accepts(password, for: url) else { return nil }
        return writeCopy(of: url, password: password)
    }

    private static func writeCopy(of url: URL, password: String) -> Opened? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fc-work-unlocked-\(UUID().uuidString)")
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try writeUnlocked(url, password: password, to: copy)
            return .unlocked(copy: copy, password: password.isEmpty ? nil : password)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }
}
