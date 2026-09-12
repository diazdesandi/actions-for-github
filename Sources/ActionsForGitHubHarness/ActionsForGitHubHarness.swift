//
//  ActionsForGitHubHarness.swift
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import DroppyKit
import DroppyKitHarness
import ActionsForGitHub

@main
struct ActionsForGitHubHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { ActionsForGitHubDroplet() }
}
