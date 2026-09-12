//
//  WorkflowMonitor.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  The model every surface reads. It owns the watch list, the poll loop, and
//  the one piece of state that is not just "what GitHub said": which runs
//  finished since the last poll, because that is what a HUD is for.
//
//  Main-actor isolated, like the droplet that owns it. The network work is not
//  here — that is the client's actor — so nothing on this actor blocks.
//

import Combine
import DroppyKit
import Foundation

// MARK: - Transition

/// A run that reached a conclusion between two polls.
///
/// ``wasWatched`` is what the HUD keys on. A run this droplet saw start and
/// then finish is worth reporting. A run that both started and finished while
/// the Mac was asleep already happened, and announcing it means the user gets
/// a burst of stale HUDs every time they open the lid.
public struct RunTransition: Sendable {
    /// Which repository.
    public let ref: RepoRef
    /// The run that finished.
    public let run: WorkflowRun
    /// The state of the previous settled run, or `nil` when there was none.
    public let previousState: RunState?
    /// Whether this droplet watched the run while it was going.
    public let wasWatched: Bool

    /// A run that went from failing to passing. The one transition worth
    /// interrupting a user with good news for.
    public var isRecovery: Bool {
        run.state == .success && (previousState?.isBad ?? false)
    }
}

// MARK: - Token state

/// What is known about the stored token.
public enum TokenState: Equatable, Sendable {
    /// Nothing saved yet.
    case missing
    /// Saved, never exercised this session.
    case unverified
    /// A request succeeded; carries the login it belongs to.
    case valid(login: String)
    /// A request was refused; carries the sentence to show.
    case invalid(message: String)

    /// Whether polling is worth attempting.
    public var isUsable: Bool {
        switch self {
        case .missing, .invalid: return false
        case .unverified, .valid: return true
        }
    }
}

// MARK: - Monitor

/// Watches a list of repositories and keeps their recent runs current.
@MainActor
public final class WorkflowMonitor: ObservableObject {

    // MARK: Published state

    /// One snapshot per watched repository, in the user's order. A repository
    /// that has never been read successfully is still present, carrying its
    /// failure message, so the widget can say which one is broken.
    @Published public private(set) var snapshots: [RepoSnapshot] = []

    /// Whether a poll is in flight, for the widget's refresh control.
    @Published public private(set) var isRefreshing = false

    /// When the last poll completed, successfully or not.
    @Published public private(set) var lastRefresh: Date?

    /// The quota headers from the most recent response.
    @Published public private(set) var rateLimit: RateLimit?

    /// What is known about the token.
    @Published public private(set) var tokenState: TokenState = .missing

    /// Jobs and their steps, keyed by run id.
    ///
    /// Fetched narrowly. A run's jobs are a second request, so this covers the
    /// run in flight and the run that went red, which are the two a surface
    /// ever names a step for, plus whatever the takeover asks for while it is
    /// open. The twenty settled runs behind them are never fetched.
    @Published public private(set) var jobsByRun: [Int: [WorkflowJob]] = [:]

    /// A published clock, so elapsed durations tick without a timer per view.
    ///
    /// It ticks every second only while a run is in flight, which is the only
    /// time a surface counts in seconds. A settled list advances it once per
    /// poll instead, which is all the "3m ago" column needs and costs the
    /// shelf no redraws in between.
    @Published public private(set) var now = Date()

    // MARK: Preferences

    /// The watch list. Writing it re-reads immediately, because a user who
    /// just added a repository is looking at the widget.
    public var repos: [RepoRef] {
        get {
            if isSample { return SampleData.repos }
            return host?.preferences.value(forKey: Keys.repos, as: [RepoRef].self) ?? []
        }
        set {
            host?.preferences.setValue(newValue, forKey: Keys.repos)
            reconcileSnapshots(with: newValue)
            refreshSoon()
        }
    }

    /// Seconds between polls when nothing is running. Clamped to the range the
    /// quota can actually sustain.
    public var interval: TimeInterval {
        get {
            let stored = host?.preferences.value(forKey: Keys.interval, as: Double.self) ?? Defaults.interval
            return min(max(stored, Limits.minimumInterval), Limits.maximumInterval)
        }
        set {
            let clamped = min(max(newValue, Limits.minimumInterval), Limits.maximumInterval)
            host?.preferences.setValue(clamped, forKey: Keys.interval)
            refreshSoon()
        }
    }

    /// Whether a failed run raises a HUD.
    public var announcesFailures: Bool {
        get { host?.preferences.value(forKey: Keys.hudOnFailure, default: true) ?? true }
        set { host?.preferences.setValue(newValue, forKey: Keys.hudOnFailure) }
    }

