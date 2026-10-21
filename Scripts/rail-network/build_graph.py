import glob
import math
import os
import re
import sqlite3
import sys

import networkx as nx
from shapely import wkb as shapely_wkb
from shapely.geometry import LineString, MultiLineString

RAILNET_DIR = "railnet"
# The columns `load_lines` selects and filters on; a layer without them is not the one we want.
COLUMNS = {"id", "geom", "Pl_Forb", "PlNamn", "Straknamn", "Bandel", "Status", "SpTyp"}


def version_key(name):
    """Orders NJDB names by the version they carry, newest last: as numbers rather than as text,
    where a hypothetical `3_10` would sort before `3_9`. The name itself breaks ties, so the order
    is total and doesn't depend on the order names arrive in."""
    return ([int(n) for n in re.findall(r"\d+", name)], name)


def find_geopackage():
    """The NJDB download's file name carries its version, so it changes between releases — take
    whatever GeoPackage is in `railnet/`, newest version first."""
    found = glob.glob(os.path.join(RAILNET_DIR, "**", "*.gpkg"), recursive=True)
    if not found:
        sys.exit(f"No .gpkg under {RAILNET_DIR}/ — run download_njdb.py first (see docs/rail-network.md)")
    return max(found, key=lambda path: version_key(os.path.basename(path)))


def find_table(con):
    """The layer `load_lines` can actually read. A GeoPackage lists its layers in `gpkg_contents`,
    and the one we want is picked by the columns the query needs rather than by its name, which
    carries the release version. A file that has no such layer is an error worth stopping on, not
    something to guess at."""
    rows = con.execute("SELECT table_name FROM gpkg_contents WHERE data_type = 'features'").fetchall()
    names = [name for (name,) in rows]
    usable = [name for name in names if COLUMNS <= {row[1] for row in con.execute(f"PRAGMA table_info('{name}')")}]
    if not usable:
        sys.exit(f"No layer in the GeoPackage has the columns {sorted(COLUMNS)}. Layers: {names}")
    # `gpkg_contents` has no guaranteed row order, so a file carrying two releases of the layer
    # would otherwise export whichever one SQLite happened to return first.
    newest = max(usable, key=version_key)
    if len(usable) > 1:
        print(f"Several usable layers {sorted(usable)}; taking the newest, {newest}")
    return newest


def gpkg_geom_to_wkb(blob):
    # GeoPackage binary header: 'GP' + version(1) + flags(1) + srs_id(int32) + envelope + WKB
    flags = blob[3]
    envelope_indicator = (flags >> 1) & 0x07
    envelope_len = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[envelope_indicator]
    header_len = 8 + envelope_len
    return blob[header_len:]


def snap(x, y):
    return (round(x, 1), round(y, 1))


def load_lines():
    path = find_geopackage()
    con = sqlite3.connect(path)
    table = find_table(con)
    print(f"Reading {table} from {path}")
    cur = con.cursor()
    cur.execute(
        f"""SELECT id, geom, Pl_Forb, PlNamn, Straknamn, Bandel FROM '{table}'
            WHERE Status = 'Öppen' AND SpTyp IN ('nhsp', 'ahsp', 'tågspår')"""
    )
    lines = []
    for row in cur.fetchall():
        rid, blob, pl_forb, pl_namn, straknamn, bandel = row
        if blob is None:
            continue
        try:
            geom = shapely_wkb.loads(gpkg_geom_to_wkb(blob))
        except Exception:
            continue
        if isinstance(geom, LineString):
            geoms = [geom]
        elif isinstance(geom, MultiLineString):
            geoms = list(geom.geoms)
        else:
            continue
        for g in geoms:
            if len(g.coords) >= 2:
                lines.append((rid, list(g.coords), pl_forb, pl_namn, straknamn, bandel))
    return lines


def build_graph(lines):
    g = nx.Graph()
    for rid, coords, pl_forb, pl_namn, straknamn, bandel in lines:
        for i in range(len(coords) - 1):
            a = snap(*coords[i])
            b = snap(*coords[i + 1])
            if a == b:
                continue
            dx = a[0] - b[0]
            dy = a[1] - b[1]
            dist = (dx * dx + dy * dy) ** 0.5
            if g.has_edge(a, b):
                if g[a][b]["weight"] <= dist:
                    continue
            # Which railway section (`Bandel`) and station or line (`PlNamn`) the track belongs to,
            # so a station's links (snap_stations.py) can stay on its own tracks.
            g.add_edge(a, b, weight=dist, bandel=bandel, pl_namn=pl_namn)
    return g


def split_edges(graph, splits):
    """Inserts nodes part-way along straight edges, so something can attach where a track has no
    vertex of its own. `splits` is `[(a, b, point), ...]` with `point` on edge `a`–`b`; several
    points on one edge go in in order along it, and a point that's already a node is left alone."""
    by_edge = {}
    for a, b, point in splits:
        a, b, point = tuple(a), tuple(b), tuple(point)
        if point not in graph and graph.has_edge(a, b):
            by_edge.setdefault((min(a, b), max(a, b)), set()).add(point)
    for (a, b), points in by_edge.items():
        chain = [a, *sorted(points, key=lambda p: math.dist(a, p)), b]
        attributes = {key: value for key, value in graph[a][b].items() if key != "weight"}
        graph.remove_edge(a, b)
        for u, v in zip(chain, chain[1:]):
            graph.add_edge(u, v, weight=math.dist(u, v), **attributes)


if __name__ == "__main__":
    lines = load_lines()
    print(f"Loaded {len(lines)} line segments")
    graph = build_graph(lines)
    print(f"Graph: {graph.number_of_nodes()} nodes, {graph.number_of_edges()} edges")
    components = list(nx.connected_components(graph))
    components.sort(key=len, reverse=True)
    print(f"Connected components: {len(components)}")
    print("Top 5 component sizes:", [len(c) for c in components[:5]])
