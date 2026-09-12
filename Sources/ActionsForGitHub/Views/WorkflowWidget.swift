//
//  WorkflowWidget.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  The shelf widget, in both layouts.
//
//  Solo and paired are two compositions, not one view at two widths. Solo has
//  room for a row per repository with its recent history beside it; paired has
//  room for the state of the whole list and the names behind it. Both follow
//  the layout every Droppy widget shares: no card, no border, one padding and
//  the host gives the number, the root filling the rectangle, a header row,
//  leading text and trailing numbers.
//

import DroppyKit
import SwiftUI

// MARK: - Root

/// The widget. Branches on `context.isCompact`, never on a width.
struct WorkflowWidget: View {
    @ObservedObject var monitor: WorkflowMonitor
    let context: ShelfWidgetContext
    /// What the refresh control does.
    let onRefresh: () -> Void
    /// What the empty state's button does.
    let onSetUp: () -> Void
    /// What a row's click does.
    let onOpen: (RepoSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header

            if monitor.snapshots.isEmpty {
                emptyState
            } else if context.isCompact {
                CompactBody(monitor: monitor)
            } else {
                SoloBody(monitor: monitor, onOpen: onOpen)
            }

            Spacer(minLength: 0)
        }
        // One padding, and the host supplies the number. Zero under a notch,
        // where the shelf's chrome has already inset the rectangle, so a
        // widget that pads again sits lower and narrower than the built-in
        // beside it. Only the Dynamic Island has an inset, for its arc.
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            // `bolt.horizontal.fill` is a flat squiggle at 12pt and reads as
            // nothing; the upright bolt keeps its shape at header size.
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .medium))
            Text("Actions")
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 0)

            if !context.isCompact {
                if monitor.isRefreshing {
                    // The control's own slot, so the row does not reflow every
                    // time a poll starts.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("Refresh now")
                    .accessibilityLabel("Refresh now")
                }
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text(monitor.hasStoredToken
                 ? "Add a repository to watch its workflow runs."
                 : "Add a GitHub token and a repository to start.")
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            // Permissions and text entry belong in Settings, not on the shelf:
            // a system alert raised over an open shelf is drawn underneath it.
            Button("Set up", action: onSetUp)
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        }
    }
}

// MARK: - Solo

/// A row per repository: state, name, recent history, success rate, age.
private struct SoloBody: View {
    @ObservedObject var monitor: WorkflowMonitor
    let onOpen: (RepoSnapshot) -> Void

    /// The row budget the droplet declared this rectangle's height for. Read
    /// from there rather than restated here, so the two cannot drift and leave
    /// the view drawing seven rows into a rectangle sized for six.
    private var budget: Int { ActionsForGitHubDroplet.SoloLayout.visibleRows }

    private var shown: [RepoSnapshot] {
        Array(monitor.attentionOrdered.prefix(budget))
    }