    /// Whether a branch going green again raises a HUD.
    public var announcesRecoveries: Bool {
        get { host?.preferences.value(forKey: Keys.hudOnRecovery, default: true) ?? true }
        set { host?.preferences.setValue(newValue, forKey: Keys.hudOnRecovery) }
    }

    // MARK: Derived

    /// Snapshots ordered by how much they want attention: failures first, then
    /// runs in flight, then everything else in the user's order.
    ///
    /// The widget shows the first few rows and the shelf is small, so the
    /// ordering decides what the user sees. A broken pipeline that sorts below
    /// the fold never gets looked at.
    public var attentionOrdered: [RepoSnapshot] {
        snapshots.enumerated()
            .sorted { lhs, rhs in
                let left = Self.attentionRank(lhs.element)
                let right = Self.attentionRank(rhs.element)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func attentionRank(_ snapshot: RepoSnapshot) -> Int {
        if snapshot.failureMessage != nil { return 1 }
        switch snapshot.state {
        case .failure, .actionRequired: return 0
        case .queued, .running:         return 2
        case .success:                  return 3
        default:                        return 4
        }
    }

    /// Every run currently in flight, newest first. This is what the live
    /// activity rides on.
    public var activeRuns: [(ref: RepoRef, run: WorkflowRun)] {
        snapshots
            .compactMap { snapshot in snapshot.activeRun.map { (snapshot.ref, $0) } }
            .sorted { $0.run.createdAt > $1.run.createdAt }
    }

    /// Repositories whose branch is currently red.
    public var failingCount: Int {
        snapshots.filter { $0.state.isBad }.count
    }

    /// The one-line state of the whole watch list, for the paired widget and
    /// the live activity's accessibility label.
    public var headline: Headline {
        if snapshots.isEmpty { return .empty }
        if case .missing = tokenState { return .needsToken }
        if case .invalid(let message) = tokenState { return .broken(message) }
        if !activeRuns.isEmpty { return .running(activeRuns.count) }
        if failingCount > 0 { return .failing(failingCount) }
        if snapshots.allSatisfy({ $0.failureMessage != nil }) {
            return .broken(snapshots.first?.failureMessage ?? "No repositories could be read.")
        }
        return .green(snapshots.count)
    }

    /// The whole watch list, as one state.
    public enum Headline: Equatable, Sendable {
        /// Nothing is being watched yet.
        case empty
        /// No token saved.
        case needsToken
        /// Nothing could be read; carries the sentence to show.
        case broken(String)
        /// Runs in flight.
        case running(Int)
        /// Branches currently red.
        case failing(Int)
        /// Everything watched is passing.
        case green(Int)
    }

    // MARK: Private state

    // `DropletHost` is a struct of service existentials, so it is held
    // strongly and released in `stop()`, exactly as the example droplet does.
    private var host: DropletHost?
    private let client = GitHubClient()

    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    /// Bumped to wake the poll loop out of its sleep early.
    private var pollGeneration = 0

    /// The settled run id last seen per workflow, which is the baseline a
    /// transition is measured against. Keyed per workflow rather than per
    /// repository: a repository runs several pipelines, and collapsing them
    /// means every finished bot run looks like the build changing state.
    private var lastSettledRunID: [String: Int] = [:]
    /// The settled state last seen per workflow, so a recovery can be told
    /// from a first pass.
    private var lastSettledState: [String: RunState] = [:]
    /// Run ids seen in flight, so a finished run can say whether it was
    /// watched.
    private var watchedRunIDs: Set<Int> = []

    /// Called for every run that finished between two polls.
    public var onTransition: ((RunTransition) -> Void)?

    // MARK: Lifecycle

    public init() {}

    /// Wires the monitor to the host and starts polling.
    public func start(host: DropletHost) {
        self.host = host

        let token = TokenStore.read()
        hasStoredToken = token != nil

        // Without a sample the harness renders every surface empty and the
        // shots show nothing worth checking. The gate is an empty watch list
        // rather than a missing token: a developer who saves a real token to
        // exercise the network still has no repositories configured, and
        // gating on the token meant that one save blinded every preview for
        // good. It never runs inside Droppy, where showing repositories the
        // user never added would be straightforwardly wrong.
        //
        // The live activity needs this more than the other surfaces do. It
        // only publishes while a run is in flight, so without the sample there
        // is nothing to look at unless a real workflow happens to be running
        // at the moment the shots are taken.
        if host.environment.isHarness, repos.isEmpty {
            isSample = true
            snapshots = SampleData.snapshots()
            jobsByRun = SampleData.jobs()
            tokenState = .valid(login: "harness")
            startClock()
            announceSample()
            return
        }

        loadCachedSnapshots()
        reconcileSnapshots(with: repos)

        tokenState = token == nil ? .missing : .unverified
        // One task, in order. Two meant the first poll could reach the client
        // before the token did, and every repository came back "Add a GitHub
        // token to start watching repositories" until the next poll.
        Task { [weak self, client] in
            await client.setToken(token)
            self?.startPolling()
        }
    }

    /// Whether the snapshots on screen are the harness sample rather than
    /// anything GitHub said.
    public private(set) var isSample = false

    /// Stops every timer and task. After this the monitor is inert.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        clockTask?.cancel()
        clockTask = nil
        onTransition = nil
        host = nil
    }

    // MARK: Token

    /// Drops the harness sample once there is a real repository to show.
    ///
    /// Without this the sample latches: `repos` keeps answering with the
    /// sample list, so a repository added in the harness is appended to
    /// `SampleData.repos` and written to preferences, and `poll()` returns
    /// early forever.
    private func leaveSampleMode() {
        guard isSample else { return }
        isSample = false
        snapshots = []
        lastSettledRunID.removeAll()
        lastSettledState.removeAll()
        watchedRunIDs.removeAll()
        loadCachedSnapshots()
        reconcileSnapshots(with: repos)
    }

    /// Saves a token, verifies it against `/user`, and re-polls.
    ///
    /// Verification is not ceremony: a mistyped token otherwise shows up as
    /// five repositories that all say "no such repository", which sends the
    /// user looking for the wrong problem.
    public func setToken(_ token: String?) async {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed

        // Only a real watch list ends the sample now. Saving a token while
        // nothing is watched leaves the sample up, which is what makes the
        // harness still previewable after you paste one in.
        if value != nil, !repos.isEmpty {
            leaveSampleMode()
            startPolling()
        }
        TokenStore.write(value)
        hasStoredToken = TokenStore.exists()
        await client.setToken(value)

        guard value != nil else {
            tokenState = .missing
            snapshots = snapshots.map {
                RepoSnapshot(ref: $0.ref, branch: $0.branch, runs: [], fetchedAt: Date(),
                             failureMessage: GitHubError.noToken.message)
            }
            return
        }

        await verifyToken()
        refreshSoon()
    }

    /// Exercises the stored token and records what came back.
    @discardableResult
    public func verifyToken() async -> TokenState {
        guard await client.hasToken() else {
            tokenState = .missing
            return tokenState
        }
        do {
            let login = try await client.verifyToken()
            tokenState = .valid(login: login)
        } catch let error as GitHubError {
            tokenState = .invalid(message: error.message)
        } catch {
            tokenState = .invalid(message: error.localizedDescription)
        }
        rateLimit = await client.currentRateLimit()
        return tokenState
    }

    /// Whether a token is stored, for the settings pane's field placeholder
    /// and the widget's empty state.
    ///
    /// Published rather than computed. Both readers are view bodies, and
    /// `TokenStore.exists()` is a synchronous keychain query: asking it from a
    /// body meant one `SecItemCopyMatching` per render pass of a widget that
    /// redraws on hover.
    @Published public private(set) var hasStoredToken = false

    // MARK: Watch list

    /// Adds a repository if it parses and is not already watched.
    ///
    /// - Returns: the parsed reference, or `nil` when the text was not a
    ///   repository.
    @discardableResult
    public func addRepo(_ text: String) -> RepoRef? {
        guard let ref = RepoRef(parsing: text) else { return nil }
        // Before reading `repos`, or the sample list is what gets appended to
        // and written back to preferences.
        leaveSampleMode()
        var list = repos
        guard !list.contains(ref) else { return ref }
        list.append(ref)
        repos = list
        return ref
    }

    /// Stops watching a repository and forgets everything cached about it.
    public func removeRepo(_ ref: RepoRef) {
        leaveSampleMode()
        repos = repos.filter { $0 != ref }
        let prefix = "\(ref.id)|"
        for key in lastSettledRunID.keys where key.hasPrefix(prefix) { lastSettledRunID[key] = nil }
        for key in lastSettledState.keys where key.hasPrefix(prefix) { lastSettledState[key] = nil }
        Task { [client] in await client.invalidate(ref) }
    }

    // MARK: Polling

    /// Polls now, out of turn. Safe to call from a button.
    public func refreshSoon() {
        pollGeneration += 1
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let delay = self.nextDelay()
                let generation = self.pollGeneration
                // Sleep in short steps so `refreshSoon()` is felt immediately
                // rather than after a minute. Cheap: this wakes once a second
                // to compare two integers.
                var slept: TimeInterval = 0
                while slept < delay, !Task.isCancelled, self.pollGeneration == generation {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    slept += 1
                }
            }
        }
    }

    /// How long to wait before the next poll.
    ///
    /// Three cadences, and each one is a quota decision. A run in flight is
    /// worth 15 seconds because the user is watching it. A settled list is
    /// worth the interval they chose. A spent quota is worth waiting for the
    /// window to roll over, because every request until then is refused
    /// anyway.
    private func nextDelay() -> TimeInterval {
        if let limit = rateLimit, limit.isNearlySpent {
            return max(Limits.minimumInterval, limit.resetsAt.timeIntervalSinceNow + 5)
        }
        if case .invalid = tokenState { return Limits.maximumInterval }
        if case .missing = tokenState { return Limits.maximumInterval }
        if !activeRuns.isEmpty { return Limits.activeInterval }
        return interval
    }

    private func poll() async {
        guard !isSample else { return }
        let watched = repos
        guard !watched.isEmpty else {
            snapshots = []
            isRefreshing = false
            return
        }
        guard tokenState.isUsable else {
            isRefreshing = false
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // Sequential rather than a task group: five repositories against one
        // rate limit is not a throughput problem, and a group would fire five
        // requests at the instant the quota headers say to stop.
        var fresh: [RepoSnapshot] = []
        fresh.reserveCapacity(watched.count)
        for ref in watched {
            guard !Task.isCancelled else { return }
            fresh.append(await client.snapshot(for: ref))
        }

        rateLimit = await client.currentRateLimit()
        lastRefresh = Date()

        // A token that was merely saved is proven by the first successful read,
        // which saves a `/user` request on every launch.
        if case .unverified = tokenState, fresh.contains(where: { $0.failureMessage == nil }) {
            tokenState = .valid(login: "")
        }
        if let refusal = fresh.compactMap(\.failureMessage).first,
           refusal == GitHubError.unauthorized.message {
            tokenState = .invalid(message: refusal)
        }

        // Jobs before transitions, so the HUD that a failure raises can name
        // the step that broke. The other order left it announcing a workflow
        // name it already had, and the steps arrived a moment after the HUD
        // had been built.
        await refreshJobs(for: fresh)
        emitTransitions(for: fresh)
        snapshots = fresh
        cacheSnapshots(fresh)
        updateClock()
    }

    // MARK: Jobs

    /// Which runs are worth a jobs request: the one in flight, because its
    /// current step changes under the user, and the one that went red, because
    /// naming the step that broke is the whole point of reading them.
    private func runsNeedingJobs(in snapshots: [RepoSnapshot]) -> [(RepoRef, WorkflowRun)] {
        snapshots.flatMap { snapshot -> [(RepoRef, WorkflowRun)] in
            var wanted: [WorkflowRun] = []
            if let active = snapshot.activeRun { wanted.append(active) }
            if let broken = snapshot.failingWorkflows.first { wanted.append(broken) }
            return wanted.map { (snapshot.ref, $0) }
        }
    }

    private func refreshJobs(for snapshots: [RepoSnapshot]) async {
        guard !isSample else { return }
        let wanted = runsNeedingJobs(in: snapshots)

        for (ref, run) in wanted {
            guard !Task.isCancelled else { return }
            // A settled run's jobs cannot change, so read them once and keep
            // them. An active run is re-read every poll, and the ETag makes
            // that free when nothing moved.
            if !run.state.isActive, jobsByRun[run.id] != nil { continue }
            if let jobs = try? await client.jobs(forRun: run.id, in: ref) {
                jobsByRun[run.id] = jobs
            }
        }

        // Drop runs nothing points at any more, or a long session accumulates
        // the jobs of every run that ever passed through.
        let live = Set(snapshots.flatMap { $0.runs.map(\.id) })
        jobsByRun = jobsByRun.filter { live.contains($0.key) }
    }

    /// Reads one run's jobs on demand, for a surface the user just opened.
    public func loadJobs(for run: WorkflowRun, in ref: RepoRef) {
        guard !isSample, jobsByRun[run.id] == nil || run.state.isActive else { return }
        Task { [weak self, client] in
            guard let jobs = try? await client.jobs(forRun: run.id, in: ref) else { return }
            self?.jobsByRun[run.id] = jobs
        }
    }

    /// The jobs of a run, or an empty array while they are still being read.
    public func jobs(for run: WorkflowRun?) -> [WorkflowJob] {
        guard let run else { return [] }
        return jobsByRun[run.id] ?? []
    }

    // MARK: Transitions

    private func emitTransitions(for fresh: [RepoSnapshot]) {
        var stillActive: Set<Int> = []

        for snapshot in fresh {
            for run in snapshot.runs where run.state.isActive {
                stillActive.insert(run.id)
            }

            for settled in snapshot.latestPerWorkflow {
                let key = "\(snapshot.ref.id)|\(settled.workflowName)"
                let previousID = lastSettledRunID[key]
                let previousState = lastSettledState[key]

                lastSettledRunID[key] = settled.id
                lastSettledState[key] = settled.state

                // No baseline means this is the first time this workflow has
                // been read. Record it and say nothing: the alternative is a
                // HUD per workflow per repository on every launch.
                guard let previousID, previousID != settled.id else { continue }

                onTransition?(
                    RunTransition(
                        ref: snapshot.ref,
                        run: settled,
                        previousState: previousState,
                        wasWatched: watchedRunIDs.contains(settled.id)
                    )
                )
            }
        }

        watchedRunIDs = stillActive
    }

    /// Replays one finished run through the transition path so the harness's
    /// HUD page has something on it.
    ///
    /// This calls the same `onTransition` the poll loop calls, with a run out
    /// of the sample, so the shot shows the HUD the droplet actually builds
    /// rather than a mock of it. The delay lets activation finish first.
    private func announceSample() {
        guard let failing = snapshots.first?.failingWorkflows.first,
              let ref = snapshots.first?.ref else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.isSample else { return }
            self.onTransition?(
                RunTransition(ref: ref, run: failing, previousState: .success, wasWatched: true)
            )
        }
    }

    // MARK: Clock

    /// Runs a one-second clock only while something is in flight.
    private func updateClock() {
        // Restamp before deciding whether a clock is needed. `now` is what the
        // age column subtracts from, and while nothing is in flight there is
        // no clock task to advance it: without this the column froze at the
        // instant the monitor was built and a run that finished three minutes
        // ago still read "3m" an hour later. A poll is fine-grained enough for
        // a column that prints whole minutes.
        now = Date()
        startClock()
    }

    private func startClock() {
        let needsClock = !activeRuns.isEmpty
        if needsClock, clockTask == nil {
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self else { return }
                    self.now = Date()
                    if self.activeRuns.isEmpty {
                        self.clockTask?.cancel()
                        self.clockTask = nil
                        return
                    }
                }
            }
        } else if !needsClock {
            clockTask?.cancel()
            clockTask = nil
        }
    }

    // MARK: Cache

    /// Where the last poll is kept, so the shelf has something to show the
    /// instant it opens rather than a spinner for however long GitHub takes.
    private var cacheURL: URL? {
        host?.environment.containerDirectory.appendingPathComponent("snapshots.json")
    }

    private func cacheSnapshots(_ snapshots: [RepoSnapshot]) {
        guard let cacheURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshots)
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            host?.log.debug("could not cache snapshots: \(error.localizedDescription)")
        }
    }

    private func loadCachedSnapshots() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode([RepoSnapshot].self, from: data) else { return }
        snapshots = cached

        // The cache is the baseline too. Without this, the first poll after a
        // launch treats every run that finished while Droppy was closed as
        // news and raises a HUD for each.
        for snapshot in cached {
            for settled in snapshot.latestPerWorkflow {
                let key = "\(snapshot.ref.id)|\(settled.workflowName)"
                lastSettledRunID[key] = settled.id
                lastSettledState[key] = settled.state
            }
        }
    }

    /// Makes the snapshot list match the watch list, keeping what is already
    /// known about repositories that stayed.
    private func reconcileSnapshots(with watched: [RepoRef]) {
        let existing = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.ref, $0) })
        snapshots = watched.map { ref in
            existing[ref] ?? RepoSnapshot(ref: ref, branch: "", runs: [], fetchedAt: .distantPast)
        }
    }

    // MARK: Constants

    private enum Keys {
        static let repos = "repos"
        static let interval = "interval"
        static let hudOnFailure = "hudOnFailure"
        static let hudOnRecovery = "hudOnRecovery"
    }

    private enum Defaults {
        static let interval: TimeInterval = 120
    }

    /// The poll cadences, and why each number is what it is.
    public enum Limits {
        /// Nothing polls faster than this. Five repositories at 30 seconds is
        /// 600 requests an hour against a 5000 quota, which leaves room for
        /// the user to actually use the token elsewhere.
        public static let minimumInterval: TimeInterval = 30
        /// The slowest offered. Beyond this the widget is a historical record.
        public static let maximumInterval: TimeInterval = 900
        /// Used while a run is in flight, where the user is watching.
        public static let activeInterval: TimeInterval = 15
    }
}
