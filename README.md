# Tågradar

[![CI](https://github.com/sebdanielsson/tagradar/actions/workflows/ci.yml/badge.svg)](https://github.com/sebdanielsson/tagradar/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-iOS%2026%20%7C%20iPadOS%2026-lightgrey)

Tågradar is a native iOS and iPadOS app that shows every train in Sweden live on a map, lets you look up any train by number or station, and keeps track of upcoming trips. It is a modern, open-source alternative to Trafikverket's MinaTåg app, built entirely on Trafikverket's free open data.

> Tågradar is an independent project and is not affiliated with or endorsed by Trafikverket.

## Features

- **Live map** of all trains with a GPS position, updated in real time over Server-Sent Events (falls back to polling). Markers show heading and are coloured by delay.
- **Train details**: every station on the run with planned, estimated and actual times, track, delay, deviations ("Spårändrat", "Buss ersätter", …), on-board services, the operator's link and the live speed, heading and position age.
- **Search** by train number on any date, or browse a station's departure and arrival board.
- **Saved trains**: pin an upcoming trip and see its status at a glance. Optionally set where you board and get off, and everything below only looks at that part of the run. Saved trains are stored on-device with SwiftData.
- **Notifications** for saved trains: delays of five minutes or more, cancellations, track changes, arrival and a reminder 30 minutes before departure, with a map of the train's position attached. Alerts are generated on the device; there is no server. While the app is open it checks every 30 seconds, in the background iOS decides how often the app may refresh (typically every 15 minutes or more), so alerts can arrive late.
- **Live Activities**: follow a train and see its next stop, delay and progress on the Lock Screen and in the Dynamic Island. The countdown and progress bar run on their own, and while the train is moving the activity is refreshed about once a minute in the background through short network wake-ups (no server involved); iOS may space them out on a poor connection.
- **Widgets** for the Home Screen and Lock Screen: one saved train (or always the next one), and the departure board of a station of your choice.
- **Traffic messages** from Trafikverket that affect the stations on your train's route.
- **iPhone and iPad** layouts. On iPhone the map fills the screen and an Apple Maps-style bottom card holds search, saved trains, quick access to stations and the train and station details. On iPad the same card is a sidebar beside the full-size map, with every upcoming saved train and every quick station (starred, recent, then the big hubs) rather than the phone's shortened lists, and a train or station opens in an inspector on the other side. Any other station is reached through search.
- Built with SwiftUI, MapKit and the iOS 26 Liquid Glass design language. No third-party dependencies, no analytics, no tracking.

## Requirements

- iOS 26.5 / iPadOS 26.5 or later
- Xcode 27 (iOS 27 SDK) to build
- A free Trafikverket API key (see below)

## Getting an API key

Trafikverket's open API is free but requires a personal key.

1. Create an account at [data.trafikverket.se](https://data.trafikverket.se).
2. Under *Mina sidor*, create an API key.
3. Either paste the key into the app on first launch (stored in the Keychain), or bake it into your own build as described under *Building*.

The data is published under [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

## Building

```bash
brew install xcodegen            # project file is generated, not committed
cp .env.example .env.local       # optional: put TRV_API_KEY=... here for a built-in dev key
Scripts/bootstrap.sh             # writes Config/Secrets.xcconfig and generates Tagradar.xcodeproj
open Tagradar.xcodeproj
```

Select the *Tagradar* scheme and run on an iPhone or iPad simulator. Without a key in `.env.local` the app asks for one on first launch.

Command-line build and test:

```bash
xcodebuild -project Tagradar.xcodeproj -scheme Tagradar \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build test
```

`Scripts/simulator.sh "iPhone 17 Pro"` builds, installs and launches the app on a named simulator (pass a second argument to save a screenshot).

The networking layer lives in the `TrafikverketKit` Swift package under `Packages/` and can be tested on its own with `swift test`.

## Project layout

```text
Tagradar/                 SwiftUI app
  App/                     Entry point, dependency container, settings
  Models/                  TrainKey, TrainJourney, TrainStop, LiveTrain, FavoriteTrain (SwiftData)
  Services/                Live positions (SSE), station directory, delay index, timetable queries
  Views/                   Map, the search and saved card, train detail, station board, settings
  AppIcon.icon/            Icon Composer package (all sizes and appearances are compiled from it)
TagradarWidgets/          WidgetKit extension: saved-train and departures widgets, Live Activity UI
fastlane/                  Store metadata (en-US, sv), screenshots and the App Store submission lane
Marketing/                 Flattened icon PNGs
Packages/TrafikverketKit/  Typed client for the Trafikverket Open API (request builder, models, SSE)
project.yml                XcodeGen spec
```

## Data sources

Everything live comes from the [Trafikverket Open API](https://data.trafikverket.se):

| Object | Used for |
| --- | --- |
| `TrainPosition` | Live GPS positions, speed and bearing |
| `TrainAnnouncement` | Timetable, estimated and actual times, deviations |
| `TrainStation` | Station names and coordinates |
| `TrainStationMessage` | Disruption notices shown on station monitors and signs |

The shape of the tracks drawn on the map is not in that API. It comes from Trafikverket's National Railway Database (NJDB, *Järnvägsnät med grundegenskaper*, also [CC0](https://creativecommons.org/publicdomain/zero/1.0/)), downloaded from [Lastkajen](https://www.trafikverket.se/e-tjanster/lastkajen--sveriges-vag--och-jarnvagsdata/), simplified offline and bundled as `Tagradar/Resources/RailNetwork.json`. See [docs/rail-network.md](docs/rail-network.md).

## App icon, releases and the App Store

The icon is an Icon Composer package at `Tagradar/AppIcon.icon`, generated by `swift Scripts/make-app-icon.swift`. The background is Trafikverket red (`#D70000`, `#AF0000` in dark mode) and iOS derives the clear and tinted Home Screen styles from the white layers.

Every push to `main` goes to TestFlight and [release-please](https://github.com/googleapis/release-please) maintains a release pull request from the commit history; merging it tags a version and submits that build to App Store Review. `docs/release.md` describes the pipeline and the one-time setup, `docs/app-store.md` the store listing, and `PRIVACY.md` is the privacy policy. Store metadata lives in `fastlane/metadata`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and feature requests are welcome in [Issues](https://github.com/sebdanielsson/tagradar/issues).

## License

MIT — see [LICENSE](LICENSE).
