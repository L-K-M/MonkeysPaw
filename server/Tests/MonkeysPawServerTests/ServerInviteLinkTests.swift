import Foundation
import Testing
@testable import MonkeysPawServer

struct ServerInviteLinkTests {
    @Test func joinLinkRoundTripsBothEncodedValues() throws {
        let server = "https://sync.example:8443/\u{96ea}/%20paw?value=a+b&token=other&percent=%25"
        let token = "a+b/c=d&next=?#% \u{96ea}"
        let link = try InviteLink.make(publicURL: server, token: token)
        let url = try #require(URLComponents(string: link))
        #expect(url.scheme == "monkeyspaw" && url.host == "join")
        #expect(url.queryItems == [.init(name: "server", value: server), .init(name: "token", value: token)])
        #expect(!link.contains("+") && !link.contains("#") && !link.contains(" "))
        #expect(link.contains("%26token%3Dother") && link.contains("%2520") && link.contains("%2B"))
    }

    @Test func publicURLIsOptionalAndInvalidSettingsAreSanitized() throws {
        for value in [nil, "", " \t\n"] {
            let env = value.map { ["MONKEYSPAW_PUBLIC_URL": $0] } ?? [:]
            #expect(try ServerConfiguration(environment: env).publicURL == nil)
        }
        for value in ["https://sync.example.test", "http://127.0.0.1:8080/paw", "https://sync.example/paw?x=a+b&y=%2F"] {
            #expect(try ServerConfiguration(environment: ["MONKEYSPAW_PUBLIC_URL": value]).publicURL == value)
        }
        for value in ["relative", "ftp://sync.example", "https:///", "https://user:sentinel-password@sync.example",
                      "https://sync.example/#sentinel-fragment", "https://sync.example/with space", "https://sync.example/\n"] {
            do {
                _ = try ServerConfiguration(environment: ["MONKEYSPAW_PUBLIC_URL": value])
                Issue.record("Invalid public URL was accepted")
            } catch {
                #expect(!String(describing: error).contains(value))
                #expect(!String(describing: error).contains("sentinel"))
            }
        }
    }
}
