import Testing
import UniformTypeIdentifiers
@testable import ZapFastCore

struct DocumentTypeTests {
    @Test func theNameDecidesAsInTheFinder() {
        #expect(DocumentType.of(fileName: "Report.PDF", mime: "application/octet-stream") == .pdf)
        #expect(DocumentType.of(fileName: "Budget.xlsx", mime: "").conforms(to: .spreadsheet))
        #expect(DocumentType.of(fileName: "Letter.docx", mime: "").identifier == "org.openxmlformats.wordprocessingml.document")
    }

    @Test func withoutAKnownExtensionTheMimeTypeDecides() {
        #expect(DocumentType.of(fileName: "scan", mime: "application/pdf") == .pdf)
        #expect(DocumentType.of(fileName: "notes.zzz9", mime: "text/plain") == .plainText)
        #expect(DocumentType.of(fileName: "blob", mime: "") == .data)
    }
}
