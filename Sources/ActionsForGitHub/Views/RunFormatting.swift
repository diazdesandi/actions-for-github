//
//  RunFormatting.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  The vocabulary every surface shares: the colour a state reads as, how long
//  a run took, and how long ago it was. Written once so the shelf, the notch
//  and the settings pane never disagree about what green means.
//

import DroppyKit
import SwiftUI

// MARK: - Palette

/// The three status colours, taken from GitHub's brand palette.
///
/// Values are from brand.github.com/foundations/color, so a run that passed is
/// the same green GitHub itself uses for one. The palette has no red: GitHub
/// uses Orange where other systems reach for one, and Orange 3 is what a
/// failure gets here.
///
/// These are fixed rather than Droppy tokens, and that is on purpose. Droppy's
/// foreground tokens are a contrast ladder, primary through tertiary, and a
/// pass/fail signal is not a rung on it. A widget that reports state also
/// cannot let the host tint them: when `usesAdaptiveForegrounds` asks for a
/// tint, the text takes it and these do not, because a green washed toward the
/// wallpaper no longer reads as the state it is reporting.
///
/// Every value here is legible on the black that Droppy's shelf and notch
/// surfaces are, which is the only surface this droplet draws on.
public enum RunPalette {
    /// Passed. GitHub Green, the brand's primary (Green 4).
    public static let pass = Color(red: 0x0F / 255, green: 0xBF / 255, blue: 0x3E / 255)

    /// Failed, or needs a human. Orange 3, the brand's most saturated warm
    /// tone and the nearest thing it has to a red.
    public static let fail = Color(red: 0xFE / 255, green: 0x4C / 255, blue: 0x25 / 255)

    /// Queued or running. Lime 3, a gold far enough from both Green 4 and
    /// Orange 3 in hue to be told apart at the 3pt width a sparkline bar gets.
    public static let active = Color(red: 0xD8 / 255, green: 0xBD / 255, blue: 0x0E / 255)

    /// Cancelled, skipped, or never read. Gray 4, the brand's mid grey. Fixed
    /// like the rest, so a bar with no verdict cannot be mistaken for one that
    /// has a faint verdict.
    public static let idle = Color(red: 0x90 / 255, green: 0x96 / 255, blue: 0x92 / 255)

    /// The colour for one state.
    public static func color(for state: RunState) -> Color {
        switch state {
        case .success:                  return pass
        case .failure, .actionRequired: return fail
        case .queued, .running:         return active
        default:                        return idle
        }
    }
}

// MARK: - Formatting

/// Durations and ages, in the shortest form that is still unambiguous.
public enum RunFormat {

    /// `12s`, `1m 40s`, `1h 04m`. Never `0h 01m 40s`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(max(total, 0))s" }
        let minutes = total / 60
        guard minutes >= 60 else { return "\(minutes)m \(String(format: "%02d", total % 60))s" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// `now`, `4m`, `3h`, `2d`. The shelf is too narrow for "ago", and the
    /// column it sits in makes the meaning plain.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<45:     return "now"
        case ..<3600:   return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default:        return "\(Int(seconds / 86_400))d"
        }
    }

    /// `92%`, or an em dash when nothing has finished yet.
    public static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    /// What a snapshot's trailing column says, about the same run the rest of
    /// the row describes: how long it has been going while it is going, and
    /// how long ago it finished once it has.
    public static func trailing(for snapshot: RepoSnapshot, now: Date) -> String {
        guard let subject = snapshot.subject else { return "—" }
        return subject.state.isActive
            ? duration(subject.duration(now: now))
            : age(subject.updatedAt, now: now)
    }
}

// MARK: - Sparkline

/// The last dozen runs as one bar per run, newest at the trailing edge.
///
/// This is the whole reason to read more than the newest run: a repository
/// that is green right now and was red four times this morning is not the same
/// repository as one that has been green all week, and the headline glyph
/// cannot tell them apart.
public struct RunSparkline: View {
    /// Runs newest first, as the snapshot stores them.
    public let runs: [WorkflowRun]
    /// How many bars to draw.
    public let capacity: Int
    /// Bar height.
    public let height: CGFloat

    public init(runs: [WorkflowRun], capacity: Int = 12, height: CGFloat = 10) {
        self.runs = runs
        self.capacity = capacity
        self.height = height
    }

    /// Oldest first, so the newest run lands at the trailing edge where the
    /// eye already is after reading the row leading to trailing.
    private var bars: [WorkflowRun] {
        Array(runs.prefix(capacity)).reversed()
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(bars) { run in
                RoundedRectangle(cornerRadius: DroppyRadius.micro, style: .continuous)
                    .fill(RunPalette.color(for: run.state))
                    // A cancelled or skipped run has no verdict to report, so
                    // it draws short. The row still reads as a sequence of
                    // runs without claiming a result for those two.
                    .frame(width: 3, height: run.state.countsTowardHealth ? height : height * 0.4)
                    .frame(height: height, alignment: .bottom)
                    .opacity(run.state.countsTowardHealth ? 1 : 0.7)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Last \(bars.count) runs")
    }
}
