import Foundation

struct QuickFocusImportLine {
    let name: String
    let isDaily: Bool

    static func parse(_ text: String) -> [Self] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Recognize the final word, including common handwritten separators.
            let marker = line.range(of: #"(?:^|\s+(?:[-–—:]\s*)?|\s*\()siempre\)?[.!?,;:…]*$"#,
                                    options: [.regularExpression, .caseInsensitive])
            let name = (marker.map { String(line[..<$0.lowerBound]) } ?? line)
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return Self(name: name, isDaily: marker != nil)
        }
    }
}
