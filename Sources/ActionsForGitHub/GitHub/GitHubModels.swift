//
//  GitHubModels.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  The slice of the GitHub Actions API this droplet reads, and the derived
//  health a repository's recent runs add up to.
//
//  Everything here is `Sendable`: the client is an actor and the droplet is
//  main-actor isolated, so every value in this file crosses an isolation
//  boundary on its way to a view.
//

import Foundation

// MARK: - Repository reference

/// One repository the user watches, as `owner/name`.
///
/// Stored in the droplet's preferences, so it is `Codable` and its coding keys
/// are the ones already written to disk. A new field needs a default, and
/// renaming either of these two orphans every watch list already saved.
public struct RepoRef: Codable, Hashable, Identifiable, Sendable, CustomStringConvertible {
    /// The account or organisation.
    public let owner: String
    /// The repository name.
    public let name: String

    public var id: String { "\(owner)/\(name)" }
    public var description: String { id }

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parses `owner/name`, a full GitHub URL, or a `git@` remote.
    ///
    /// The settings pane accepts whatever the user has on the clipboard, which
    /// in practice is one of those three and never a tidy `owner/name`.
    public init?(parsing input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let range = text.range(of: "github.com") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ":/ "))
        if text.hasSuffix(".git") { text.removeLast(4) }

        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let owner = String(parts[0])
        let name = String(parts[1])
        guard Self.isValidSegment(owner), Self.isValidSegment(name) else { return nil }
        self.init(owner: owner, name: name)
    }

    private static func isValidSegment(_ segment: String) -> Bool {
        !segment.isEmpty
            && segment.count <= 100
            && segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// The repository's page, for ``DropletWorkspaceService/open(_:)``.
    public var webURL: URL? { URL(string: "https://github.com/\(owner)/\(name)") }
}

// MARK: - Run state

/// What a workflow run is doing, as one value.
///
/// GitHub splits this across `status` and `conclusion`: a run is `completed`
/// with a conclusion of `failure`, or `in_progress` with no conclusion at all.
/// Every surface in this droplet wants the single answer, so the split is
/// collapsed once, here, rather than at each of the five places that draws a
/// status glyph.
public enum RunState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case success
    case failure
    case cancelled
    case skipped
    case actionRequired
    case neutral
    case unknown

    /// Collapses GitHub's `status` and `conclusion` pair.
    public init(status: String?, conclusion: String?) {
        switch status {
        case "queued", "requested", "waiting", "pending":
            self = .queued
            return
        case "in_progress":
            self = .running
            return
        default:
            break
        }

        switch conclusion {
        case "success":          self = .success
        case "failure":          self = .failure
        case "timed_out":        self = .failure
        case "startup_failure":  self = .failure
        case "cancelled":        self = .cancelled
        case "skipped":          self = .skipped
        case "action_required":  self = .actionRequired
        case "neutral", "stale": self = .neutral
        case nil where status == "completed": self = .unknown
        default:                 self = .unknown
        }
    }

    /// Whether the run is still going. Drives the live activity and the fast
    /// poll cadence.
    public var isActive: Bool { self == .queued || self == .running }

    /// Whether the run reached a conclusion the success rate should count.
    ///
    /// Cancelled and skipped runs are excluded. Someone hitting cancel says
    /// nothing about whether the pipeline works, so counting it would drag the
    /// rate down for a reason the number does not claim to be about.
    public var countsTowardHealth: Bool {
        switch self {
        case .success, .failure, .actionRequired: return true
        case .queued, .running, .cancelled, .skipped, .neutral, .unknown: return false
        }
    }

    /// Whether this state is worth interrupting the user with.
    public var isBad: Bool { self == .failure || self == .actionRequired }

    /// The SF Symbol every surface draws for this state.
    public var systemImage: String {
        switch self {
        case .queued:         return "clock"
        case .running:        return "circle.dashed"
        case .success:        return "checkmark.circle.fill"
        case .failure:        return "xmark.circle.fill"
        case .cancelled:      return "slash.circle.fill"
        case .skipped:        return "minus.circle.fill"
        case .actionRequired: return "exclamationmark.triangle.fill"
        case .neutral:        return "circle.fill"
        case .unknown:        return "questionmark.circle.fill"
        }
    }

    /// Spoken and written name, sentence case per the design guidelines.
    public var label: String {
        switch self {
        case .queued:         return "Queued"
        case .running:        return "Running"
        case .success:        return "Passed"
        case .failure:        return "Failed"
        case .cancelled:      return "Cancelled"
        case .skipped:        return "Skipped"
        case .actionRequired: return "Action required"
        case .neutral:        return "Neutral"
        case .unknown:        return "Unknown"
        }
    }
}

// MARK: - Workflow run

/// One run of one workflow.
public struct WorkflowRun: Codable, Hashable, Identifiable, Sendable {
    /// GitHub's run id.
    public let id: Int
    /// The workflow's display name, for example `CI`.
    public let workflowName: String
    /// The branch the run was triggered on.
    public let branch: String
    /// What triggered it: `push`, `pull_request`, `schedule`.
    public let event: String
    /// The incrementing run number GitHub shows in its UI.
    public let runNumber: Int
    /// Collapsed status.
    public let state: RunState
    /// When the run was created.
    public let createdAt: Date
    /// When it last changed, which for a finished run is when it finished.
    public let updatedAt: Date
    /// When the run actually started, which is later than `createdAt` when it
    /// waited for a runner.
    public let startedAt: Date?
    /// The run's page on github.com.
    public let htmlURL: URL?

