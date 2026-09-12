//
//  SettingsPane.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  The droplet's page in Droppy's Settings: the token, the watch list, the
//  cadence, and what gets announced.
//
//  Built from the settings kit rather than from plain SwiftUI rows, so it
//  matches every native page and keeps matching after Droppy's styling moves.
//  It is also the only surface here with text entry. The shelf closes a moment
//  after the pointer leaves it, which makes it a poor place to type a token.
//

import DroppyKit
import SwiftUI

struct ActionsSettingsPane: View {
    @ObservedObject var monitor: WorkflowMonitor
    let context: SettingsPaneContext
    /// Opens a URL through the host, which is the only sanctioned way out.
    let onOpen: (URL) -> Void

    @State private var tokenField = ""
    @State private var repoField = ""
    @State private var repoFieldError: String?
    @State private var isVerifying = false
    @State private var intervalMinutes: Double = 2

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            accountCard
            repositoriesCard
            cadenceCard
            announcementsCard
        }
        .onAppear {
            intervalMinutes = monitor.interval / 60
        }
    }

    // MARK: Account

    private var accountCard: some View {
        DropletSettingsCard {
            DropletStackedRow(
                title: "GitHub token",
                icon: "key.fill",
                infoTip: "A fine-grained personal access token with read access to Actions, "
                       + "or a classic token with the repo scope. It is kept in your keychain, "
                       + "never in Droppy's preferences."
            ) {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    HStack(spacing: DroppySpacing.sm) {
                        SecureField(tokenPlaceholder, text: $tokenField)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit { save() }

                        Button(tokenField.isEmpty ? "Check" : "Save") { save() }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .disabled(isVerifying || (tokenField.isEmpty && !monitor.hasStoredToken))
                    }

                    HStack(spacing: DroppySpacing.xsm) {
                        Image(systemName: tokenGlyph)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tokenTint)
                        Text(tokenMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: DroppySpacing.sm) {
                        Button("Create a token on GitHub") {
                            guard let url = URL(string: "https://github.com/settings/personal-access-tokens/new") else { return }
                            onOpen(url)
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))

                        if monitor.hasStoredToken {
                            Button("Remove") {
                                tokenField = ""
                                Task { await monitor.setToken(nil) }
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                        }
                    }
                }
            }

            if let limit = monitor.rateLimit {
                DropletSettingsDivider()
                DropletControlRow(
                    title: "Rate limit",
                    icon: "gauge.with.needle",
                    infoTip: "Requests left in GitHub's hourly window. Unchanged repositories "
                           + "answer from cache and cost nothing, so this falls slower than the "
                           + "poll interval suggests."
                ) {
                    DropletValuePill(text: "\(limit.remaining) of \(limit.limit)")
                }
            }
        }
    }

    private var tokenPlaceholder: String {
        monitor.hasStoredToken ? "Saved — paste a new token to replace it" : "github_pat_… or ghp_…"
    }

    private var tokenGlyph: String {
        switch monitor.tokenState {
        case .valid:      return "checkmark.circle.fill"
        case .invalid:    return "xmark.circle.fill"
        case .unverified: return "clock"
        case .missing:    return "exclamationmark.circle.fill"
        }
    }

    private var tokenTint: Color {
        switch monitor.tokenState {
        case .valid:                return RunPalette.pass
        case .invalid, .missing:    return RunPalette.fail
        case .unverified:           return RunPalette.active
        }
    }

    private var tokenMessage: String {
        if isVerifying { return "Checking with GitHub…" }
        switch monitor.tokenState {
        case .valid(let login):
            return login.isEmpty ? "The token works." : "Signed in as \(login)."
        case .invalid(let message):
            return message
        case .unverified:
            return "Saved. It will be checked on the next poll."
        case .missing:
            return "No token saved. Private repositories and the rate limit both need one."
        }
    }

    private func save() {
        isVerifying = true
        let value = tokenField.isEmpty ? nil : tokenField
        Task {
            if let value {
                await monitor.setToken(value)
            } else {
                await monitor.verifyToken()
            }
            tokenField = ""
            isVerifying = false
        }
    }

    // MARK: Repositories

    private var repositoriesCard: some View {
        DropletSettingsCard {
            DropletStackedRow(
                title: "Repositories",
                icon: "bolt.fill",
                infoTip: "Runs are read from each repository's default branch. "
                       + "Paste owner/name, a GitHub URL, or a git remote."
            ) {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    HStack(spacing: DroppySpacing.sm) {
                        TextField("owner/name", text: $repoField)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit { addRepo() }

                        Button("Add") { addRepo() }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                            .disabled(repoField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let repoFieldError {
                        Text(repoFieldError)
                            .font(.system(size: 11))
                            .foregroundStyle(RunPalette.fail)
                    }

                    if monitor.snapshots.isEmpty {
                        Text("Nothing watched yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(monitor.snapshots) { snapshot in
                                repoRow(snapshot)
                                if snapshot.id != monitor.snapshots.last?.id {
                                    DropletSettingsDivider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func repoRow(_ snapshot: RepoSnapshot) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: snapshot.state.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RunPalette.color(for: snapshot.state))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.ref.id)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(rowDetail(snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DroppySpacing.md)

            if snapshot.failureMessage == nil, !snapshot.runs.isEmpty {
                RunSparkline(runs: snapshot.runs, capacity: 16, height: 12)
                DropletValuePill(text: RunFormat.rate(snapshot.successRate))
            }

            Button {
                guard let url = snapshot.ref.webURL else { return }
                onOpen(url)
            } label: {
                Image(systemName: "arrow.up.forward")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 22))
            .help("Open on GitHub")
            .accessibilityLabel("Open \(snapshot.ref.id) on GitHub")

            Button {
                monitor.removeRepo(snapshot.ref)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 22, destructive: true, solidFill: nil, foregroundColorOverride: nil))
            .help("Stop watching")
            .accessibilityLabel("Stop watching \(snapshot.ref.id)")
        }
        .padding(.vertical, DroppySpacing.xsm)
    }

    private func rowDetail(_ snapshot: RepoSnapshot) -> String {
        if let message = snapshot.failureMessage { return message }
        // The glyph beside this line reports the broken workflow, so the line
        // has to describe that same run. Describing whichever run is newest
        // would put a build in progress next to a failure glyph.
        guard let run = snapshot.subject else { return "No runs on the default branch yet." }
        var parts = ["\(run.workflowName) · \(snapshot.branch)"]
        if run.state.isActive {
            parts.append("running for \(RunFormat.duration(run.duration(now: monitor.now)))")
        } else {
            parts.append("\(run.state.label.lowercased()) \(RunFormat.age(run.updatedAt, now: monitor.now)) ago")
        }
        let verdicts = snapshot.passingWorkflows
        if verdicts.total > 1 {
            parts.append("\(verdicts.passing)/\(verdicts.total) workflows green")
        }
        if let median = snapshot.medianDuration {
            parts.append("median \(RunFormat.duration(median))")
        }
        return parts.joined(separator: " · ")
    }

    private func addRepo() {
        let text = repoField
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if monitor.addRepo(text) != nil {
            repoField = ""
            repoFieldError = nil
        } else {
            repoFieldError = "That is not a repository. Try owner/name."
        }
    }

    // MARK: Cadence

    private var cadenceCard: some View {
        DropletSettingsCard {
            DropletSliderRow(
                title: "Check every",
                value: intervalLabel,
                binding: $intervalMinutes,
                range: (WorkflowMonitor.Limits.minimumInterval / 60)...(WorkflowMonitor.Limits.maximumInterval / 60),
                step: 0.5,
                onEditingChanged: { editing in
                    // Writing on every tick of the drag would restart the poll
                    // loop a hundred times on the way from two minutes to ten.
                    guard !editing else { return }
                    monitor.interval = intervalMinutes * 60
                }
            )

            DropletSettingsDivider()

            DropletControlRow(
                title: "While a run is going",
                icon: "hare.fill",
                infoTip: "The cadence above applies to a settled list. A run in flight is "
                       + "checked more often, because that is when you are watching."
            ) {
                DropletValuePill(text: "every \(Int(WorkflowMonitor.Limits.activeInterval))s")
            }
        }
    }

    private var intervalLabel: String {
        let seconds = intervalMinutes * 60
        guard seconds >= 60 else { return "\(Int(seconds)) sec" }
        let minutes = intervalMinutes
        return minutes == minutes.rounded()
            ? "\(Int(minutes)) min"
            : String(format: "%.1f min", minutes)
    }

    // MARK: Announcements

    private var announcementsCard: some View {
        DropletSettingsCard {
            DropletToggleRow(
                title: "Announce failures",
                icon: "xmark.circle.fill",
                iconColor: RunPalette.fail,
                subtitle: "A HUD in the notch when a run on a watched branch fails.",
                isOn: Binding(
                    get: { monitor.announcesFailures },
                    set: { monitor.announcesFailures = $0 }
                )
            )

            DropletSettingsDivider()

            DropletToggleRow(
                title: "Announce recoveries",
                icon: "checkmark.circle.fill",
                iconColor: RunPalette.pass,
                subtitle: "A HUD when a branch that was failing goes green again. "
                        + "Runs that simply keep passing are never announced.",
                isOn: Binding(
                    get: { monitor.announcesRecoveries },
                    set: { monitor.announcesRecoveries = $0 }
                )
            )
        }
    }
}