    private var hidden: Int {
        max(0, monitor.snapshots.count - budget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            ForEach(shown) { snapshot in
                RepoRow(
                    snapshot: snapshot,
                    jobs: monitor.jobs(for: snapshot.subject),
                    now: monitor.now,
                    onOpen: onOpen
                )
            }
            if hidden > 0 {
                Text("\(hidden) more")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
    }
}

/// One repository's line.
private struct RepoRow: View {
    let snapshot: RepoSnapshot
    let jobs: [WorkflowJob]
    let now: Date
    let onOpen: (RepoSnapshot) -> Void

    @State private var isHovering = false

    private var state: RunState { snapshot.state }

    var body: some View {
        Button {
            onOpen(snapshot)
        } label: {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: state.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RunPalette.color(for: state))
                    .frame(width: 13)

                Text(snapshot.ref.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                // Which pipeline this row is about. A repository runs several,
                // and "Thaw is red" sends the user to the wrong one half the
                // time. Named only when it is not simply passing: a green row
                // does not need to say which of four green workflows it means.
                if let subject = snapshot.subject, subject.state != .success {
                    // The workflow when that is all this row knows, the step
                    // once the jobs have been read: "Issue Triage" says where
                    // to look, "Run triage" says what to look at.
                    StepLine(
                        jobs: jobs,
                        fallback: subject.workflowName,
                        showsProgress: subject.state.isActive
                    )
                    .foregroundStyle(
                        subject.state.isBad ? RunPalette.fail : AdaptiveColors.notchSurfaceTertiaryText
                    )
                }

                Spacer(minLength: DroppySpacing.sm)

                if let message = snapshot.failureMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(RunPalette.fail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    RunSparkline(runs: snapshot.runs)

                    Text(RunFormat.rate(snapshot.successRate))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .frame(width: 34, alignment: .trailing)

                    Text(RunFormat.trailing(for: snapshot, now: now))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background {
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                .fill(AdaptiveColors.notchSurfaceCardFill)
                .opacity(isHovering ? 1 : 0)
                .padding(.horizontal, -DroppySpacing.xs)
        }
        .animation(DroppyAnimation.hoverQuick, value: isHovering)
        .help(accessibilityDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityDescription: String {
        if let message = snapshot.failureMessage {
            return "\(snapshot.ref.id). \(message)"
        }
        var parts = ["\(snapshot.ref.id) \(state.label.lowercased())"]
        let broken = snapshot.failingWorkflows
        if !broken.isEmpty {
            parts.append(broken.map(\.workflowName).joined(separator: " and ") + " failing")
        }
        if let run = snapshot.activeRun {
            parts.append("\(run.workflowName) running for \(RunFormat.duration(run.duration(now: now)))")
        }
        let verdicts = snapshot.passingWorkflows
        if verdicts.total > 0 {
            parts.append("\(verdicts.passing) of \(verdicts.total) workflows passing")
        }
        if let rate = snapshot.successRate {
            parts.append("\(Int((rate * 100).rounded())) percent of recent runs passed")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Paired

/// The state of the whole list, then the names behind it.
///
/// The paired rectangle has room for one number, and the number here is how
/// many repositories want attention. The names below it fill the height the
/// solo composition declared, which the shelf gives this one too.
private struct CompactBody: View {
    @ObservedObject var monitor: WorkflowMonitor

    private var headline: WorkflowMonitor.Headline { monitor.headline }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: glyph)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }

            ForEach(notable) { snapshot in
                HStack(spacing: DroppySpacing.xsm) {
                    Image(systemName: snapshot.state.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RunPalette.color(for: snapshot.state))
                        .frame(width: 12)
                    Text(compactLabel(snapshot))
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// In a 215pt slot the workflow name is what the user needs and the repo
    /// name is what they already know, so the broken pipeline wins the space.
    private func compactLabel(_ snapshot: RepoSnapshot) -> String {
        snapshot.subject?.workflowName ?? snapshot.ref.name
    }

    /// The repositories worth naming in a narrow slot: the ones not passing,
    /// and when everything passes, nothing — a list of green names is four
    /// lines that say what the headline already said.
    private var notable: [RepoSnapshot] {
        guard case .green = headline else {
            return Array(monitor.attentionOrdered.filter { $0.state != .success }.prefix(4))
        }
        return []
    }

    private var glyph: String {
        switch headline {
        case .empty, .needsToken: return "bolt.horizontal"
        case .broken:             return "exclamationmark.triangle.fill"
        case .running:            return "circle.dashed"
        case .failing:            return "xmark.circle.fill"
        case .green:              return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch headline {
        case .failing, .broken: return RunPalette.fail
        case .running:          return RunPalette.active
        case .green:            return RunPalette.pass
        case .empty, .needsToken: return RunPalette.idle
        }
    }

    private var title: String {
        switch headline {
        case .empty:            return "No repos"
        case .needsToken:       return "No token"
        case .broken:           return "Error"
        case .running(let n):   return n == 1 ? "1 running" : "\(n) running"
        case .failing(let n):   return n == 1 ? "1 failing" : "\(n) failing"
        case .green:            return "All green"
        }
    }

    private var subtitle: String? {
        switch headline {
        case .empty, .needsToken:
            return "Open settings"
        case .broken(let message):
            return message
        case .green(let count):
            return count == 1 ? "1 repository" : "\(count) repositories"
        case .running, .failing:
            return "of \(monitor.snapshots.count)"
        }
    }
}
