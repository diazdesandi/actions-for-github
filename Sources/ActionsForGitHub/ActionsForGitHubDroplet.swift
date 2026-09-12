//
//  ActionsForGitHubDroplet.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  GitHub Actions on Droppy's surfaces: a board on the shelf, a run in flight
//  beside the notch, and a HUD when one finishes.
//
//  The droplet owns the lifecycle and the mapping from model to surface. The
//  model itself is `WorkflowMonitor`, and every view reads that rather than
//  this, so a surface can be added without this file growing state.
//

import Combine
import DroppyKit
import SwiftUI

// MARK: - Principal

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(ActionsForGitHubPrincipal)
public final class ActionsForGitHubPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { ActionsForGitHubDroplet() }
}

// MARK: - Droplet

/// Watches GitHub Actions workflow runs.
@MainActor
public final class ActionsForGitHubDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "actions-for-github"

    /// The widget's id, used by the descriptor and by `invalidateLayout`.
    static let boardWidget: ShelfWidgetID = "board"

    private var host: DropletHost?

    /// The model every surface reads.
    let monitor = WorkflowMonitor()

    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private var cancellables: Set<AnyCancellable> = []

    /// The run the HUD is currently reporting, so the card knows what to draw
    /// and the "Open" button knows where to go.
    @Published private var hudSubject: RunTransition?
    /// Whether the HUD is showing its card rather than its strip. The droplet
    /// owns this: switching it is a re-present with the same id, never a
    /// dismiss and a second present, which the host would read as two HUDs.
    @Published private var isHUDExpanded = false

    /// The row count the last descriptor was built for, so the shelf is only
    /// asked to re-measure when the height actually changed.
    private var lastDeclaredRowCount = 0

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host

        monitor.onTransition = { [weak self] transition in
            self?.announce(transition)
        }
        monitor.start(host: host)

        // One subscription drives every notch surface. The monitor publishes
        // on the main actor and so does this, so there is no hop between a
        // poll landing and the notch showing it.
        monitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.modelDidChange()
            }
            .store(in: &cancellables)

        lastDeclaredRowCount = declaredRowCount
        publishActivity()

        host.log.info("Actions for GitHub activated, watching \(monitor.snapshots.count) repositories")
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        cancellables.removeAll()
        monitor.stop()
        activitySubject.send(nil)
        host?.hud.dismiss(id: HUD.id)
        hudSubject = nil
        host = nil
    }

    // MARK: Model changes

    private func modelDidChange() {
        publishActivity()

        // The widget's height is a function of how many rows there are, so a
        // repository added or removed is a re-measure. Crossing a threshold,
        // not every poll: a widget that re-measures continuously is a shelf
        // that never settles.
        let rows = declaredRowCount
        guard rows != lastDeclaredRowCount else { return }
        lastDeclaredRowCount = rows
        host?.shelf.invalidateLayout(for: Self.boardWidget)
    }

    // MARK: Actions

    /// Polls out of turn, from the widget's refresh control.
    func refreshNow() {
        monitor.refreshSoon()
        host?.feedback.play(.tick)
    }

    /// Sends the user to this droplet's own page in Droppy's Settings.
    ///
    /// The shelf has no business holding a token field, and a system alert
    /// raised over an open shelf is drawn underneath it.
    func openSettings() {
        guard host?.workspace.openSettings() == true else {
            host?.log.notice("the host refused to open settings")
            return
        }
    }

    /// Opens a URL through the host rather than through `NSWorkspace`: the
    /// host is what holds the `network-client` grant and what logs the refusal.
    func open(_ url: URL?) {
        guard let url else { return }
        if host?.workspace.open(url) != true {
            host?.log.notice("the host refused to open \(url.absoluteString)")
        }
    }

    /// Opens whatever a widget row points at: the newest run when there is
    /// one, the repository otherwise.
    func open(_ snapshot: RepoSnapshot) {
        open(snapshot.latest?.htmlURL ?? snapshot.ref.webURL)
    }

    // MARK: Layout

    /// How many rows the widget will draw, which is what its height is a
    /// function of.
    private var declaredRowCount: Int {
        let watched = monitor.snapshots.count
        guard watched > 0 else { return 0 }
        let shown = min(watched, SoloLayout.visibleRows)
        return watched > SoloLayout.visibleRows ? shown + 1 : shown
    }

    /// The rectangle's height, derived rather than guessed.
    ///
    /// Stated as an arithmetic of the tokens the view actually lays out with,
    /// so a change to the row height is one number in one place instead of a
    /// magic constant here that drifts away from the view.
    private var declaredHeight: CGFloat {
        let rows = declaredRowCount
        guard rows > 0 else { return SoloLayout.emptyHeight }
        let content = CGFloat(rows) * SoloLayout.rowHeight
                    + CGFloat(max(0, rows - 1)) * DroppySpacing.xsm
        return SoloLayout.chromeHeight + content
    }

    /// The numbers the widget's rectangle is built from.
    ///
    /// The view lays out against these too, so the declared height and the
    /// drawn height cannot drift apart.
    enum SoloLayout {
        /// Rows before the overflow count takes the last slot.
        static let visibleRows = 6
        /// One repository line.
        static let rowHeight: CGFloat = 18
        /// Padding on both edges, the header row, and the gap below it.
        static let chromeHeight: CGFloat = DroppySpacing.mdl * 2 + 16 + DroppySpacing.sm
        /// The empty state: two lines of copy and a button.
        static let emptyHeight: CGFloat = 104
    }

    // MARK: HUD

    private enum HUD {
        /// One id for every announcement. A second request with the same id
        /// replaces the first in place, which is what makes the strip morph
        /// into the card on the host's own spring.
        static let id = "actions-for-github.run"
    }

    /// Reports a finished run in the notch, when it is worth reporting.
    ///
    /// The three guards below each block a different way this surface gets
    /// annoying: reporting a run that finished while the Mac was asleep,
    /// reporting a run that passed exactly like the twenty before it, and
    /// reporting anything at all after the user turned announcements off.
    private func announce(_ transition: RunTransition) {
        guard let host else { return }

        let isFailure = transition.run.state.isBad
        let isRecovery = transition.isRecovery

        guard isFailure || isRecovery else { return }
        guard isFailure ? monitor.announcesFailures : monitor.announcesRecoveries else { return }
        // A failure is worth reporting whether or not this droplet watched it
        // happen — it is still red now. A recovery is only news if the droplet
        // saw the run that fixed it.
        guard isFailure || transition.wasWatched else { return }

        hudSubject = transition
        // A failure earns the card: which workflow, on which branch, and a way
        // to go look at it. A recovery is one fact and earns the strip.
        isHUDExpanded = isFailure
        host.feedback.play(isFailure ? .failure : .success)
        presentHUD()
    }

    /// Puts the current announcement on the notch, in whichever shape
    /// `isHUDExpanded` says.
    private func presentHUD() {
        guard let host, let transition = hudSubject else { return }

        let ref = transition.ref
        let run = transition.run
        let expanded = isHUDExpanded
        // The content builders are held by the host and rebuilt on its own
        // render passes, so they capture values rather than `self`: a closure
        // that read the droplet would pin it for as long as the host kept the
        // request.
        let openURL = run.htmlURL ?? ref.webURL
        // Built out here so the view builder captures this closure rather than
        // the droplet. A builder that mentions `self` anywhere captures it
        // strongly for as long as the host keeps the request, weak capture
        // inside it or not.
        let openRun: @MainActor @Sendable () -> Void = { [weak self] in self?.open(openURL) }

        let request = DropletHUDRequest(
            id: HUD.id,
            duration: expanded ? 6.0 : 4.0,
            priority: run.state.isBad ? .high : .normal,
            accessibilityLabel: "\(ref.id): \(run.workflowName) \(run.state.label.lowercased())"
                              + " on \(run.branch) after \(RunFormat.duration(run.duration()))",
            isExpanded: expanded,
            expandedContentHeight: 56
        ) {
            RunHUDStrip(state: run.state, repoName: ref.name)
        } expanded: {
            RunHUDCard(ref: ref, run: run, onOpen: openRun)
        }

        guard host.hud.present(request) else {
            host.log.notice("the host refused the run HUD")
            return
        }
    }

    // MARK: Live activity

    /// Republishes the activity state from the current model.
    ///
    /// Publishing is a request. The host decides which activity wins the
    /// compact seat, and today's shipping Droppy awards it to no external
    /// droplet at all. Publishing regardless costs nothing and means the
    /// droplet already works on the build where the host does award one.
    private func publishActivity() {
        let active = monitor.activeRuns
        guard let first = active.first else {
            activitySubject.send(nil)
            return
        }

        let elapsed = first.run.duration(now: monitor.now)
        let others = active.count - 1
        var label = "\(first.ref.name): \(first.run.workflowName) running"
        if others > 0 { label += ", \(others) more running" }

        activitySubject.send(
            LiveActivityState(
                // Below the host's own bands. A build finishing is not a phone
                // call, and a droplet that claims otherwise is a droplet the
                // user turns off.
                priority: 100,
                accessibilityTitle: label,
                isInteractive: true,
                compactPresentation: CompactLiveActivityPresentationMetadata(
                    id: "run-\(first.run.id)",
                    accessibilityLabel: label,
                    accessibilityValue: RunFormat.duration(elapsed)
                )
            )
        )
    }
}

