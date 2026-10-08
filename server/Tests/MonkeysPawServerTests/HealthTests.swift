import Foundation
import HummingbirdTesting
import XCTest
@testable import MonkeysPawServer

final class HealthTests: XCTestCase {
    func testHealthReturnsStatusAndFallbackVersion() async throws {
        try await assertHealth(environment: [:], expectedVersion: "0.0.0")
    }

    func testHealthReturnsConfiguredVersion() async throws {
        try await assertHealth(
            environment: ["MONKEYSPAW_VERSION": "0.1.0-test"],
            expectedVersion: "0.1.0-test"
        )
    }

    func testConfigurationDefaultsAndOverrides() throws {
        let defaults = try ServerConfiguration(environment: [:])
        XCTAssertEqual(defaults.httpHost, "0.0.0.0")
        XCTAssertEqual(defaults.httpPort, 8080)

        let configured = try ServerConfiguration(environment: [
            "MONKEYSPAW_HTTP_HOST": "127.0.0.1",
            "MONKEYSPAW_HTTP_PORT": "8790",
        ])
        XCTAssertEqual(configured.httpHost, "127.0.0.1")
        XCTAssertEqual(configured.httpPort, 8790)
    }

    func testConfigurationRejectsInvalidPorts() {
        for port in ["", "not-a-port", "0", "-1", "65536"] {
            XCTAssertThrowsError(try ServerConfiguration(environment: ["MONKEYSPAW_HTTP_PORT": port]))
        }
    }

    private func assertHealth(environment: [String: String], expectedVersion: String) async throws {
        let configuration = try ServerConfiguration(environment: environment)
        let application = buildApplication(configuration: configuration)

        try await application.test(.router) { client in
            try await client.execute(uri: "/api/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "application/json; charset=utf-8")

                let body = try JSONDecoder().decode([String: String].self, from: Data(response.body.readableBytesView))
                XCTAssertEqual(body, ["status": "ok", "version": expectedVersion])
            }
        }
    }
}
