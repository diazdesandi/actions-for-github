# Actions for GitHub

A Droplet for [Droppy](https://getdroppy.app), built with
[DroppyKit](https://getdroppy.app/docs/droppykit). It keeps the GitHub Actions
runs of the repositories you watch on Droppy's shelf, in the spirit of
[OmniLens](https://github.com/OmniLens/OmniLens) but sized for the notch.

## What it shows

- **Shelf widget, solo.** A row per repository: whether it is green, which
  workflow the verdict belongs to, the last dozen runs as a sparkline, the
  share of them that passed, and how long ago.
- **Shelf widget, paired.** The state of the whole watch list as one number,
  then the pipelines behind it.
- **Live activity.** A run in flight rides beside the notch with its elapsed
  time; the card names the repository, the workflow and the branch.
- **HUD.** A run that fails, or a branch that goes green again, says so once
  and gets out of the way.
- **Settings pane.** The token, the watch list, the cadence, and what gets
  announced.

## How it reads GitHub

- A repository does not have one pipeline. Each workflow keeps its own standing
  verdict and the row reports the worst of them, so a failing issue-triage bot
  does not paint the build red and a green bot does not paint a broken build
  green.
- Every request is conditional on the previous response's ETag, so a repository
  that has not built since the last poll answers `304` and costs nothing
  against the hourly quota. The quota headers are read on every response and
  polling stands down before GitHub starts refusing it.
- The cadence is three-tiered: 15s while a run is in flight, the interval you
  chose when the list is settled, and "wait for the window" when the quota is
  spent.
- The token lives in the keychain, never in Droppy's preferences.
- Runs that finished while the Mac was asleep are history, not news: the
  cached snapshot is the baseline, so a launch never fires a HUD per repository.

## Status

The package builds, validates and renders every surface it declares against
DroppyKit 1.6.

One thing is still a placeholder: `Assets/Creator.png` is the blue disc
`droppykit new` writes, and it is what the Droplet Store shows beside the
author's name.

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce ActionsForGitHub.droplet
droppykit validate   # the checks a submission runs
droppykit submit     # open the submission form, filled in from this checkout
```

## With a coding agent

Open this folder in Claude Code, Codex or Cursor. `AGENTS.md` is the brief
they read first, and `.mcp.json` / `.cursor/mcp.json` connect the DroppyKit
MCP server, which gives them the build, the checks, pictures of every surface
and an install into Droppy Playground as tools. Codex registers the server
once per Mac: `codex mcp add droppykit -- path/to/droppykit/Scripts/droppykit mcp`.
Run `droppykit agent` again after moving this folder or the SDK checkout.

## Before submitting

- Replace `ActionsForGitHub.icon` with real artwork, in Icon Composer.
- Replace `Assets/Creator.png` with your own square, unrounded mark.
- Fill in `summary`, `description`, `creator` and `source` in `droplet.json`.
- Push this repository, then `droppykit submit`: it opens
  [getdroppy.app/submit-droplet](https://getdroppy.app/submit-droplet) with the
  repository, the commit and the id filled in.

## License

Copyright (C) 2026 René Jiménez

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>.

The full text is in [LICENSE](LICENSE).

### Linking exception

A compiled `.droplet` links DroppyKit, which ships under the proprietary
DroppyKit SDK License 1.0 and cannot be redistributed. The AGPL asks a
distributor for Corresponding Source covering what the binary links, so without
a further grant the built bundle could not be conveyed at all.

[LICENSE-EXCEPTION](LICENSE-EXCEPTION) is that grant: an additional permission
under AGPL section 7 allowing this program to be linked with DroppyKit and
Droppy, conveyed in binary form including through the Droplet Store, with those
two omitted from the Corresponding Source. Everything else here stays under the
AGPL, and the source you are reading is offered under it in full.

Section 13, the network clause that separates the AGPL from the GPL, has
nothing to bite on here: this droplet runs on one Mac and talks to GitHub's API
as a client, so nobody interacts with it remotely over a network. It matters if
someone later builds a hosted service out of this code, which is the case the
AGPL exists for.
