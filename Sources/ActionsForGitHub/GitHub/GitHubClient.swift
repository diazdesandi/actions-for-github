//
//  GitHubClient.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  The GitHub REST client. An actor, because it owns two caches that outlive
//  any one request and the droplet that calls it is on the main actor: the
//  network work has no business there.
//
//  Two things here are not decoration. Every request is conditional on the
//  ETag of the last response, so a repository that has not built since the
//  last poll answers 304 with no body and costs nothing against the hourly
//  quota. And the rate limit headers are read on every response, so a droplet
//  polling five repositories every minute backs off before GitHub starts
//  refusing it rather than after.
//

import Foundation

// MARK: - Errors

/// What can go wrong talking to GitHub, phrased so the message can be shown to
/// the user as-is. A widget that says "the token was refused" is worth five
/// that say "an error occurred".
public enum GitHubError: Error, Sendable, Equatable {
    /// No token has been saved yet.
    case noToken
    /// The token was refused: expired, revoked, or mistyped.
    case unauthorized
    /// The token is valid but cannot see this repository. On a private
    /// repository this is usually a missing scope rather than a missing repo.
    case forbidden
    /// No such repository, or the token cannot see that it exists.
    case notFound
    /// The hourly quota is spent. Carries the moment it resets.
    case rateLimited(until: Date)
    /// Any other HTTP status.
    case http(status: Int)
    /// The request never completed.
    case transport(String)
    /// The response did not look like what the API documents.
    case decoding(String)

    /// One sentence, sentence case, safe to put in a settings pane.
    public var message: String {
        switch self {
        case .noToken:
            return "Add a GitHub token to start watching repositories."
        case .unauthorized:
            return "GitHub refused the token. It may have expired or been revoked."
        case .forbidden:
            return "The token cannot read this repository. Check that it has the Actions scope."
        case .notFound:
            return "No such repository, or the token cannot see it."
        case .rateLimited(let until):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "GitHub's rate limit is spent. It resets at \(formatter.string(from: until))."
        case .http(let status):
            return "GitHub answered \(status)."
        case .transport(let detail):
            return "Could not reach GitHub: \(detail)"
        case .decoding(let detail):
            return "GitHub's answer could not be read: \(detail)"
        }
    }
}

// MARK: - Rate limit

/// What the quota headers on the last response said.
public struct RateLimit: Sendable, Equatable {
    /// Requests left in the current window.
    public let remaining: Int
    /// The window's ceiling.
    public let limit: Int
    /// When the window rolls over.
    public let resetsAt: Date

    public init(remaining: Int, limit: Int, resetsAt: Date) {
        self.remaining = remaining
        self.limit = limit
        self.resetsAt = resetsAt
    }

    /// Whether so little is left that polling should stand down until the
    /// window rolls over. The floor sits above zero deliberately, so that a
    /// user who opens Settings and hits "Check" still gets an answer out of
    /// the requests the poll loop did not spend.
    public var isNearlySpent: Bool { remaining <= 10 }
}

// MARK: - Client

