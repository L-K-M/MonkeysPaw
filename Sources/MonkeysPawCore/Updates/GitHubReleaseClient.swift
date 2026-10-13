import Foundation

/// The stable-only public endpoint is fixed; no account/sync state enters this
/// client. Vervellum's GitHubReleaseClient (Unlicense) supplies the reference
/// endpoint/header contract: https://github.com/L-K-M/Vervellum.
struct GitHubReleaseClient: Sendable {
    struct Release: Equatable, Sendable {
        let version: ReleaseVersion
        let page: URL
    }

    private struct Payload: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    let transport: HTTPTransporting

    func latestRelease(currentVersion: ReleaseVersion, now: () -> Date) async throws -> Release? {
        do {
            try Task.checkCancellation()
            let deadline = ContinuousClock.now.advanced(by: Limits.updateRequestTimeout)
            let request = try HTTPRequest(
                url: URL(string: "https://api.github.com/repos/L-K-M/MonkeysPaw/releases/latest")!,
                method: .get, headers: [
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                    "User-Agent": "MonkeysPaw/\(currentVersion.description)"
                ], responseByteCap: Limits.updateResponseCap, deadline: deadline)
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw HTTPTransportError.deadlineExceeded }
            guard response.body.count <= Limits.updateResponseCap else { throw HTTPTransportError.responseTooLarge }

            switch response.statusCode {
            case 404: return nil
            case 403, 429:
                throw UpdateCheckFailure.rateLimited(UpdateRateLimit(statusCode: response.statusCode,
                    until: rateLimitDate(response.headers, at: now())))
            case 300..<400: throw HTTPTransportError.redirectRefused
            case 200: break
            default: throw UpdateCheckFailure.httpStatus(response.statusCode)
            }

            guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
                throw UpdateCheckFailure.malformedResponse
            }
            guard !payload.draft, !payload.prerelease else { return nil }
            guard payload.tag_name.hasPrefix("v"), let version = ReleaseVersion(payload.tag_name),
                  !version.isPrerelease else { throw UpdateCheckFailure.malformedResponse }

            // Ignore every response URL, asset and release note. This strict tag
            // alphabet cannot inject a path, query, fragment or different origin.
            let page = URL(string: "https://github.com/L-K-M/MonkeysPaw/releases/tag/v\(version.description)")!
            return Release(version: version, page: page)
        } catch let failure as UpdateCheckFailure { throw failure }
        catch HTTPTransportError.networkFailure { throw UpdateCheckFailure.offline }
        catch let failure as HTTPTransportError { throw UpdateCheckFailure.transport(failure) }
        catch is CancellationError { throw UpdateCheckFailure.transport(.cancelled) }
        catch { throw UpdateCheckFailure.offline }
    }

    private func rateLimitDate(_ headers: [String: String], at now: Date) -> Date {
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name }?.value
        }
        func seconds(_ raw: String?) -> TimeInterval? {
            guard let raw, !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = TimeInterval(raw), value.isFinite,
                  value <= Limits.historyMaxUnixSeconds else { return nil }
            return value
        }
        var until = now.addingTimeInterval(Limits.updateRateLimitMinimumDelay)
        if let delay = seconds(header("retry-after")) {
            until = max(until, now.addingTimeInterval(delay))
        }
        if header("x-ratelimit-remaining") == "0", let reset = seconds(header("x-ratelimit-reset")) {
            until = max(until, Date(timeIntervalSince1970: reset))
        }
        return min(until, Date(timeIntervalSince1970: Limits.historyMaxUnixSeconds - 1))
    }
}