    public init(
        id: Int,
        workflowName: String,
        branch: String,
        event: String,
        runNumber: Int,
        state: RunState,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date?,
        htmlURL: URL?
    ) {
        self.id = id
        self.workflowName = workflowName
        self.branch = branch
        self.event = event
        self.runNumber = runNumber
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.htmlURL = htmlURL
    }

    /// How long the run took, or has taken so far.
    ///
    /// `now` is a parameter rather than `Date()` so a view that redraws on a
    /// published clock gets the same answer the clock says, and so the value
    /// is testable.
    public func duration(now: Date = Date()) -> TimeInterval {
        let start = startedAt ?? createdAt
        let end = state.isActive ? now : updatedAt
        return max(0, end.timeIntervalSince(start))
    }
}

// MARK: - Snapshot

/// Everything known about one repository at one moment: its recent runs on the
/// default branch, and the health they add up to.
public struct RepoSnapshot: Codable, Hashable, Identifiable, Sendable {
    /// The repository.
    public let ref: RepoRef
    /// The branch the runs were read from.
    public let branch: String
    /// Recent runs, newest first.
    public let runs: [WorkflowRun]
    /// When this was read from GitHub.
    public let fetchedAt: Date
    /// The last error against this repository, or `nil` when the read
    /// succeeded. Kept per repository so one bad name does not blank the
    /// widget for the other four.
    public let failureMessage: String?

    public var id: String { ref.id }

    public init(
        ref: RepoRef,
        branch: String,
        runs: [WorkflowRun],
        fetchedAt: Date,
        failureMessage: String? = nil
    ) {
        self.ref = ref
        self.branch = branch
        self.runs = runs
        self.fetchedAt = fetchedAt
        self.failureMessage = failureMessage
    }

    /// The newest run, active or not.
    public var latest: WorkflowRun? { runs.first }

    /// The newest run still going, if any. This is what the live activity
    /// rides on.
    public var activeRun: WorkflowRun? { runs.first { $0.state.isActive } }

    /// The newest run that reached a conclusion, across every workflow.
    public var latestSettled: WorkflowRun? { runs.first { !$0.state.isActive } }

    /// The newest settled run of each distinct workflow, newest first.
    ///
    /// A repository does not have one pipeline, it has several: a build, a
    /// nightly fuzz run, a bot that triages issues. Reading the repository's
    /// single newest run as its state means a failing issue-triage bot paints
    /// the build red, and a green bot paints a broken build green — whichever
    /// happened to finish last. Each workflow keeps its own verdict instead,
    /// and the row reports the worst of them.
    public var latestPerWorkflow: [WorkflowRun] {
        var seen: Set<String> = []
        var result: [WorkflowRun] = []
        for run in runs where !run.state.isActive {
            guard seen.insert(run.workflowName).inserted else { continue }
            result.append(run)
        }
        return result
    }

    /// The workflows whose newest run did not pass.
    public var failingWorkflows: [WorkflowRun] {
        latestPerWorkflow.filter { $0.state.isBad }
    }

    /// The run a row is about.
    ///
    /// Every column in a row has to describe the same run, or the row lies: a
    /// glyph that reports a broken issue-triage bot beside an elapsed time
    /// that belongs to a build still running reads as "the build is broken and
    /// has been for two minutes". Broken first, then whatever is in flight,
    /// then the newest standing verdict.
    public var subject: WorkflowRun? {
        failingWorkflows.first ?? activeRun ?? latestPerWorkflow.first
    }

    /// The state the repository row reads as: the worst standing verdict
    /// across its workflows, or the run in flight when there is one and
    /// nothing is broken.
    public var state: RunState {
        if let failure = failingWorkflows.first { return failure.state }
        if let active = activeRun { return active.state }
        guard !latestPerWorkflow.isEmpty else { return .unknown }
        return latestPerWorkflow.contains { $0.state == .success } ? .success : .neutral
    }

    /// Runs that count toward health, newest first.
    public var healthRuns: [WorkflowRun] { runs.filter { $0.state.countsTowardHealth } }

    /// Share of counted runs that passed, or `nil` when none did yet.
    public var successRate: Double? {
        let counted = healthRuns
        guard !counted.isEmpty else { return nil }
        let passed = counted.filter { $0.state == .success }.count
        return Double(passed) / Double(counted.count)
    }

    /// Median wall-clock duration of counted runs, which resists the one
    /// twenty-minute outlier a mean does not.
    public var medianDuration: TimeInterval? {
        let durations = healthRuns.map { $0.duration() }.sorted()
        guard !durations.isEmpty else { return nil }
        let middle = durations.count / 2
        if durations.count.isMultiple(of: 2) {
            return (durations[middle - 1] + durations[middle]) / 2
        }
        return durations[middle]
    }

    /// How many of this repository's workflows are currently passing, out of
    /// how many have a standing verdict at all.
    public var passingWorkflows: (passing: Int, total: Int) {
        let verdicts = latestPerWorkflow.filter { $0.state.countsTowardHealth }
        return (verdicts.filter { $0.state == .success }.count, verdicts.count)
    }
}
