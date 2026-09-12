//
//  SampleData.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  What the harness shows when there is no token.
//
//  The harness has no keychain item and no network, so without this every
//  surface renders its empty state and the one thing the shots are for — does
//  this look right with real content in it — cannot be checked. The sample is
//  taken from a real repository's real run history rather than invented, so
//  the shapes it exercises are the shapes that actually occur: several
//  workflows per repository, a bot that fails while the build passes, skipped
//  runs in the middle of the sparkline, and one run still going.
//
//  It is only ever loaded when `host.environment.isHarness` is true.
//

import Foundation

enum SampleData {

    /// The repository the sample is built from.
    static let thaw = RepoRef(owner: "thaw-app", name: "Thaw")
    /// A second one, so the widget's paired layout and its row list have more
    /// than one thing to lay out.
    static let droppy = RepoRef(owner: "getdroppy", name: "droppykit")

    /// The sample watch list.
    static var repos: [RepoRef] { [thaw, droppy] }

    /// Snapshots dated relative to `now`, so the age column reads sensibly
    /// whenever the shots are taken rather than drifting into "412d".
    static func snapshots(now: Date = Date()) -> [RepoSnapshot] {
        [thawSnapshot(now: now), droppySnapshot(now: now)]
    }

    // MARK: Thaw

    /// Thaw's development branch, as it actually runs: a Build DMG workflow
    /// that passes, a scheduled Fuzz and Scorecard, an issue-triage bot that
    /// is currently failing, and skipped runs between them.
    ///
    /// This is the case the repository-level state exists for. The newest run
    /// here passed, and the repository is still not green, because a different
    /// workflow's standing verdict is a failure.
    private static func thawSnapshot(now: Date) -> RepoSnapshot {
        let runs: [WorkflowRun] = [
            run(1_179, "Build DMG",      "development", "workflow_dispatch", .running,  ago: 2 * 60,        took: 0,   now: now),
            run(1_178, "Build DMG",      "development", "workflow_dispatch", .success,  ago: 34 * 60,       took: 338, now: now),
            run(1_177, "Assign issues",  "development", "issues",            .skipped,  ago: 66 * 60,       took: 9,   now: now),
            run(1_176, "Issue Triage",   "development", "issues",            .failure,  ago: 66 * 60,       took: 188, now: now),
            run(1_175, "Fuzz",           "development", "schedule",          .success,  ago: 154 * 60,      took: 359, now: now),
            run(1_174, "Build DMG",      "development", "workflow_dispatch", .success,  ago: 188 * 60,      took: 332, now: now),
            run(1_173, "Scorecard",      "development", "schedule",          .success,  ago: 258 * 60,      took: 36,  now: now),
            run(1_172, "Build DMG",      "development", "workflow_dispatch", .success,  ago: 297 * 60,      took: 301, now: now),
            run(1_171, "Remove runs",    "development", "workflow_dispatch", .success,  ago: 305 * 60,      took: 63,  now: now),
            run(1_170, "Build DMG",      "development", "workflow_dispatch", .success,  ago: 444 * 60,      took: 467, now: now),
            run(1_169, "Build DMG",      "development", "workflow_dispatch", .success,  ago: 576 * 60,      took: 310, now: now),
            run(1_168, "Issue Triage",   "development", "issues",            .failure,  ago: 760 * 60,      took: 317, now: now)
        ]
        return RepoSnapshot(ref: thaw, branch: "development", runs: runs, fetchedAt: now)
    }

    // MARK: A green repository

    /// The other shape: one workflow, every run passing. A widget that only
    /// ever renders the interesting case is a widget nobody checked the
    /// ordinary one on.
    private static func droppySnapshot(now: Date) -> RepoSnapshot {
        let runs: [WorkflowRun] = (0..<12).map { index in
            run(
                2_100 - index,
                "CI",
                "main",
                "push",
                index == 4 ? .cancelled : .success,
                ago: TimeInterval(index) * 3 * 3600 + 900,
                took: 96 + TimeInterval(index % 5) * 11,
                now: now
            )
        }
        return RepoSnapshot(ref: droppy, branch: "main", runs: runs, fetchedAt: now)
    }

    // MARK: Builder

    private static func run(
        _ id: Int,
        _ workflow: String,
        _ branch: String,
        _ event: String,
        _ state: RunState,
        ago: TimeInterval,
        took: TimeInterval,
        now: Date
    ) -> WorkflowRun {
        let started = now.addingTimeInterval(-ago)
        return WorkflowRun(
            id: id,
            workflowName: workflow,
            branch: branch,
            event: event,
            runNumber: id,
            state: state,
            createdAt: started,
            updatedAt: state.isActive ? started : started.addingTimeInterval(took),
            startedAt: started,
            htmlURL: URL(string: "https://github.com/thaw-app/Thaw/actions")
        )
    }
}
