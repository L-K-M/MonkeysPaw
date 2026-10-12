import Foundation

enum AssistantModelList {
    static func validID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func url(for connection: ProviderConnection, afterID: String?) throws -> URL {
        guard let afterID else { return connection.modelsURL }
        guard validID(afterID),
              var components = URLComponents(url: connection.modelsURL, resolvingAgainstBaseURL: false) else {
            throw AssistantError.invalidOutput
        }
        components.queryItems = [URLQueryItem(name: "after_id", value: afterID)]
        // Form-style query decoders interpret a literal plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw AssistantError.invalidOutput }
        return url
    }
}
