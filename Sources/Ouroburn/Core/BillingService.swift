import Foundation

/// Optional fetch of month-to-date billed cost or usage. Three backends, all opt-in via secret.
/// Default install never makes any network call against Anthropic.
///
/// Backends in priority order:
///
/// 1. **Claude Code OAuth usage** — set `CLAUDE_CODE_OAUTH_TOKEN` (or paste into the settings
///    keychain). Hits the same undocumented endpoint Claude Code's statusline + claude-proxy
///    use: `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer …`,
///    `Anthropic-Beta: oauth-2025-04-20`, and `Anthropic-Version: 2023-06-01`. Returns
///    `extra_usage.used_credits` (cents → dollars) for MTD overage. Available to individual
///    accounts (the Admin API is not). The endpoint rate-limits aggressively so polling stays
///    capped at the same 1 h cadence as the other backends and any 429 with `Retry-After`
///    extends the cool-down to that value.
///
/// 2. **Claude Enterprise (claude.ai OAuth)** — set `CLAUDE_OAUTH_TOKEN` to your bearer token.
///    Hits the (undocumented) `claude.ai` API surface used by the web app:
///    `GET https://claude.ai/api/organizations` then per-org candidate paths
///    `…/usage`, `…/billing/usage`, `…/usage/summary`. Whichever returns 2xx first is saved
///    raw to `~/Library/Caches/ouroburn/enterprise-usage.json` so the user can shape the
///    parser to whatever the server actually returns. NOTE: this requires a *web-session*
///    bearer, not the Claude Code OAuth token from #1 — the two surfaces do not share auth.
///
/// 3. **Anthropic Admin API (organization billing)** — set `ANTHROPIC_ADMIN_API_KEY`
///    (`sk-ant-admin01-…`). Hits `POST /v1/organizations/cost_report` and sums every
///    `amount`/`amount_usd` it finds in the response payload. Admin keys are only available
///    to organizations (not individual accounts).
///
/// Pulls run at most once per hour (in-memory throttle) and cache to disk so the popover has
/// data to show after relaunch even when offline.
actor BillingService {
    /// Cap on the exponential-backoff cool-down — `Preferences.oauthRefreshMaxMinutes` mirrors
    /// this so the settings UI uses the same ceiling.
    private static let backoffCeilingSeconds: TimeInterval = 15 * 60
    private static let httpTimeout: TimeInterval = 15
    private static let oauthUsageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let oauthUsageBeta = "oauth-2025-04-20"
    private static let anthropicVersion = "2023-06-01"
    private static let userAgent = "ouroburn/0.1 (+https://github.com/sheldonhull/ouroburn)"
    private static let adminEndpoint = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    private static let enterpriseOrgsEndpoint = URL(string: "https://claude.ai/api/organizations")!
    private static let enterpriseUsageSuffixes = [
        "/usage",
        "/billing/usage",
        "/usage/summary",
        "/billable_usage"
    ]
    private static let enterpriseDumpFilename = "enterprise-usage.json"

    private let cacheURL: URL
    private let session: URLSession
    private let environment: [String: String]
    private let sampleStore: BillingSampleStore
    private var lastAttemptAt: Date? // updated on every network attempt — success OR failure
    private var lastFetchedAt: Date?
    private var lastReport: BillingReport?
    private var oauthBackoffUntil: Date? // upstream 429 cool-down (longer than the 1 h floor)
    private var baselinePollInterval: TimeInterval = 5 * 60 // overridden via setPollInterval
    private var consecutiveFailures: Int = 0 // doubles the cool-down each time, capped at the ceiling
    private var lastStatusMessage: String? // human-readable billing status surfaced into the snapshot
    /// While the popover is open we shorten the floor so the user's monthly tile keeps up. Still
    /// rides on top of `consecutiveFailures` backoff and the upstream 429 cool-down — this only
    /// changes the *baseline*, not the cooldown semantics.
    private var foregroundFloorSeconds: TimeInterval?
    static let foregroundBoostSeconds: TimeInterval = 60

    init(
        cacheURL: URL,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sampleStore: BillingSampleStore = BillingSampleStore()
    ) {
        self.cacheURL = cacheURL
        self.session = session
        self.environment = environment
        self.sampleStore = sampleStore
        let initial = Self.readDiskCacheStatic(at: cacheURL)
        lastReport = initial
        lastFetchedAt = initial?.fetchedAt
        // Don't seed lastAttemptAt from the cache: the on-disk report may be from an older
        // backend (e.g. enterprise probe) and we want the new poll cadence to fire on the next
        // tick rather than waiting out the 1-hour throttle from the previous run.
        lastAttemptAt = nil
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
    /// Update the baseline poll interval at runtime when the user edits the setting. Bounded to
    /// `[1, 60]` minutes; the exponential backoff still rides on top up to
    /// `backoffCeilingSeconds`.
    func setPollInterval(minutes: Double) {
        let clamped = min(max(minutes, 1), 60)
        baselinePollInterval = clamped * 60
    }

    /// Toggle the foreground boost on/off. While `active`, the effective baseline floors at
    /// `foregroundBoostSeconds` (60s) — the user's configured interval still wins if it's already
    /// shorter. Backoff and 429 cool-downs are unchanged.
    func setForegroundActive(_ active: Bool) {
        foregroundFloorSeconds = active ? Self.foregroundBoostSeconds : nil
    }

    func currentMonthBilledUSD() async -> Double? {
        let claudeCodeToken = await resolveClaudeCodeOAuthToken()
        let oauthToken = resolveSecret(envKey: "CLAUDE_OAUTH_TOKEN", account: SecretsAccount.claudeOAuth)
        let adminKey = resolveSecret(envKey: "ANTHROPIC_ADMIN_API_KEY", account: SecretsAccount.anthropicAdmin)

        guard claudeCodeToken != nil || oauthToken != nil || adminKey != nil else {
            lastStatusMessage = "no token · run `claude login` (PKCE) or paste Admin API key"
            return lastReport?.totalUSD
        }

        let now = Date()
        let interval = currentPollInterval()
        if let lastAttempt = lastAttemptAt, now.timeIntervalSince(lastAttempt) < interval {
            return lastReport?.totalUSD
        }
        lastAttemptAt = now

        if let token = claudeCodeToken,
           (oauthBackoffUntil.map { now >= $0 } ?? true),
           let result = await runOAuthUsage(token: token)
        {
            registerSuccess()
            stamp(report: result)
            return result.totalUSD
        }
        if let token = oauthToken, let result = await runEnterprise(token: token) {
            registerSuccess()
            stamp(report: result)
            return result.totalUSD
        }
        if let key = adminKey, let result = await runAdminAPI(key: key) {
            registerSuccess()
            stamp(report: result)
            return result.totalUSD
        }
        registerFailure()
        return lastReport?.totalUSD
    }

    /// Effective interval = baseline × 2^failures, capped at the ceiling. After a successful
    /// fetch the failure count resets and we drop back to the user's configured cadence.
    /// While the foreground boost is active, the baseline is replaced by the smaller of the two
    /// (so a user who already runs 30s polls isn't slowed down by the boost).
    private func currentPollInterval() -> TimeInterval {
        let baseline: TimeInterval = if let floor = foregroundFloorSeconds {
            min(baselinePollInterval, floor)
        } else {
            baselinePollInterval
        }
        let multiplier = pow(2.0, Double(consecutiveFailures))
        return min(baseline * multiplier, Self.backoffCeilingSeconds)
    }

    private func registerSuccess() {
        consecutiveFailures = 0
    }

    private func registerFailure() {
        // Cap the exponent so multiplier doesn't overflow; the ceiling clamps the actual delay.
        if currentPollInterval() < Self.backoffCeilingSeconds {
            consecutiveFailures += 1
        }
    }

    /// Resolves the Claude Code OAuth bearer token used against `/api/oauth/usage`. Order:
    /// 1. Ouroburn's own PKCE credential (auto-refreshed when near expiry)
    /// 2. `CLAUDE_OAUTH_TOKEN` env / keychain entry the user pastes manually (skipped if it's
    ///    obviously a `sk-ant-oat01-` setup-token, which Anthropic disabled for this surface
    ///    in early 2026)
    /// 3. `~/.claude/.credentials.json` written by interactive `claude login`
    private func resolveClaudeCodeOAuthToken() async -> String? {
        if let credential = OAuthCredentialStore.load() {
            if !credential.expiresWithin(5 * 60) {
                return credential.accessToken
            }
            if let refreshed = await refreshStoredCredential(credential) {
                return refreshed.accessToken
            }
        }
        if let value = environment["CLAUDE_OAUTH_TOKEN"], usableForOAuthUsage(value) {
            return value
        }
        if let stored = Keychain.read(account: SecretsAccount.claudeOAuth), usableForOAuthUsage(stored) {
            return stored
        }
        return readClaudeCodeCredentials()
    }

    private func refreshStoredCredential(_ credential: StoredCredential) async -> StoredCredential? {
        do {
            let refreshed = try await OAuthLogin.refresh(credential: credential)
            OAuthCredentialStore.save(refreshed)
            Log.info(Log.pricing, "Refreshed PKCE credential — expires \(refreshed.expiresAt)")
            return refreshed
        } catch {
            Log.error(Log.pricing, "PKCE refresh failed: \(error)")
            lastStatusMessage = "refresh failed · re-link account"
            return nil
        }
    }

    private func usableForOAuthUsage(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.hasPrefix("sk-ant-oat01-") {
            Log.info(
                Log.pricing,
                "Skipping sk-ant-oat01- setup-token for /api/oauth/usage; falling back to ~/.claude/.credentials.json"
            )
            return false
        }
        return true
    }

    private func readClaudeCodeCredentials() -> String? {
        let path = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return nil }
        return Self.findFirstString(in: dict, keys: ["accessToken", "access_token", "token"])
    }

    private static func findFirstString(in node: Any, keys: [String]) -> String? {
        if let dict = node as? [String: Any] {
            for key in keys {
                if let s = dict[key] as? String, !s.isEmpty { return s }
            }
            for value in dict.values {
                if let hit = findFirstString(in: value, keys: keys) { return hit }
            }
        } else if let array = node as? [Any] {
            for v in array {
                if let hit = findFirstString(in: v, keys: keys) { return hit }
            }
        }
        return nil
    }

    /// Drops the in-memory throttle + 429 backoff so the next `currentMonthBilledUSD` call
    /// triggers a fresh network attempt. Used by the "Refresh now" menu item.
    func invalidate() {
        lastAttemptAt = nil
        oauthBackoffUntil = nil
        consecutiveFailures = 0
    }

    /// Last human-readable billing status (success summary, 429 backoff timer, auth failure
    /// hint). Surfaced into the popover footer when there's no cached dollar figure yet.
    func currentStatusMessage() -> String? { lastStatusMessage }

    private func resolveSecret(envKey: String, account: String) -> String? {
        if let value = environment[envKey], !value.isEmpty { return value }
        if let stored = Keychain.read(account: account), !stored.isEmpty { return stored }
        return nil
    }

    private func stamp(report: BillingReport) {
        lastReport = report
        lastFetchedAt = report.fetchedAt
        writeDiskCache(report)
        sampleStore.append(BillingSample(
            timestamp: report.fetchedAt,
            totalUSD: report.totalUSD,
            source: Self.sourceTag(for: report.source)
        ))
    }

    private static func sourceTag(for source: BillingReport.Source) -> String {
        switch source {
        case .admin: "admin_api"
        case .enterprise: "claude_ai_enterprise"
        case .claudeCodeOAuth: "claude_code_oauth"
        }
    }

    // MARK: - Claude Code OAuth (`/api/oauth/usage`) path

    private func runOAuthUsage(token: String) async -> BillingReport? {
        do {
            let result = try await fetchOAuthUsage(token: token)
            Log.info(Log.pricing, String(
                format: "OAuth usage fetched: $%.2f / $%.2f extra (5h %.0f%%, 7d %.0f%%)",
                result.extraUsedUSD, result.extraLimitUSD,
                result.fiveHourPct * 100, result.sevenDayPct * 100
            ))
            lastStatusMessage = nil // success — let the dollar value speak for itself
            return BillingReport(
                month: BillingReport.currentMonthKey(),
                totalUSD: result.extraUsedUSD,
                fetchedAt: Date(),
                source: .claudeCodeOAuth(
                    extraUsedUSD: result.extraUsedUSD,
                    extraLimitUSD: result.extraLimitUSD,
                    fiveHourPct: result.fiveHourPct,
                    sevenDayPct: result.sevenDayPct
                )
            )
        } catch let error as OAuthUsageError {
            switch error {
            case let .rateLimited(retryAfter):
                // Honour the upstream Retry-After but never accept a value above the global
                // ceiling — the public-tracker issues #31021/#31637 show 429s frequently miss
                // Retry-After entirely, and we don't want a misbehaving server to lock us out
                // for hours. Falls back to the current backed-off interval when absent.
                let fallback = currentPollInterval()
                let cooldown = min(max(retryAfter, fallback), Self.backoffCeilingSeconds)
                let until = Date().addingTimeInterval(cooldown)
                oauthBackoffUntil = until
                Log.error(
                    Log.pricing,
                    "OAuth usage 429 — backing off for \(Int(cooldown))s"
                )
                lastStatusMessage = "rate-limited · retry in \(formatMinutes(cooldown))"
            case let .badStatus(code):
                Log.error(Log.pricing, "OAuth usage status \(code)")
                lastStatusMessage = code == 401 || code == 403
                    ? "unauthorized (HTTP \(code)) · re-run `claude login`"
                    : "/api/oauth/usage HTTP \(code)"
            case let .transport(message):
                Log.error(Log.pricing, "OAuth usage transport error: \(message)")
                lastStatusMessage = "network error · \(message)"
            case .decodeFailure:
                Log.error(Log.pricing, "OAuth usage payload decode failed")
                lastStatusMessage = "decode failed · upstream payload changed?"
            }
            return nil
        } catch {
            Log.error(Log.pricing, "OAuth usage fetch failed: \(error.localizedDescription)")
            lastStatusMessage = "fetch failed · \(error.localizedDescription)"
            return nil
        }
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds + 59) / 60)
        return minutes <= 1 ? "1m" : "\(minutes)m"
    }

    private struct OAuthUsageResult {
        let extraUsedUSD: Double
        let extraLimitUSD: Double
        let fiveHourPct: Double
        let sevenDayPct: Double
    }

    private enum OAuthUsageError: Error {
        case rateLimited(retryAfter: TimeInterval)
        case badStatus(Int)
        case transport(String)
        case decodeFailure
    }

    private func fetchOAuthUsage(token: String) async throws -> OAuthUsageResult {
        var request = URLRequest(url: Self.oauthUsageEndpoint, timeoutInterval: Self.httpTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthUsageBeta, forHTTPHeaderField: "Anthropic-Beta")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "Anthropic-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthUsageError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw OAuthUsageError.badStatus(-1) }
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(TimeInterval.init) ?? currentPollInterval()
            throw OAuthUsageError.rateLimited(retryAfter: retryAfter)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OAuthUsageError.badStatus(http.statusCode)
        }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { throw OAuthUsageError.decodeFailure }

        let extra = dict["extra_usage"] as? [String: Any]
        let usedCents = (extra?["used_credits"] as? NSNumber)?.doubleValue ?? 0
        let limitCents = (extra?["monthly_limit"] as? NSNumber)?.doubleValue ?? 0
        let fiveHour = (dict["five_hour"] as? [String: Any])?["utilization"] as? NSNumber
        let sevenDay = (dict["seven_day"] as? [String: Any])?["utilization"] as? NSNumber

        return OAuthUsageResult(
            extraUsedUSD: usedCents / 100,
            extraLimitUSD: limitCents / 100,
            fiveHourPct: fiveHour?.doubleValue ?? 0,
            sevenDayPct: sevenDay?.doubleValue ?? 0
        )
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
            "group_by": ["workspace_id"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error(
                Log.pricing,
                "cost_report \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
            )
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
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.error(
                Log.pricing,
                "enterprise /organizations \(status): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
            )
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
                if (200 ..< 300).contains(status) {
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
            "body": (try? JSONSerialization.jsonObject(with: data)) ?? String(data: data, encoding: .utf8) ?? ""
        ]
        if let envelopeData = try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.prettyPrinted, .sortedKeys]
        ) {
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
                    if lower == "amount" || lower == "amount_usd" || lower == "cost" || lower == "cost_usd" || lower ==
                        "total_cost"
                    {
                        total += n
                    }
                }
                accumulateAmount(value, into: &total)
            }
        } else if let array = node as? [Any] {
            for v in array {
                accumulateAmount(v, into: &total)
            }
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
            for value in dict.values {
                collectUUIDs(value, into: &out)
            }
        } else if let array = node as? [Any] {
            for v in array {
                collectUUIDs(v, into: &out)
            }
        }
    }
}

struct BillingReport: Codable, Sendable {
    enum Source: Codable, Sendable {
        case admin
        case enterprise(orgUUID: String, endpoint: String, rawDumpPath: String)
        case claudeCodeOAuth(
            extraUsedUSD: Double,
            extraLimitUSD: Double,
            fiveHourPct: Double,
            sevenDayPct: Double
        )
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
