import json
import math

import networkx as nx
import pyproj
from build_graph import build_graph, load_lines, snap
from shapely.geometry import LineString, Point
from shapely.strtree import STRtree

transformer = pyproj.Transformer.from_crs("EPSG:4326", "EPSG:3006", always_xy=True)

with open("stations.json", encoding="utf-8") as f:
    data = json.load(f)
stations = data["RESPONSE"]["RESULT"][0]["TrainStation"]


def parse_point(wkt):
    # "POINT (lon lat)"
    inner = wkt[wkt.index("(") + 1 : wkt.index(")")]
    lon, lat = map(float, inner.split())
    return lon, lat


if __name__ == "__main__":
    lines = load_lines()
    graph = build_graph(lines)
    print(f"Graph: {graph.number_of_nodes()} nodes")

    # Spatial grid index for nearest-node lookup (avoid O(n*m) brute force over 400k nodes x 718 stations)
    from collections import defaultdict

    # Stations further than `max_snap` from any open main-running track (harbours, museum lines,
    # closed stations) are deliberately left out rather than glued onto an unrelated line; the app
    # draws straight lines for them. Within the limit the offset is real: a directory coordinate is
    # often the station building, while the node is on the platform track (Stockholm City ~320 m).
    max_snap = 500.0  # meters
    cell_size = 200.0  # meters
    # Enough neighbouring cells that every node within `max_snap` of a query is seen, whatever the
    # query's position inside its own cell.
    cell_reach = math.ceil(max_snap / cell_size)
    grid = defaultdict(list)
    for node in graph.nodes:
        cx, cy = int(node[0] // cell_size), int(node[1] // cell_size)
        grid[(cx, cy)].append(node)

    # A station is a single node on one track, but a multi-track station's trains use the others
    # too, and the shortest path to a node on the wrong one runs on to the next crossover and back
    # (Nödinge's is 2.4 km away). So each station also gets a straight "link" to every other track
    # within `link_reach` that it can only reach the long way round along the track (more than
    # `link_slack` further than straight across); the app lets a route start or end over one, so it
    # can arrive at the station on whichever track it's on. Only the station's own tracks count —
    # the same railway section (`Bandel`) or named place (`PlNamn`; open line has none) as a track
    # at its node, or right alongside within `adjacent` (Jamtli, on Mittbanan, beside Inlandsbanan's
    # track) — or Stockholm C would link into the Citybanan tunnel next door and send every train
    # south through it. A link ends at the nearest point of its track — a straight run in a tunnel
    # can have no vertex for hundreds of metres, so that point is usually part-way along an edge,
    # which `contract_graph.py` splits there (`split_edges`).
    link_reach = 100.0  # meters
    link_slack = 50.0  # meters
    adjacent = 10.0  # meters
    edge_list = list(graph.edges)
    edge_tree = STRtree([LineString(edge) for edge in edge_list])

    def links_for(node):
        along = nx.single_source_dijkstra_path_length(graph, node, cutoff=link_reach + link_slack, weight="weight")
        own = graph.edges(node, data=True)
        # A track without a section or place name matches nothing, not every other unnamed track.
        sections = {data["bandel"] for *_, data in own} - {None}
        places = {data["pl_namn"] for *_, data in own} - {None}
        here = Point(node)
        reached = {}
        for i in edge_tree.query(here.buffer(link_reach)):
            a, b = edge_list[int(i)]
            if graph[a][b]["bandel"] not in sections and graph[a][b]["pl_namn"] not in places and LineString((a, b)).distance(here) > adjacent:
                continue
            segment = LineString((a, b))
            nearest = segment.interpolate(segment.project(here))
            point = snap(nearest.x, nearest.y)
            across = math.dist(node, point)
            by_track = min(along.get(a, math.inf) + math.dist(a, point), along.get(b, math.inf) + math.dist(b, point))
            if across <= link_reach and by_track > across + link_slack:
                reached[(a, b)] = (point, across)
        # Qualifying edges joined end to end are one run of track, which gets one link: its nearest
        # point. Only plain vertices join them, not switches — tracks a crossover connects inside
        # the circle are still separate tracks, each possibly the one a train arrives on.
        runs = nx.Graph()
        runs.add_nodes_from(reached)
        for edge in reached:
            for end in edge:
                if graph.degree[end] == 2:
                    for other in graph.edges(end):
                        key = other if other in reached else other[::-1]
                        if key != edge and key in reached:
                            runs.add_edge(edge, key)
        # Two runs that meet at a switch can both be nearest at it: one link there is enough.
        links = {}
        for run in nx.connected_components(runs):
            a, b = min(run, key=lambda edge: reached[edge][1])
            links.setdefault(reached[(a, b)][0], {"edge": [list(a), list(b)], "point": list(reached[(a, b)][0])})
        return sorted(links.values(), key=lambda link: link["point"])

    def nearest_node(x, y, max_dist=max_snap):
        cx, cy = int(x // cell_size), int(y // cell_size)
        best, best_d = None, max_dist
        for dcx in range(-cell_reach, cell_reach + 1):
            for dcy in range(-cell_reach, cell_reach + 1):
                for node in grid.get((cx + dcx, cy + dcy), []):
                    d = ((node[0] - x) ** 2 + (node[1] - y) ** 2) ** 0.5
                    if d < best_d:
                        best, best_d = node, d
        return best, best_d

    snapped = {}
    unmatched = []
    for st in stations:
        geom = st.get("Geometry", {}).get("WGS84")
        if not geom:
            unmatched.append((st["LocationSignature"], "no coordinate"))
            continue
        lon, lat = parse_point(geom)
        x, y = transformer.transform(lon, lat)
        node, dist = nearest_node(x, y)
        if node is None:
            unmatched.append((st["LocationSignature"], f"no node within {max_snap:.0f}m"))
            continue
        snapped[st["LocationSignature"]] = {
            "node": node, "dist": round(dist, 1), "name": st["AdvertisedLocationName"], "links": links_for(node)
        }

    print(f"Snapped {len(snapped)} / {len(stations)} stations")
    print(f"Unmatched: {len(unmatched)}")
    for sig, reason in unmatched[:30]:
        print(" ", sig, reason)

    dists = sorted(v["dist"] for v in snapped.values())
    print("Snap distance percentiles (m): p50=%.1f p90=%.1f p99=%.1f max=%.1f" % (
        dists[len(dists) // 2], dists[int(len(dists) * 0.9)], dists[int(len(dists) * 0.99)], dists[-1]
    ))

    linked = [len(v["links"]) for v in snapped.values() if v["links"]]
    print(f"Linked {len(linked)} stations to {sum(linked)} other tracks (at most {max(linked, default=0)} at one station)")

    with open("snapped_stations.json", "w", encoding="utf-8") as f:
        json.dump(
            {
                sig: {"node": list(v["node"]), "dist": v["dist"], "name": v["name"], "links": v["links"]}
                for sig, v in snapped.items()
            },
            f,
        )
