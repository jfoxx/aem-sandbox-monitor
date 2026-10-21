# AEM Environment Monitor

A macOS menu bar app that monitors AEM Cloud Service environments for de-hibernation.

## Requirements

- macOS 13+ (Ventura or later)
- Xcode 15+ or Swift 5.9+ toolchain

## Build & Run

```bash
cd aem-sandbox-monitor
swift build
swift run AEMMonitor
```

Or open in Xcode:

```bash
open Package.swift
```

Then build and run (Cmd+R).

## What It Does

Monitors AEM Cloud Service author environments by polling their login page:

- **HTTP 200 + body contains "hibernat"** → Hibernated
- **HTTP 200 + no "hibernat" in body** → Up / Awake
- **Non-200 status** → Down

## Cloud Manager API mode (1.2.0)

Each program can get its status from either:

| Source | Credentials | Matches Cloud Manager | Pipelines |
|---|---|---|---|
| Login page check (default) | none | approximately: author can accept logins before Cloud Manager stops showing "Restarting" | no |
| Cloud Manager API | OAuth Server-to-Server | yes: same status fields the Cloud Manager UI reads, including "Restarting" | yes |

### Create the credential (once per IMS org)

1. In [Adobe Developer Console](https://developer.adobe.com/console), create a project in the org that owns the program.
   You need to be a System Administrator, or have Developer Access for a Cloud Manager product profile.
2. Add API > **Cloud Manager**, choose **OAuth Server-to-Server**, and select the **Developer** product profile (read-only is enough).
3. Copy the Client ID, Client Secret, Organization ID and Scopes from the credential page.

### Add it to the app

Settings > **Cloud Manager API** > Add Credential, paste the values, Save. Saving runs a test that:

- requests a token,
- lists the programs the credential can see (each has **Add** / **Use API**),
- reports whether "Restarting" detection is available for that credential.

Or pick the credential per program under **Status from**. The client secret is stored in the macOS Keychain
(service `com.adobe.aem-monitor.cloudmanager`), never in config.json.

### Pipelines

Programs using the API show a **Pipelines** list. **Watch** a pipeline to get notified when a run starts,
when a step is waiting for approval, and when it succeeds, fails or is cancelled. Turn on
"Pipelines: also notify at each step" in Settings for a notification per step. Clicking a notification opens the
run in Cloud Manager.

## Configuration

All programs and environments are **user-configurable** via the Settings view (gear icon in the popover).

- **Add/edit/remove programs** — each has a name and Cloud Manager program ID
- **Add/edit/remove environments** per program — each has a name and environment ID
- Configuration persists to `~/Library/Application Support/AEMMonitor/config.json`
- Ships with two default programs (foxx, Public Sector SLG) — fully deletable

### Config file format

```json
{
  "programs": [
    {
      "id": "49252",
      "name": "foxx",
      "environments": [
        { "id": "1429146", "name": "dev" },
        { "id": "308289", "name": "stage" },
        { "id": "308251", "name": "prod" }
      ]
    }
  ]
}
```

### First Launch

On first launch (no config file), the app:
1. Pre-populates with default programs
2. Automatically opens the Settings view
3. Shows helper text with the author URL pattern

## Features

- **Menu bar icon** — cloud icon with color state (gray=idle, orange=watching, green=awake)
- **Watch individual environments** or "Watch All" to monitor everything
- **30-second polling** with countdown display
- **macOS notifications on status change** for watched environments: Ready, Starting (de-hibernating), Hibernated, Down. Configurable in Settings: every change or only when up, sound on/off, and an option to keep watching after wake so a later re-hibernation is reported. Clicking a notification opens that environment's author. Transient errors (timeouts, network blips) never notify. A **Send Test** button confirms banners are allowed.
- **Agent app** — no dock icon, lives entirely in the menu bar
- **Graceful error handling** — timeouts, network errors shown inline without crashing
- **Shareable** — anyone with Cloud Manager access can configure their own programs

## Architecture

| File | Lines | Purpose |
|------|-------|---------|
| `Package.swift` | 16 | SPM manifest, macOS 13+, swift-tools-version 5.9 |
| `App.swift` | 13 | `@main` entry point, SwiftUI App with NSApplicationDelegateAdaptor |
| `AppDelegate.swift` | 115 | NSStatusItem, NSPopover, menu bar icon management |
| `ContentView.swift` | 208 | SwiftUI popover — program sections, environment rows, empty state |
| `SettingsView.swift` | 283 | Full CRUD for programs/environments, inline editing |
| `EnvironmentModel.swift` | 268 | ObservableObject — state, polling, notifications, config CRUD |
| `EnvironmentChecker.swift` | 47 | Async URLSession HTTP check with body inspection |
| `Models.swift` | 162 | Codable config structs, ConfigStore (JSON persistence), runtime types |
