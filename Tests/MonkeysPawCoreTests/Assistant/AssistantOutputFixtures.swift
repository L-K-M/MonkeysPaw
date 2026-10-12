import Foundation

enum AssistantOutputFixtures {
    static var option: [String: Any] { ["value": "neutral", "label": "Neutral"] }
    static var field: [String: Any] {
        ["name": "tone", "type": "choice", "label": "Tone", "description": "Voice to use",
         "default": "neutral", "options": [option], "optional": false, "remember": true]
    }
    static var artifact: [String: Any] {
        var context = field
        context["name"] = "context"
        context["type"] = "multiline"
        context["default"] = ""
        context["options"] = []
        return ["title": "Research", "description": "Research a topic", "tags": ["research", "work"],
                "fields": [field, context], "body": "<context>{{ context }}</context>\nUse {{tone}}.",
                "notes": "Explain the context and preserve the tone."]
    }
    static var finding: [String: Any] {
        ["severity": "medium", "criterion": "verifiability", "quote": "Use sources.",
         "problem": "The source requirements are vague.", "suggestion": "Request primary sources."]
    }
    static var review: [String: Any] { ["summary": "Clarify sources.", "findings": [finding]] }

    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func artifactReplacing(_ object: [String: Any], layer: Int) -> [String: Any] {
        if layer == 0 { return object }
        var root = artifact
        var fields = root["fields"] as! [[String: Any]]
        if layer == 1 { fields[0] = object }
        else { fields[0]["options"] = [object] }
        root["fields"] = fields
        return root
    }

    static func reviewReplacing(_ object: [String: Any], layer: Int) -> [String: Any] {
        if layer == 0 { return object }
        var root = review
        root["findings"] = [object]
        return root
    }

    static func wrongTypes(for key: String) -> [Any] {
        switch key {
        case "optional", "remember": return [NSNull(), 0, 1, "true", [], [:]]
        case "tags", "fields", "options", "findings": return [NSNull(), false, 1, "array", [:], [NSNull()]]
        default: return [NSNull(), false, 1, [], [:]]
        }
    }
}
