# Hephaestus

A multiplatform SwiftUI app that demonstrates persistence with SwiftData. The app presents a list of timestamped items with support for adding and deleting entries, using a data model that is stored on disk.

## Requirements

- Xcode 27 or later
- Swift 5
- Platforms: iOS, macOS, and visionOS

## Features

- SwiftUI-based interface that adapts across platforms
  - `NavigationSplitView` on macOS
  - `NavigationStack` on iOS and visionOS
- SwiftData-backed persistence via a shared `ModelContainer`
- Add items with the toolbar `+` button
- Delete items with swipe/contextual delete (`EditButton` on iOS)
- In-memory container for SwiftUI previews

## Project Structure

| Path | Description |
| --- | --- |
| `Hephaestus/Hephaestus/HephaestusApp.swift` | App entry point and SwiftData `ModelContainer` setup |
| `Hephaestus/Hephaestus/ContentView.swift` | Main list view with add/delete logic and platform navigation |
| `Hephaestus/Hephaestus/Item.swift` | SwiftData `@Model` representing a timestamped item |
| `Hephaestus/HephaestusTests/HephaestusTests.swift` | Unit tests using the Swift Testing framework |
| `Hephaestus/HephaestusUITests/HephaestusUITests.swift` | UI tests using XCUIAutomation |
| `Hephaestus.xcodeproj` | Xcode project and shared scheme |

## Getting Started

1. Open `Hephaestus.xcodeproj` in Xcode.
2. Select the `Hephaestus` scheme and a run destination (iOS, macOS, or visionOS).
3. Build and run with `Cmd+R`.

## Testing

- Unit tests use the [Swift Testing](https://developer.apple.com/documentation/testing) framework.
- UI tests use [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation).

Run tests in Xcode with `Cmd+U`, or via the command line:

```sh
xcodebuild test -scheme Hephaestus -destination 'platform=macOS'
```

## Architecture Notes

- State is stored in a SwiftData `ModelContainer` configured in `HephaestusApp`.
- Views read data with the `@Query` property wrapper and mutate it through the `@Environment(\.modelContext)`.
- Asynchronous work should prefer Swift `async`/`await` over Combine.
