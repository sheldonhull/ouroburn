import Foundation

/// Optional fetch of month-to-date billed cost or usage. Two backends, both opt-in via env var.
/// Default install never makes any network call against Anthropic.
///
/// Backends in priority order:
///
/// 1. **Claude Enterprise (claude.ai OAuth)** — set `CLAUDE_OAUTH_TOKEN` to your bearer token.
///    Hits the (undocumented) `claude.ai` API surface used by the web app:
///    `GET https://claude.ai/api/organizations` then per-org candidate paths
///    `…/usage`, `…/billing/usage`, `…/usage/summary`. Whichever returns 2xx first is saved
///    raw to `~/Library/Caches/ouroburn/enterprise-usage.json` so the user can shape the
///    parser to whatever the server actually returns.
///
/// 2. **Anthropic Admin API (per-token billing)** — set `ANTHROPIC_ADMIN_API_KEY`
///    (`sk-ant-admin01-…`). Hits `POST /v1/organizations/cost_report` and sums every
///    `amount`/`amount_usd` it finds in the response payload.
///
/// Pulls run at most once per hour (in-memory throttle) and cache to disk so the popover has
/// data to show after relaunch even when offline.
actor BillingService {
    private static let pollInterval: TimeInterval = 3_600
    private static let httpTimeout: TimeInterval = 15
    private static let adminEndpoint = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    private static let enterpriseOrgsEndpoint = URL(string: "https://claude.ai/api/organizations")!
    private static let enterpriseUsageSuffixes = [
        "/usage",
        "/billing/usage",
        "/usage/summary",
        "/billable_usage",
    ]
    private static let enterpriseDumpFilename = "enterprise-usage.json"

    private let cacheURL: URL
    private let session: URLSession
    private let environment: [String: String]
    private var lastAttemptAt: Date?     // updated on every network attempt — success OR failure
    private var lastFetchedAt: Date?
    private var lastReport: BillingReport?

    init(
        cacheURL: URL,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.cacheURL = cacheURL
        self.session = session
        self.environment = environment
        let initial = Self.readDiskCacheStatic(at: cacheURL)
        self.lastReport = initial
        self.lastFetchedAt = initial?.fetchedAt
        self.lastAttemptAt = initial?.fetchedAt
    }

    /// Returns the latest billed/used total. Throttled to **at most one network attempt per
    /// hour** regardless of success or failure, so a misconfigured token won't hammer the
    /// upstream service via the per-minute tracker poll. The throttle is global across both
    /// backends — claude.ai enterprise probing and the Anthropic admin API share the same
    /// hourly attempt budget.
    ///
    /// Token resolution order, per backend:
    /// 1. Environment variable (highest priority — useful for `op run --` style injection)
    /// 2. Keychain entry (set via the settings window)
    /// 3. Otherwise the backend is skipped.
    func currentMonthBilledUSD() async -> Double? {
        let oauthToken = resolveSecret(envKey: "CLAUDE_OAUTH_TOKEN", account: SecretsAccount.claudeOAuth)
        let adminKey = resolveSecret(envKey: "ANTHROPIC_ADMIN_API_KEY", account: SecretsAccount.anthropicAdmin)

        guard oauthToken != nil || adminKey != nil else {
            return lastReport?.totalUSD
        }

        if let lastAttempt = lastAttemptAt,
           Date().timeIntervalSince(lastAttempt) < Self.pollInterval {
            return lastReport?.totalUSD
        }
        lastAttemptAt = Date()

        if let token = oauthToken, let result = await runEnterprise(token: token) {
            stamp(report: result)
            return result.totalUSD
        }
        if let key = adminKey, let result = await runAdminAPI(key: key) {
            stamp(report: result)
            return result.totalUSD
        }
        return lastReport?.totalUSD
    }

    private func resolveSecret(envKey: String, account: String) -> String? {
        if let value = environment[envKey], !value.isEmpty { return value }
        if let stored = Keychain.read(account: account), !stored.isEmpty { return stored }
        return nil
    }

    private func stamp(report: BillingReport) {
        lastReport = report
        lastFetchedAt = report.fetchedAt
        writeDiskCache(report)
    }

    // MARK: - Anthropic Admin API path

    private func runAdminAPI(key: String) async -> BillingReport? {
        do {
            let total = try await fetchAdminCost(key: key)
            Log.info(Log.pricing, String(format: "Admin cost_report fetched: $%.2f", total))
            return BillingReport(
                month: BillingReport.currentMonthKey(),
                totalUSD: total,
                fetchedAt: Date(),
                source: .admin
            )
        } catch {
            Log.error(Log.pricing, "Admin cost_report fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchAdminCost(key: String) async throws -> Double {
        var request = URLRequest(url: Self.adminEndpoint, timeoutInterval: Self.httpTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let monthStart = BillingReport.firstOfCurrentMonth()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "starting_at": formatter.string(from: monthStart),
            "ending_at": formatter.string(from: Date()),
            "group_by": ["workspace_id"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            Log.error(Log.pricing, "cost_report \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            throw URLError(.userAuthenticationRequired)
        }
        return Self.totalAmountUSD(in: data)
    }

    // MARK: - Claude Enterprise (claude.ai OAuth) path

    private func runEnterprise(token: String) async -> BillingReport? {
        do {
            let orgs = try await fetchEnterpriseOrganizations(token: token)
            Log.info(Log.pricing, "claude.ai enterprise: discovered \(orgs.count) orgs")
            for org in orgs {
                if let dump = await tryEnterpriseUsage(orgUUID: org.uuid, token: token) {
                    persistRawDump(dump.raw, orgUUID: org.uuid, path: dump.path)
                    let total = Self.totalAmountUSD(in: dump.raw)
                    let source: BillingReport.Source = .enterprise(
                        orgUUID: org.uuid,
                        endpoint: dump.path,
                        rawDumpPath: enterpriseDumpURL().path
                    )
                    return BillingReport(
                        month: BillingReport.currentMonthKey(),
                        totalUSD: total,
                        fetchedAt: Date(),
                        source: source
                    )
                }
            }
            Log.error(Log.pricing, "claude.ai enterprise: no candidate endpoint succeeded")
            return nil
        } catch {
            Log.error(Log.pricing, "claude.ai enterprise discovery failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchEnterpriseOrganizations(token: String) async throws -> [EnterpriseOrg] {
        let request = enterpriseRequest(url: Self.enterpriseOrgsEndpoint, token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.error(Log.pricing, "enterprise /organizations \(status): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            throw URLError(.userAuthenticationRequired)
        }
        return EnterpriseOrg.parse(from: data)
    }

    private func tryEnterpriseUsage(orgUUID: String, token: String) async -> (raw: Data, path: String)? {
        for suffix in Self.enterpriseUsageSuffixes {
            let path = "/api/organizations/\(orgUUID)\(suffix)"
            guard let url = URL(string: "https://claude.ai" + path) else { continue }
            var request = enterpriseRequest(url: url, token: token)
            request.httpMethod = "GET"
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.info(Log.pricing, "enterprise GET \(path) → \(status)")
                if (200..<300).contains(status) {
                    return (data, path)
                }
            } catch {
                Log.error(Log.pricing, "enterprise GET \(path) error: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func enterpriseRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: Self.httpTimeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // claude.ai's bot defenses are forgiving but a deliberate UA helps support diagnostics.
        request.setValue("ouroburn/0.1 (+menu-bar)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func enterpriseDumpURL() -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent(Self.enterpriseDumpFilename)
    }

    private func persistRawDump(_ data: Data, orgUUID: String, path: String) {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dumpURL = enterpriseDumpURL()
        let envelope: [String: Any] = [
            "fetched_at": ISO8601DateFormatter().string(from: Date()),
            "org_uuid": orgUUID,
            "endpoint": path,
            "body": (try? JSONSerialization.jsonObject(with: data)) ?? String(data: data, encoding: .utf8) ?? "",
        ]
        if let envelopeData = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]) {
            try? envelopeData.write(to: dumpURL, options: .atomic)
            Log.info(Log.pricing, "Enterprise usage raw dump saved at \(dumpURL.path)")
        }
    }

    // MARK: - Common parsing + persistence

    static func totalAmountUSD(in data: Data) -> Double {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return 0 }
        var total = 0.0
        accumulateAmount(any, into: &total)
        return total
    }

    private static func accumulateAmount(_ node: Any, into total: inout Double) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                if let n = numericAmount(value) {
                    let lower = key.lowercased()
                    if lower == "amount" || lower == "amount_usd" || lower == "cost" || lower == "cost_usd" || lower == "total_cost" {
                        total += n
                    }
                }
                accumulateAmount(value, into: &total)
            }
        } else if let array = node as? [Any] {
            for v in array { accumulateAmount(v, into: &total) }
        }
    }

    private static func numericAmount(_ value: Any) -> Double? {
        if let n = value as? Double { return n }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func readDiskCacheStatic(at url: URL) -> BillingReport? {
        guard let data = try? Data(contentsOf: url),
              let report = try? JSONDecoder().decode(BillingReport.self, from: data) else { return nil }
        return report
    }

    private func writeDiskCache(_ report: BillingReport) {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

private struct EnterpriseOrg {
    let uuid: String

    /// Pull every `uuid` string from the response body, regardless of nesting. claude.ai's web
    /// payload has shifted shapes over the years; treating the field as a leaf grep means a
    /// schema change won't immediately break us.
    static func parse(from data: Data) -> [EnterpriseOrg] {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var ids: [String] = []
        collectUUIDs(any, into: &ids)
        return ids.map { EnterpriseOrg(uuid: $0) }
    }

    private static func collectUUIDs(_ node: Any, into out: inout [String]) {
        if let dict = node as? [String: Any] {
            if let uuid = dict["uuid"] as? String { out.append(uuid) }
            for value in dict.values { collectUUIDs(value, into: &out) }
        } else if let array = node as? [Any] {
            for v in array { collectUUIDs(v, into: &out) }
        }
    }
}

struct BillingReport: Codable, Sendable {
    enum Source: Codable, Sendable {
        case admin
        case enterprise(orgUUID: String, endpoint: String, rawDumpPath: String)
    }

    let month: String
    let totalUSD: Double
    let fetchedAt: Date
    let source: Source

    static func currentMonthKey() -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    static func firstOfCurrentMonth() -> Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: Date())
        return calendar.date(from: comps) ?? Date()
    }
}
