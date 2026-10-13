import Foundation

enum InviteLink {
    static func make(publicURL: String, token: String) throws -> String {
        // Query values must also escape '+' and '%' inside the nested server URL.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let server = publicURL.addingPercentEncoding(withAllowedCharacters: unreserved),
              let token = token.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw AccountError.malformedRequest
        }
        return "monkeyspaw://join?server=\(server)&token=\(token)"
    }
}