/// Reads workflow runs from GitHub.
public actor GitHubClient {
    private var token: String?
    private let session: URLSession

    /// ETag of the last response per endpoint path, sent back as
    /// `If-None-Match` so an unchanged endpoint answers 304.
    private var etags: [String: String] = [:]
    /// The body that ETag belongs to, since a 304 carries none.
    private var bodies: [String: Data] = [:]

    /// Default branch per repository. It is read once and kept: a repository
    /// renames its default branch roughly never, and paying a request per poll
    /// to re-learn it would double this droplet's quota use.
    private var defaultBranches: [String: String] = [:]

    /// The quota headers from the most recent response.
    private(set) var rateLimit: RateLimit?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Replaces the token and drops every cache, because the caches are
    /// answers the old token was allowed to see.
    public func setToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmed?.isEmpty ?? true) ? nil : trimmed
        etags.removeAll()
        bodies.removeAll()
        defaultBranches.removeAll()
        rateLimit = nil
    }

    /// Whether a token is set. Not whether it works — only a request can say
    /// that, which is what ``verifyToken()`` is for.
    public func hasToken() -> Bool { token != nil }

    /// The quota state, for the settings pane.
    public func currentRateLimit() -> RateLimit? { rateLimit }

    /// Forgets this repository's caches, so the next poll is unconditional.
    public func invalidate(_ ref: RepoRef) {
        let prefix = "/repos/\(ref.owner)/\(ref.name)"
        for key in etags.keys where key.hasPrefix(prefix) { etags[key] = nil }
        for key in bodies.keys where key.hasPrefix(prefix) { bodies[key] = nil }
        defaultBranches[ref.id] = nil
    }

    // MARK: Endpoints

    /// The login the token belongs to. The cheapest call that proves a token
    /// works, which is what the settings pane's "Check" button wants.
    public func verifyToken() async throws -> String {
        let data = try await get("/user", conditional: false)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let login = object["login"] as? String
        else {
            throw GitHubError.decoding("no login in /user")
        }
        return login
    }

    /// The repository's default branch, read once per repository per session.
    public func defaultBranch(for ref: RepoRef) async throws -> String {
        if let cached = defaultBranches[ref.id] { return cached }

        let data = try await get("/repos/\(ref.owner)/\(ref.name)", conditional: false)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let branch = object["default_branch"] as? String
        else {
            throw GitHubError.decoding("no default_branch for \(ref.id)")
        }
        defaultBranches[ref.id] = branch
        return branch
    }

    /// Recent runs on one branch, newest first.
    ///
    /// One request covers every surface: the newest run is the widget's state,
    /// the newest active run is the live activity, and the tail is the success
    /// rate and the median duration. Asking for the tail costs the same as
    /// asking for the head.
    public func recentRuns(
        for ref: RepoRef,
        branch: String,
        limit: Int = 20
    ) async throws -> [WorkflowRun] {
        var components = URLComponents()
        components.path = "/repos/\(ref.owner)/\(ref.name)/actions/runs"
        components.queryItems = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "exclude_pull_requests", value: "true")
        ]
        guard let path = components.string else { throw GitHubError.decoding("bad query") }

        let data = try await get(path, conditional: true)
        return try Self.decodeRuns(data)
    }

    /// A repository's runs plus the health they add up to, or a snapshot
    /// carrying the failure.
    ///
    /// Returning a failed snapshot rather than throwing is deliberate: the
    /// monitor polls a list, and one repository the user typed wrong must not
    /// take the other four off the shelf.
    public func snapshot(for ref: RepoRef, limit: Int = 20) async -> RepoSnapshot {
        do {
            let branch = try await defaultBranch(for: ref)
            let runs = try await recentRuns(for: ref, branch: branch, limit: limit)
            return RepoSnapshot(ref: ref, branch: branch, runs: runs, fetchedAt: Date())
        } catch let error as GitHubError {
            return RepoSnapshot(
                ref: ref,
                branch: defaultBranches[ref.id] ?? "",
                runs: [],
                fetchedAt: Date(),
                failureMessage: error.message
            )
        } catch {
            return RepoSnapshot(
                ref: ref,
                branch: defaultBranches[ref.id] ?? "",
                runs: [],
                fetchedAt: Date(),
                failureMessage: GitHubError.transport(error.localizedDescription).message
            )
        }
    }

    // MARK: Transport

    private func get(_ path: String, conditional: Bool) async throws -> Data {
        guard let token else { throw GitHubError.noToken }

        if let limit = rateLimit, limit.isNearlySpent, limit.resetsAt > Date() {
            throw GitHubError.rateLimited(until: limit.resetsAt)
        }

        guard let url = URL(string: "https://api.github.com" + path) else {
            throw GitHubError.decoding("bad path \(path)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ActionsLens-Droplet", forHTTPHeaderField: "User-Agent")
        // URLSession's own cache would answer from disk without telling us the
        // ETag story, and the droplet needs to know whether anything changed.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if conditional, let etag = etags[path] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.decoding("not an HTTP response")
        }

        readRateLimit(from: http)

        switch http.statusCode {
        case 200...299:
            if conditional, let etag = http.value(forHTTPHeaderField: "ETag") {
                etags[path] = etag
                bodies[path] = data
            }
            return data

        case 304:
            // Nothing changed, and this response did not count against the
            // quota. Hand back the body the ETag belongs to.
            if let cached = bodies[path] { return cached }
            // The body was dropped without the ETag; ask again unconditionally.
            etags[path] = nil
            return try await get(path, conditional: false)

        case 401:
            throw GitHubError.unauthorized

        case 403, 429:
            // 403 is both "forbidden" and "rate limited" on this API. The
            // headers are what tell them apart.
            if let limit = rateLimit, limit.remaining == 0 {
                throw GitHubError.rateLimited(until: limit.resetsAt)
            }
            if let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = TimeInterval(retryAfter) {
                throw GitHubError.rateLimited(until: Date().addingTimeInterval(seconds))
            }
            throw GitHubError.forbidden

        case 404:
            throw GitHubError.notFound

        default:
            throw GitHubError.http(status: http.statusCode)
        }
    }

    private func readRateLimit(from response: HTTPURLResponse) {
        guard
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init),
            let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
            let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
        else {
            return
        }
        rateLimit = RateLimit(
            remaining: remaining,
            limit: limit,
            resetsAt: Date(timeIntervalSince1970: reset)
        )
    }

    // MARK: Decoding

    /// Decodes the `workflow_runs` array.
    ///
    /// Hand-rolled rather than `Codable`: the payload nests differently from
    /// the model, three fields need the status/conclusion collapse, and the
    /// timestamps are ISO 8601 with a `Z` that the default date strategy does
    /// not read. A `CodingKeys` enum plus three custom decoders is longer than
    /// this and no clearer.
    static func decodeRuns(_ data: Data) throws -> [WorkflowRun] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawRuns = object["workflow_runs"] as? [[String: Any]]
        else {
            throw GitHubError.decoding("no workflow_runs array")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        func date(_ value: Any?) -> Date? {
            guard let string = value as? String else { return nil }
            return formatter.date(from: string)
        }

        return rawRuns.compactMap { raw -> WorkflowRun? in
            guard
                let id = raw["id"] as? Int,
                let created = date(raw["created_at"])
            else {
                return nil
            }
            return WorkflowRun(
                id: id,
                workflowName: (raw["name"] as? String) ?? "Workflow",
                branch: (raw["head_branch"] as? String) ?? "",
                event: (raw["event"] as? String) ?? "",
                runNumber: (raw["run_number"] as? Int) ?? 0,
                state: RunState(
                    status: raw["status"] as? String,
                    conclusion: raw["conclusion"] as? String
                ),
                createdAt: created,
                updatedAt: date(raw["updated_at"]) ?? created,
                startedAt: date(raw["run_started_at"]),
                htmlURL: (raw["html_url"] as? String).flatMap(URL.init(string:))
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}
