import Foundation
@testable import Ouroburn
import Testing

/// Stubbed URLProtocol used by BillingService tests. Each test queues HTTP responses keyed off
/// the OAuth usage endpoint and counts hits to that endpoint; all other hosts (e.g. claude.ai
/// enterprise fallback) get an immediate `.notConnectedToInternet` error and are NOT counted.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    static let oauthHost = "api.anthropic.com"
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var oauthRequestCount: Int = 0
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
        oauthRequestCount = 0
    }

    static func enqueue(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        queue.append(response)
    }

    static func currentOAuthRequestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return oauthRequestCount
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let isOAuthUsage = request.url?.host == Self.oauthHost
            && request.url?.path == "/api/oauth/usage"
        if !isOAuthUsage {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        Self.lock.lock()
        Self.oauthRequestCount += 1
        let response = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        Self.lock.unlock()

        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Billing", .serialized)
struct BillingServiceTests {
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeCacheURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ouroburn-billing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("billing.json")
    }

    private static func cleanup(_ cacheURL: URL) {
        try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
    }

    @Test func parseRetryAfterNumericSeconds() {
        #expect(BillingService.parseRetryAfter("30") == 30)
        #expect(BillingService.parseRetryAfter("3600") == 3600)
    }

    @Test func parseRetryAfterZeroReturnsNil() {
        #expect(BillingService.parseRetryAfter("0") == nil)
    }

    @Test func parseRetryAfterEmptyReturnsNil() {
        #expect(BillingService.parseRetryAfter("") == nil)
        #expect(BillingService.parseRetryAfter("   ") == nil)
        #expect(BillingService.parseRetryAfter(nil) == nil)
    }

    @Test func parseRetryAfterGarbageReturnsNil() {
        #expect(BillingService.parseRetryAfter("abc") == nil)
        #expect(BillingService.parseRetryAfter("not-a-date") == nil)
    }

    @Test func parseRetryAfterFutureHTTPDate() {
        let future = Date().addingTimeInterval(3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: future)
        let parsed = BillingService.parseRetryAfter(header)
        #expect(parsed != nil)
        if let parsed {
            #expect(abs(parsed - 3600) < 5)
        }
    }

    @Test func parseRetryAfterPastHTTPDateReturnsNil() {
        let past = Date().addingTimeInterval(-3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: past)
        #expect(BillingService.parseRetryAfter(header) == nil)
    }

    @Test func cooldownHonorsRetryAfterAbovePollCeiling() async {
        MockURLProtocol.reset()
        let cacheURL = Self.makeCacheURL()
        defer { Self.cleanup(cacheURL) }

        MockURLProtocol.enqueue(MockURLProtocol.Response(
            statusCode: 429,
            headers: ["Retry-After": "3600"],
            body: Data()
        ))
        let env = ["CLAUDE_OAUTH_TOKEN": "fake-token"]
        let service = BillingService(cacheURL: cacheURL, session: Self.makeSession(), environment: env)
        _ = await service.currentMonthBilledUSD()
        let health = await service.currentHealth()
        switch health {
        case let .rateLimited(seconds):
            #expect(seconds >= 3600 - 5)
            #expect(seconds > 15 * 60)
        default:
            Issue.record("expected .rateLimited, got \(health)")
        }
    }

    @Test func retryAfterZeroFallsBackToPollInterval() async {
        MockURLProtocol.reset()
        let cacheURL = Self.makeCacheURL()
        defer { Self.cleanup(cacheURL) }

        MockURLProtocol.enqueue(MockURLProtocol.Response(
            statusCode: 429,
            headers: ["Retry-After": "0"],
            body: Data()
        ))
        let env = ["CLAUDE_OAUTH_TOKEN": "fake-token"]
        let service = BillingService(cacheURL: cacheURL, session: Self.makeSession(), environment: env)
        _ = await service.currentMonthBilledUSD()
        let health = await service.currentHealth()
        switch health {
        case let .rateLimited(seconds):
            #expect(seconds >= 5 * 60)
        default:
            Issue.record("expected .rateLimited, got \(health)")
        }
    }

    @Test func backoffPersistsAcrossInit() async {
        MockURLProtocol.reset()
        let cacheURL = Self.makeCacheURL()
        defer { Self.cleanup(cacheURL) }

        MockURLProtocol.enqueue(MockURLProtocol.Response(
            statusCode: 429,
            headers: ["Retry-After": "3600"],
            body: Data()
        ))
        let env = ["CLAUDE_OAUTH_TOKEN": "fake-token"]
        let first = BillingService(cacheURL: cacheURL, session: Self.makeSession(), environment: env)
        _ = await first.currentMonthBilledUSD()
        #expect(MockURLProtocol.currentOAuthRequestCount() == 1)

        let second = BillingService(cacheURL: cacheURL, session: Self.makeSession(), environment: env)
        _ = await second.currentMonthBilledUSD()
        #expect(MockURLProtocol.currentOAuthRequestCount() == 1) // no new request — still in backoff
        let health = await second.currentHealth()
        switch health {
        case .rateLimited: break
        default: Issue.record("expected loaded .rateLimited, got \(health)")
        }
    }

    @Test func expiredBackoffIsDiscarded() async throws {
        MockURLProtocol.reset()
        let cacheURL = Self.makeCacheURL()
        defer { Self.cleanup(cacheURL) }

        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let probeURL = cacheURL.deletingLastPathComponent().appendingPathComponent("oauth-state.json")
        let stale = OAuthProbeState(
            backoffUntil: Date().addingTimeInterval(-60),
            lastHealth: .rateLimited(retryAfterSeconds: 1800),
            lastStatusMessage: "stale",
            consecutiveFailures: 1,
            updatedAt: Date().addingTimeInterval(-3600)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stale)
        try data.write(to: probeURL)

        try MockURLProtocol.enqueue(MockURLProtocol.Response(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: #require(
                #"{"extra_usage":{"used_credits":1234,"monthly_limit":10000},"five_hour":{"utilization":0.1},"seven_day":{"utilization":0.2}}"#
                    .data(using: .utf8)
            )
        ))
        let env = ["CLAUDE_OAUTH_TOKEN": "fake-token"]
        let service = BillingService(cacheURL: cacheURL, session: Self.makeSession(), environment: env)
        _ = await service.currentMonthBilledUSD()
        #expect(MockURLProtocol.currentOAuthRequestCount() == 1)
    }

    @Test func sidecarLoadSurfacesHealthOnInit() async throws {
        MockURLProtocol.reset()
        let cacheURL = Self.makeCacheURL()
        defer { Self.cleanup(cacheURL) }

        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let probeURL = cacheURL.deletingLastPathComponent().appendingPathComponent("oauth-state.json")
        let probe = OAuthProbeState(
            backoffUntil: Date().addingTimeInterval(1800),
            lastHealth: .rateLimited(retryAfterSeconds: 1800),
            lastStatusMessage: "rate-limited · retry in 30m",
            consecutiveFailures: 2,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(probe)
        try data.write(to: probeURL)

        let env: [String: String] = [:]
        let service = BillingService(cacheURL: cacheURL, session: Self.makeSession(), environment: env)
        let health = await service.currentHealth()
        switch health {
        case let .rateLimited(seconds):
            #expect(seconds >= 1000)
        default:
            Issue.record("expected .rateLimited, got \(health)")
        }
    }
}
