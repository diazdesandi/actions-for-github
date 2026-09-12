//
//  NotchViews.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  The two notch surfaces: the live activity that rides beside the camera
//  while a run is going, and the HUD that reports one finishing.
//
//  Both are mini-HUD chrome rather than cards. The numbers come from
//  `DroppyLiveActivityMetrics` rather than from measuring a screenshot, and
//  the HUD strip puts its content at the two outer edges because on a MacBook
//  the middle of that width is the camera housing.
//

import DroppyKit
import SwiftUI

// MARK: - Live activity

/// The leading wing: the repository's state, as one dot.
struct ActivityLeading: View {
    let state: RunState

    var body: some View {
        Image(systemName: state.systemImage)
            .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
            .foregroundStyle(RunPalette.color(for: state))
            .accessibilityHidden(true)
    }
}

/// The trailing wing: how long the run has been going.
struct ActivityTrailing: View {
    let elapsed: TimeInterval

    var body: some View {
        Text(RunFormat.duration(elapsed))
            .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .accessibilityHidden(true)
    }
}

/// The card the compact activity grows into on hover.
///
/// The host has already inset this below the camera housing and inside the
/// shoulders, so nothing here pads for the notch.
struct ActivityCard: View {
    let ref: RepoRef
    let run: WorkflowRun
    let jobs: [WorkflowJob]
    let now: Date
    /// How many other runs are going at the same time, so the card can say so
    /// rather than pretending this is the only one.
    let otherRunCount: Int
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: DroppyLiveActivityMetrics.contentSpacing) {
            Image(systemName: run.state.systemImage)
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                .foregroundStyle(RunPalette.color(for: run.state))

            VStack(alignment: .leading, spacing: 1) {
                Text(ref.name)
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // The workflow's name is on the row above in everything but
                // name; what the user does not know is which step it is on.
                StepLine(jobs: jobs, fallback: subtitle)
            }

            Spacer(minLength: DroppySpacing.sm)

            Text(RunFormat.duration(run.duration(now: now)))
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            // A live activity row is the one place in a droplet that is not
            // Liquid Glass: it is Dynamic Island chrome, and its controls keep
            // the iOS wash, like Droppy's own Pomodoro row.
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward")
            }
            .buttonStyle(DroppyLiveActivityControlStyle())
            .help("Open the run on GitHub")
            .accessibilityLabel("Open the run on GitHub")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown until the jobs arrive, and for a run whose steps cannot be read.
    private var subtitle: String {
        var text = "\(run.workflowName) · \(run.branch)"
        if otherRunCount > 0 {
            text += otherRunCount == 1 ? " · 1 more running" : " · \(otherRunCount) more running"
        }
        return text
    }
}

// MARK: - HUD

/// The strip: a glyph at the far left, the verdict at the far right, nothing
/// in the middle, because on a MacBook the middle is the camera housing.
struct RunHUDStrip: View {
    let state: RunState
    let repoName: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: state.systemImage)
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                .foregroundStyle(RunPalette.color(for: state))

            Spacer(minLength: 0)

            Text(repoName)
                .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The card the strip grows into: which workflow, on which branch, how long it
/// took, and the way to go look at it.
struct RunHUDCard: View {
    let ref: RepoRef
    let run: WorkflowRun
    let jobs: [WorkflowJob]
    /// Spelled out rather than left to inference: the host holds this card's
    /// builder, so the action has to be safe to send and to run on the main
    /// actor when the host rebuilds it.
    let onOpen: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: DroppySpacing.smd) {
            Image(systemName: run.state.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(RunPalette.color(for: run.state))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(run.state.label) · \(ref.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Naming the step that broke is the difference between a HUD
                // the user acts on and one they have to go look something up
                // after.
                StepLine(
                    jobs: jobs,
                    fallback: "\(run.workflowName) · \(run.branch) · \(RunFormat.duration(run.duration()))",
                    showsProgress: false
                )
            }

            Spacer(minLength: DroppySpacing.sm)

            // A HUD is transient notification chrome rather than a prompt,
            // and Droppy's own expanded HUDs keep their buttons neutral. An
            // accent pill flashing on the notch every time CI fails would be
            // louder than the event deserves. The harness renders this as bare
            // text because glass does not composite into its offscreen shots;
            // the SDK's own example renders the same way.
            Button("Open", action: onOpen)
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
