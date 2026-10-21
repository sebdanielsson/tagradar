import networkx as nx
from build_graph import build_graph, load_lines, split_edges


def douglas_peucker(points, tolerance):
    if len(points) < 3:
        return points

    def perpendicular_distance(pt, start, end):
        if start == end:
            return ((pt[0] - start[0]) ** 2 + (pt[1] - start[1]) ** 2) ** 0.5
        x0, y0 = pt
        x1, y1 = start
        x2, y2 = end
        num = abs((y2 - y1) * x0 - (x2 - x1) * y0 + x2 * y1 - y2 * x1)
        den = ((y2 - y1) ** 2 + (x2 - x1) ** 2) ** 0.5
        return num / den

    dmax, index = 0.0, 0
    for i in range(1, len(points) - 1):
        d = perpendicular_distance(points[i], points[0], points[-1])
        if d > dmax:
            index, dmax = i, d
    if dmax > tolerance:
        left = douglas_peucker(points[: index + 1], tolerance)
        right = douglas_peucker(points[index:], tolerance)
        return left[:-1] + right
    return [points[0], points[-1]]


def contract(graph, pinned=frozenset()):
    """Collapse degree-2 chains into single edges carrying the full polyline.
    `pinned` nodes (e.g. station locations) are kept even if they'd otherwise be a degree-2
    pass-through point, so every station stays individually addressable after contraction."""
    topology_nodes = {n for n in graph.nodes if graph.degree[n] != 2} | (pinned & graph.nodes.keys())
    contracted = nx.Graph()
    contracted.add_nodes_from(topology_nodes)
    visited_edges = set()

    for start in topology_nodes:
        for neighbor in list(graph.neighbors(start)):
            if (start, neighbor) in visited_edges:
                continue
            # Walk the chain starting at `start` -> `neighbor` until hitting another topology node.
            chain = [start, neighbor]
            prev, cur = start, neighbor
            visited_edges.add((start, neighbor))
            visited_edges.add((neighbor, start))
            while cur not in topology_nodes:
                nbrs = [n for n in graph.neighbors(cur) if n != prev]
                if not nbrs:
                    break
                nxt = nbrs[0]
                visited_edges.add((cur, nxt))
                visited_edges.add((nxt, cur))
                chain.append(nxt)
                prev, cur = cur, nxt
            end = cur
            length = sum(graph[chain[i]][chain[i + 1]]["weight"] for i in range(len(chain) - 1))
            if contracted.has_edge(start, end) and contracted[start][end]["weight"] <= length:
                continue
            contracted.add_edge(start, end, weight=length, chain=chain)
    return contracted


if __name__ == "__main__":
    import json

    lines = load_lines()
    graph = build_graph(lines)
    degree_hist = {}
    for n in graph.nodes:
        d = graph.degree[n]
        degree_hist[d] = degree_hist.get(d, 0) + 1
    print("Degree histogram:", dict(sorted(degree_hist.items())))

    with open("snapped_stations.json") as f:
        snapped = json.load(f)
    links = [link for v in snapped.values() for link in v.get("links", [])]
    split_edges(graph, [(*link["edge"], link["point"]) for link in links])
    pinned = {tuple(v["node"]) for v in snapped.values()} | {tuple(link["point"]) for link in links}
    print(f"Pinning {len(pinned)} station and link nodes")

    contracted = contract(graph, pinned=pinned)
    print(f"Contracted: {contracted.number_of_nodes()} nodes, {contracted.number_of_edges()} edges")

    total_points_before = sum(len(data["chain"]) for _, _, data in contracted.edges(data=True))
    for u, v, data in contracted.edges(data=True):
        pts = [(round(x, 1), round(y, 1)) for x, y in data["chain"]]
        data["chain"] = douglas_peucker(pts, tolerance=15.0)
    total_points_after = sum(len(data["chain"]) for _, _, data in contracted.edges(data=True))
    print(f"Chain points before simplify: {total_points_before}, after (15m tol): {total_points_after}")

    import pickle
    with open("contracted_graph.pkl", "wb") as f:
        pickle.dump(contracted, f)
    print("Saved contracted_graph.pkl")
