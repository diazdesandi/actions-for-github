//
//  StepViews.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  Steps, at the two sizes anything here needs them: one line naming the step
//  that matters, and the whole list.
//

import DroppyKit
import SwiftUI

// MARK: - One line

/// Names the step a surface is speaking for, with its position in the job.
///
/// Every surface too small for the list uses this: the live activity's card,
/// the HUD's card, a widget row with a run in flight. Written once so "step 6
/// of 11" means the same thing and counts the same way everywhere.
struct StepLine: View {
    let jobs: [WorkflowJob]
    let fallback: String
    var font: CGFloat = 11
    var showsProgress = true

    private var job: WorkflowJob? { jobs.subject }
    private var step: WorkflowStep? { jobs.subjectStep }

    var body: some View {
        HStack(spacing: DroppySpacing.xs) {
            Text(label)
                .font(.system(size: font))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsProgress, let job, job.steps.count > 1 {
                Text(verbatim: "\(job.progress.done)/\(job.progress.total)")
                    .font(.system(size: font))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
    }

    private var label: String {
        guard let step else { return fallback }
        return step.name
    }

    private var tint: Color {
        guard let step else { return AdaptiveColors.notchSurfaceTertiaryText }
        return step.state.isBad ? RunPalette.fail : AdaptiveColors.notchSurfaceSecondaryText
    }
}

// MARK: - The list

/// Every step of every job, which is what the takeover exists to show.
struct StepList: View {
    let jobs: [WorkflowJob]
    let now: Date
    /// Drawn while the jobs are still being read, so the surface does not flash
    /// an empty list on its way to a full one.
    let isLoading: Bool

    var body: some View {
        if jobs.isEmpty {
            HStack(spacing: DroppySpacing.xsm) {
                if isLoading { ProgressView().controlSize(.small) }
                Text(isLoading ? "Reading steps…" : "No steps to show.")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    ForEach(jobs) { job in
                        // The job's name only earns a row when there is more
                        // than one: a single-job run would otherwise repeat the
                        // workflow name above it for nothing.
                        if jobs.count > 1 {
                            JobHeader(job: job, now: now)
                                .padding(.top, job.id == jobs.first?.id ? 0 : DroppySpacing.xsm)
                        }
                        ForEach(job.steps) { step in
                            StepRow(step: step, now: now)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct JobHeader: View {
    let job: WorkflowJob
    let now: Date

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Text(job.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            Text(verbatim: "\(job.progress.done)/\(job.progress.total)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
    }
}

/// One step: glyph, name, duration.
private struct StepRow: View {
    let step: WorkflowStep
    let now: Date

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: step.state.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RunPalette.color(for: step.state))
                .frame(width: 12)

            Text(step.name)
                .font(.system(size: 12, weight: step.state.isActive ? .medium : .regular))
                .foregroundStyle(
                    step.state == .queued
                        ? AdaptiveColors.notchSurfaceTertiaryText
                        : AdaptiveColors.notchSurfacePrimaryText
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: DroppySpacing.sm)

            // A queued step has no duration to report and prints nothing rather
            // than a zero that would read as "took no time".
            if let duration = step.duration(now: now) {
                Text(RunFormat.duration(duration))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["\(step.name), \(step.state.label.lowercased())"]
        if let duration = step.duration(now: now) {
            parts.append(RunFormat.duration(duration))
        }
        return parts.joined(separator: ", ")
    }
}
