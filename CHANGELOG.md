# Changelog

Releases are cut by [release-please](https://github.com/googleapis/release-please) from [Conventional Commits](https://www.conventionalcommits.org/) on `main`; new sections are added above this one automatically. The project uses [Semantic Versioning](https://semver.org/).

## [1.0.1](https://github.com/sebdanielsson/tagradar/compare/v1.0.0...v1.0.1) (2026-09-26)


### Bug Fixes

* **deps:** update dependency networkx to &gt;=3.7 ([#43](https://github.com/sebdanielsson/tagradar/issues/43)) ([8072b5d](https://github.com/sebdanielsson/tagradar/commit/8072b5dfdb10125408ead72ae2a0b378fc757392))
* **deps:** update dependency pyproj to &gt;=3.8.0 ([#40](https://github.com/sebdanielsson/tagradar/issues/40)) ([dedc8a8](https://github.com/sebdanielsson/tagradar/commit/dedc8a8626ab84c7a92332fcf601970b28aae3be))
* **deps:** update dependency shapely to &gt;=2.1.2 ([#41](https://github.com/sebdanielsson/tagradar/issues/41)) ([752d95f](https://github.com/sebdanielsson/tagradar/commit/752d95f44b6282cec0aebe88cc9fdaa2647c4345))

## [1.0.0](https://github.com/sebdanielsson/tagradar/compare/v0.1.0...v1.0.0) (2026-09-19)


### ⚠ BREAKING CHANGES

* rename the app to Tågradar

### Features

* **ipad:** replace the tab layout with a sidebar, map and inspector ([#26](https://github.com/sebdanielsson/tagradar/issues/26)) ([67e5155](https://github.com/sebdanielsson/tagradar/commit/67e515535947198828a873c9bc38369ee80f723a))
* **map:** add a "Near you" section with next departures nearby ([#24](https://github.com/sebdanielsson/tagradar/issues/24)) ([e5b6ad4](https://github.com/sebdanielsson/tagradar/commit/e5b6ad48f8b8464c9f7775355f54f9ddee35113a))
* **map:** distinguish recent and major stations with different tints ([#21](https://github.com/sebdanielsson/tagradar/issues/21)) ([7f7f4c9](https://github.com/sebdanielsson/tagradar/commit/7f7f4c977c0c49b55d076e3839925be1a34a64c9))
* **map:** draw a cancelled leg of a route in red ([#16](https://github.com/sebdanielsson/tagradar/issues/16)) ([59fb5ff](https://github.com/sebdanielsson/tagradar/commit/59fb5ffe1793203c1ec9e2cc5be608ad98864e73))
* **map:** draw real track geometry instead of straight lines between stations ([#7](https://github.com/sebdanielsson/tagradar/issues/7)) ([3614bd8](https://github.com/sebdanielsson/tagradar/commit/3614bd881c7bf0ece4e24d1b6059b4abd262cdec))
* **map:** open the map near the user instead of over all of Sweden ([#31](https://github.com/sebdanielsson/tagradar/issues/31)) ([27d1cfa](https://github.com/sebdanielsson/tagradar/commit/27d1cfae105d9a4f58737314b4bc8c7fc598fad2))
* **map:** point the train marker in its direction of travel ([#15](https://github.com/sebdanielsson/tagradar/issues/15)) ([b296ff0](https://github.com/sebdanielsson/tagradar/commit/b296ff0f1543cf958396972860fb9ca5459f495f))
* **map:** show recently opened trains beside the saved ones ([#25](https://github.com/sebdanielsson/tagradar/issues/25)) ([cfec72c](https://github.com/sebdanielsson/tagradar/commit/cfec72cc3fd3f2930d3e93ffbc82f089de7b51ff))
* **map:** show stations on the map and fix sheet back-navigation ([#8](https://github.com/sebdanielsson/tagradar/issues/8)) ([b4658c4](https://github.com/sebdanielsson/tagradar/commit/b4658c45f2955425562115b97c9f98ec2497ceb4))
* **saved:** show the track on saved and recent trains ([#27](https://github.com/sebdanielsson/tagradar/issues/27)) ([6525047](https://github.com/sebdanielsson/tagradar/commit/652504752b10a2189a720cf3a157b9eba2d17191))


### Bug Fixes

* **activity:** show minutes to the next stop instead of a seconds timer ([967ddbf](https://github.com/sebdanielsson/tagradar/commit/967ddbfbd8d210da73b0fe3244cb78f36cb08750))
* **build:** stamp the widget extension with the app's build number ([b922e44](https://github.com/sebdanielsson/tagradar/commit/b922e44f5592c6b73450c3ea57d8aace6f4587dd))
* **ci:** pin an Apple Development certificate alongside the Distribution one ([#18](https://github.com/sebdanielsson/tagradar/issues/18)) ([b6b42fc](https://github.com/sebdanielsson/tagradar/commit/b6b42fcd22aa386a74458cb8a8c0e39f05a93e06))
* **ci:** resolve the simulator destination at run time ([#10](https://github.com/sebdanielsson/tagradar/issues/10)) ([3b99341](https://github.com/sebdanielsson/tagradar/commit/3b99341efd67358639e6f62cc9df53b7d7f4ddd1))
* keep the Live Activity updating in the background on cellular ([2a44052](https://github.com/sebdanielsson/tagradar/commit/2a44052a0616cfcb7af58032de501ed35cc14da3))
* **map:** keep camera and selection across a size-class change ([#23](https://github.com/sebdanielsson/tagradar/issues/23)) ([c467a37](https://github.com/sebdanielsson/tagradar/commit/c467a379c7541bfa73ec371796ff2f69358817c0))
* **map:** let the Recent tab show a saved run the way the Saved tab does ([#28](https://github.com/sebdanielsson/tagradar/issues/28)) ([1866043](https://github.com/sebdanielsson/tagradar/commit/1866043f278c88e559f774301d13f55992c5c7bd))
* **train:** keep the stop timeline connector line unbroken ([#14](https://github.com/sebdanielsson/tagradar/issues/14)) ([4d5da8a](https://github.com/sebdanielsson/tagradar/commit/4d5da8a2b870fd9baf29a0679eba2e0ecb1ef26c))


### Performance

* **map:** stop re-rendering the map and card on every position flush ([#30](https://github.com/sebdanielsson/tagradar/issues/30)) ([dd41e78](https://github.com/sebdanielsson/tagradar/commit/dd41e781e1bcb0413126905a6e5beadc6e17feb9))


### Miscellaneous

* **release:** prepare the App Store listing for 1.0.0 ([3132bc9](https://github.com/sebdanielsson/tagradar/commit/3132bc9d497973e84b72da68a8f572bcb71d525f))
* rename the app to Tågradar ([29af294](https://github.com/sebdanielsson/tagradar/commit/29af29470d05108731011842946019dc78a64f74))

## 0.1.0 (2026-09-05)

Initial development, before automated releases.

### Features

- Live map of all trains in Sweden with SSE updates and polling fallback.
- Train detail with all stops, planned/estimated/actual times, delays, deviations and traffic messages.
- Search by train number and date; station departure and arrival boards.
- Saved trains with live status, optionally limited to the stations where you board and get off.
- Local notifications for saved trains: delays, cancellations, track changes, arrival and a departure reminder, with a map attachment.
- Live Activities for followed trains (Lock Screen and Dynamic Island), refreshed in the background about once a minute via background URLSession wake-ups, with a self-running countdown, progress bar and upcoming stops.
- Home Screen and Lock Screen widgets: saved train and station departures.
- Background app refresh keeps notifications, Live Activities and widgets updated when iOS allows it.
- Icon Composer app icon in Trafikverket red with dark, clear and tinted appearances; original train glyph.
- Privacy policy, App Store submission checklist and screenshot script.
- iPhone and iPad layouts using iOS 26 Liquid Glass.
- `TrafikverketKit` Swift package with a typed request builder and models for the Trafikverket Open API.
