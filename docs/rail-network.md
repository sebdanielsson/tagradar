# Rail network geometry

`Tagradar/Resources/RailNetwork.json` lets the map draw a train's route following the real
shape of the track instead of straight lines between stations (`RailNetwork.swift`). It's
generated offline from Trafikverket's National Railway Database (NJDB) and checked in as a
static bundled resource — nothing about it is fetched at runtime.

## Where the data comes from

The Trafikverket Open API used everywhere else in the app (`TrainPosition`, `TrainAnnouncement`,
`TrainStation`, …) has no track geometry — only points. The actual rail network shape is a
separate product, **"Järnvägsnät med grundegenskaper"**, distributed as a GeoPackage through
[Lastkajen](https://www.trafikverket.se/e-tjanster/lastkajen--sveriges-vag--och-jarnvagsdata/)
(free, CC0, just needs an email registration; `download_njdb.py` fetches it through Lastkajen's
token-based API, or you can pull the `.zip` from the portal by hand). It ships ~195k short track segments (tens of metres
each) in SWEREF99TM, tagged with attributes like track type and status but no direct link to
Trafikverket's station signatures.

## Pipeline (`Scripts/rail-network/`)

Everything runs from inside `Scripts/rail-network/` and reads/writes files next to the scripts
(all of them git-ignored except the final copy under `Tagradar/Resources/`):

The scripts are run with [uv](https://docs.astral.sh/uv/), which reads `pyproject.toml` and
`uv.lock` and sets up the interpreter and dependencies itself — no GDAL needed, a GeoPackage is
just SQLite:

```bash
cd Scripts/rail-network
uv run build_graph.py     # uv installs Python and the dependencies on first run
```

Two inputs have to be in place first:

- `railnet/` — the NJDB GeoPackage from Lastkajen, unzipped. `download_njdb.py` fetches it for
  you given a free Lastkajen account:

  ```bash
  LASTKAJEN_USER='you@example.com' LASTKAJEN_PASSWORD='…' uv run download_njdb.py
  ```

  The file name carries the data's version and changes between releases, so `build_graph.py`
  takes whatever GeoPackage it finds under `railnet/` and reads the layer name out of the file
  rather than hard-coding either.
- `stations.json` — the raw Open API response for every advertised station, saved as-is
  (`snap_stations.py` reads `RESPONSE.RESULT[0].TrainStation`). Any API key works:

  ```bash
  curl -s -X POST https://api.trafikinfo.trafikverket.se/v2/data.json -H 'Content-Type: text/xml' \
    -d "<REQUEST><LOGIN authenticationkey='$TRV_API_KEY'/><QUERY objecttype='TrainStation' namespace='rail.infrastructure' schemaversion='1.5'><FILTER><EQ name='Advertised' value='true'/></FILTER><INCLUDE>LocationSignature</INCLUDE><INCLUDE>AdvertisedLocationName</INCLUDE><INCLUDE>Geometry.WGS84</INCLUDE></QUERY></REQUEST>" \
    -o stations.json
  ```

0. **`download_njdb.py`** — fetches the GeoPackage from Lastkajen's REST API (bearer token from
   your account) and unpacks it into `railnet/`. Skip it if you downloaded the zip by hand.
1. **`build_graph.py`** — reads the GeoPackage straight out of SQLite (a GeoPackage is just
   SQLite; geometries are WKB with a small header we strip), keeping only open main-running
   track (`Status = 'Öppen'`, `SpTyp` in `nhsp`/`ahsp`/`tågspår` — excludes sidings and yard
   tracks). Builds an undirected graph: every vertex of every segment becomes a node (snapped to
   10cm to merge coincident points), consecutive vertices become weighted edges.
2. **`snap_stations.py`** — snaps every station in `stations.json` to the nearest graph node
   within 500 m (grid-indexed for speed). 606 of 718 stations match — half of them within 13 m,
   nine in ten within 77 m, the worst 438 m where the directory coordinate is the station
   building rather than the platforms (Stockholm City, whose platforms are deep under the
   entrance, is ~320 m). The rest are foreign stations (`At.`/`De.`/`Dk.`…
   prefixes) not covered by the Swedish network at all, plus a couple of dozen Swedish ones:
   museum lines, harbour tracks and closed lines outside the open main-running track kept in
   step 1, and Blattnicksele, where the kept track passes right by but its nearest survey vertex
   is 700 m away, past the snap limit. All of them just fall back to a straight line in the app.

   A station is one node on one track, but at a multi-track station the shortest path to a node
   on the far track runs on to the next crossover and back (2.4 km at Nödinge, 0.9 km at Arlanda
   C). So each station also gets *links*: straight connectors to every other track within 100 m
   that it can only reach more than 50 m the long way round along the track, ending at that
   track's nearest point (usually part-way along an edge, which step 3 splits there). 465
   stations get 902 links.
3. **`contract_graph.py`** — the raw graph has ~400k nodes, almost all of them degree-2 points
   that just sit along a straight-ish run between real junctions. It collapses every such chain
   into a single edge carrying the full sub-polyline, *pinning* every snapped station and link
   end as a kept node first (after splitting the edges link ends fall on) so none disappears into
   a collapsed chain. Then simplifies each chain's polyline with Douglas-Peucker (15m tolerance).
   Result: 7,741 nodes / 10,038 edges for the whole country.
4. **`export_network.py`** — converts back to WGS84, rounds to 5 decimals (~1m), and writes the
   final `RailNetwork.json` (796KB): `nodes` (`[lat, lon]` per graph node), `edges` (one
   `[a, b, interior, length]` per contracted chain — node indices, the simplified interior
   points, and the exact pre-simplification track length in metres so the app never has to
   measure polylines itself), `stations` (signature → node index) and `links` (signature →
   `[node, length]` per link).

Sanity check baked into `export_network.py`: it runs a shortest path Stockholm C → Mora C on the
exact graph being exported and refuses to write the file if the result strays more than 5 km
from the real-world 329.6 km, so a dropped line or a broken contraction can't ship silently.

## On the app side

- `RailGraph` is the pure data structure (nodes, edges, adjacency, station lookup) plus Dijkstra
  between two station signatures. Each edge's polyline is stored once; the adjacency entry says
  which direction to walk it. A route may take a station's links only as its first or last step,
  so it can arrive on whichever track it's on without links becoming shortcuts between lines. It's
  tested against small synthetic graphs in `RailGraphTests`, and the bundled file against a couple
  of multi-track stations in `BundledRailNetworkTests`.
- `RailNetwork` owns loading and caching: `AppDependencies.start()` calls `preload()` at launch,
  which parses the JSON off the main actor. `route(from:to:)` returns `nil` until that finishes
  and memoises every answer (including misses) per station pair.
- `TrainMapView` computes the selected journey's polyline once per selection (not in `body`) by
  concatenating the real path between each consecutive pair of its stops — there's no precomputed
  table of "every travelled station pair" — and falls back to a straight segment for any pair
  where either station isn't in the network or the network hasn't loaded yet.
- A leg isn't always the shortest path between its two stops: an express that doesn't stop
  between Norrköping and Södertälje runs via Katrineholm, while the shortest track goes via
  Nyköping. `TrainJourney.passingPoints` collects the unadvertised `TrainAnnouncement` rows for
  the stations the train passes between each pair of stops (ordered by when it actually passed —
  rows sharing an advertised minute aren't listed in running order; cancelled rows are left out),
  and `RailGraph.legs` reroutes the leg through those the network knows that lie more than 1 km
  off the shortest path. Closer ones are on the same line, only snapped to the other track, a
  platform or a stub, and are ignored. A waypoint the route turns back at — its heading over 200 m
  either side differs by more than 90°, even when it leaves on a different track than it came in
  on — is dropped too, and a spike of up to 150 m out to a waypoint's own node is cut from the
  line. Over a full day's data this
  changes only legs that really run elsewhere (Norrköping–Södertälje via Katrineholm, Helsingborg–
  Malmö via Lund, …). Trafikverket publishes a passing row only once the train has passed, so for
  legs the selected run hasn't finished `MapScreen` fetches the same train number's run the day
  before (`JourneyStore.loadPreviousRun`) and `TrainJourney.routePassingPoints(previous:)` uses
  its passing points wherever it had the same pair of stops.

## Regenerating

Needed only if NJDB publishes a materially different network (new lines, major reroutes) — the
existing file doesn't need routine updates. Re-download the GeoPackage from Lastkajen and refresh
`stations.json` as described above, then:

```bash
cd Scripts/rail-network
uv run download_njdb.py   # or unzip the Lastkajen download into railnet/ yourself
uv run build_graph.py && uv run snap_stations.py && uv run contract_graph.py && uv run export_network.py
cp RailNetwork.json ../../Tagradar/Resources/RailNetwork.json
```
