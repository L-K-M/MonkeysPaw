import Foundation

extension AssistantPrompts {
    public static func writeData(brief: String) -> String {
        data(brief, tag: "brief")
    }

    public static func reviewData(source: String) -> String {
        data(source, tag: "prompt")
    }

    public static func improveData(source: String, instruction: String,
                                   selectedFindings: [LlmReview.Finding] = []) -> String {
        let findings = selectedFindings.map {
            "<finding>\n" + [data($0.criterion.rawValue, tag: "criterion"),
                data($0.severity.rawValue, tag: "severity"), data($0.quote, tag: "quote"),
                data($0.problem, tag: "problem"), data($0.suggestion, tag: "suggestion")]
                .joined(separator: "\n") + "\n</finding>"
        }.joined(separator: "\n")
        // Put long source material before the requested edit; tags are trusted
        // literals and all user/provider text is escaped before delimiting it.
        return data(source, tag: "prompt") + "\n<findings>\n" + findings + "\n</findings>\n"
            + data(instruction, tag: "instruction")
    }

    private static func data(_ value: String, tag: String) -> String {
        let escaped = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        return "<\(tag)>\n\(escaped)\n</\(tag)>"
    }
}