// MARK: - Shelf widget

extension ActionsForGitHubDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.boardWidget,
                title: "Actions",
                systemImage: "bolt.fill",
                layoutTraits: ShelfWidgetLayoutTraits(
                    // The CARD, in points at the Regular shelf size: the area
                    // the view draws in. Both widths are required; the host
                    // refuses a descriptor that leaves either to a fallback.
                    // The height holds in a paired row too, which is why the
                    // compact composition fills it rather than centring one
                    // number in it.
                    preferredSoloWidth: 430,
                    preferredPairedWidth: 215,
                    contentHeight: .fixed(declaredHeight)
                ),
                searchKeywords: ["github", "actions", "ci", "workflow", "build", "pipeline"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(
            WorkflowWidget(
                monitor: monitor,
                context: context,
                onRefresh: { [weak self] in self?.refreshNow() },
                onSetUp: { [weak self] in self?.openSettings() },
                onOpen: { [weak self] snapshot in self?.open(snapshot) }
            )
        )
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? {
        AnyView(
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                Text("Actions")
                    .font(.system(size: 12, weight: .semibold))

                if let limit = monitor.rateLimit {
                    Text("\(limit.remaining) of \(limit.limit) requests left this hour")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let last = monitor.lastRefresh {
                    Text("Checked \(RunFormat.age(last, now: monitor.now)) ago")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Button("Open settings") { [weak self] in self?.openSettings() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            .padding(DroppySpacing.md)
        )
    }
}

// MARK: - Live activity

extension ActionsForGitHubDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {
        host?.log.debug("live activity seat: \(seat)")
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(ActivityLeading(state: monitor.activeRuns.first?.run.state ?? .running))
    }

    public func makeCompactTrailing() -> AnyView {
        let elapsed = monitor.activeRuns.first?.run.duration(now: monitor.now) ?? 0
        return AnyView(ActivityTrailing(elapsed: elapsed))
    }

    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        let active = monitor.activeRuns
        guard let first = active.first else { return AnyView(EmptyView()) }
        return AnyView(
            ActivityCard(
                ref: first.ref,
                run: first.run,
                now: monitor.now,
                otherRunCount: active.count - 1,
                onOpen: { [weak self] in
                    self?.open(first.run.htmlURL ?? first.ref.webURL)
                }
            )
        )
    }
}

// MARK: - HUD

/// A marker: it declares that this droplet presents HUDs, which is what lets
/// the host and the harness match the `hud` surface in droplet.json against
/// something in the code. The presenting itself goes through
/// ``DropletHUDService``, not through a requirement here.
extension ActionsForGitHubDroplet: HUDPresenting {}

// MARK: - Settings pane

extension ActionsForGitHubDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(
            ActionsSettingsPane(
                monitor: monitor,
                context: context,
                onOpen: { [weak self] url in self?.open(url) }
            )
        )
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(
                title: "GitHub token",
                keywords: ["github", "token", "pat", "actions", "keychain"]
            ),
            SettingsSearchEntry(
                title: "Watched repositories",
                keywords: ["github", "repository", "repo", "workflow", "ci"]
            )
        ]
    }
}
