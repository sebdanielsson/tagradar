import json
import math
import os
import pickle

import networkx as nx
import pyproj

to_wgs84 = pyproj.Transformer.from_crs("EPSG:3006", "EPSG:4326", always_xy=True)

with open("contracted_graph.pkl", "rb") as f:
    g = pickle.load(f)
with open("snapped_stations.json") as f:
    snapped = json.load(f)

node_list = list(g.nodes)
node_index = {n: i for i, n in enumerate(node_list)}


def to_ll(x, y):
    lon, lat = to_wgs84.transform(x, y)
    return [round(lat, 5), round(lon, 5)]


nodes_out = [to_ll(*n) for n in node_list]

edges_out = []
for u, v, data in g.edges(data=True):
    chain = data["chain"]
    if chain[0] != u:
        chain = list(reversed(chain))
    # store only the interior points (endpoints are implied by node indices) to avoid duplication
    interior = [to_ll(*p) for p in chain[1:-1]]
    # `weight` is the exact pre-simplification track length in metres (SWEREF99TM), computed once
    # here so the app doesn't need to reconstruct it from CLLocation distances at load time.
    edges_out.append([node_index[u], node_index[v], interior, round(data["weight"], 1)])

stations_out = {}
links_out = {}
skipped = 0
for sig, v in snapped.items():
    node = tuple(v["node"])
    if node not in node_index:
        skipped += 1
        continue
    stations_out[sig] = node_index[node]
    # A link is a straight connector, so its length is just the distance across.
    ends = [tuple(link["point"]) for link in v.get("links", [])]
    if missing := [end for end in ends if end not in node_index]:
        raise SystemExit(f"{sig}'s link ends {missing} didn't survive contraction — refusing to export")
    links = [[node_index[end], round(math.dist(node, end), 1)] for end in ends]
    if links:
        links_out[sig] = links

print(f"Nodes: {len(nodes_out)}, Edges: {len(edges_out)}, Stations: {len(stations_out)} (skipped {skipped}), linked: {len(links_out)}")

# Sanity check against a known real-world rail distance: Stockholm C -> Mora C is ~329.6 km.
# Runs on the exact graph (and weights) being exported, so a broken contraction or a dropped
# line shows up here rather than as a wrong route in the app.
CHECK_FROM, CHECK_TO, CHECK_KM = "Cst", "Mrc", 329.6  # Stockholm C, Mora C
if CHECK_FROM not in stations_out or CHECK_TO not in stations_out:
    raise SystemExit(f"{CHECK_FROM} or {CHECK_TO} was not snapped to the network — refusing to export")
try:
    km = nx.shortest_path_length(g, node_list[stations_out[CHECK_FROM]], node_list[stations_out[CHECK_TO]], weight="weight") / 1000
except nx.NetworkXNoPath:
    raise SystemExit(f"No path {CHECK_FROM} -> {CHECK_TO} in the contracted graph — refusing to export")
print(f"Sanity check {CHECK_FROM} -> {CHECK_TO}: {km:.1f} km (expected ~{CHECK_KM})")
if abs(km - CHECK_KM) > 5:
    raise SystemExit(f"Route length {km:.1f} km is off by more than 5 km — refusing to export")

out = {"nodes": nodes_out, "edges": edges_out, "stations": stations_out, "links": links_out}
with open("RailNetwork.json", "w", encoding="utf-8") as f:
    json.dump(out, f, separators=(",", ":"))

size = os.path.getsize("RailNetwork.json")
print(f"RailNetwork.json size: {size / 1024:.0f} KB")
