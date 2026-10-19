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
