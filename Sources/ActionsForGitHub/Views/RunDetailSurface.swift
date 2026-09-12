//
//  RunDetailSurface.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  The takeover: one run, every job, every step.
//
//  The other surfaces each have room for one step, so they name the one that
//  matters and stop. This is where the whole list goes, because it is the only
//  surface Droppy gives a droplet that is big enough to hold it.
//

import DroppyKit
import SwiftUI

struct RunDetailSurface: View {
    @ObservedObject var monitor: WorkflowMonitor
    let ref: RepoRef
    let run: WorkflowRun
    let context: ExpandedSurfaceContext
    let onOpen: () -> Void
    let onClose: () -> Void

    private var jobs: [WorkflowJob] { monitor.jobs(for: run) }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header

            StepList(jobs: jobs, now: monitor.now, isLoading: jobs.isEmpty && !monitor.isSample)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: run.state.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RunPalette.color(for: run.state))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(ref.name) · \(run.workflowName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: DroppySpacing.sm)

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Open the run on GitHub")
            .accessibilityLabel("Open the run on GitHub")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    private var subtitle: String {
        var parts = ["#\(run.runNumber)", run.branch]
        if run.state.isActive {
            parts.append("running for \(RunFormat.duration(run.duration(now: monitor.now)))")
        } else {
            parts.append("\(run.state.label.lowercased()) in \(RunFormat.duration(run.duration()))")
        }
        if !jobs.isEmpty {
            parts.append(jobs.stepCount == 1 ? "1 step" : "\(jobs.stepCount) steps")
        }
        return parts.joined(separator: " · ")
    }
}
