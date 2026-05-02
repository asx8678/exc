"""Directed-acyclic-graph helpers for dependency resolution.

Inspired by patterns from oh-my-pi (omp) project.

Typical use-case: given a set of tasks with declared dependencies, produce
an ordered list of *execution waves* where every task inside a wave can be
run in parallel because all its predecessors finished in earlier waves.
"""

from collections import defaultdict, deque
from typing import Hashable


def build_dependency_graph[T: Hashable](
    deps: dict[T, list[T]],
) -> dict[T, set[T]]:
    """Normalise a dependency map into a ``{node: set_of_deps}`` dict.

    All nodes mentioned as dependencies but absent as keys are added with an
    empty dependency set so the graph is complete.

    Args:
        deps: Mapping of *node → list of nodes it depends on*.

    Returns:
        Normalised ``{node: set[node]}`` graph.
    """
    graph: dict[T, set[T]] = {}
    for node, node_deps in deps.items():
        graph.setdefault(node, set()).update(node_deps)
        for dep in node_deps:
            graph.setdefault(dep, set())
    return graph


def detect_cycles[T: Hashable](graph: dict[T, set[T]]) -> list[T]:
    """Return the nodes that participate in a cycle (empty list if acyclic).

    Uses DFS colouring (white/grey/black) to find back-edges.

    Args:
        graph: ``{node: set_of_deps}`` as returned by
            :func:`build_dependency_graph`.

    Returns:
        List of nodes in cycles, or ``[]`` if the graph is acyclic.
    """
    WHITE, GREY, BLACK = 0, 1, 2
    colour: dict[T, int] = {n: WHITE for n in graph}
    cycle_nodes: set[T] = set()

    def _dfs(node: T) -> bool:
        colour[node] = GREY
        for neighbour in graph.get(node, set()):
            if colour.get(neighbour, WHITE) == GREY:
                cycle_nodes.add(node)
                cycle_nodes.add(neighbour)
                return True
            if colour.get(neighbour, WHITE) == WHITE:
                if _dfs(neighbour):
                    cycle_nodes.add(node)
        colour[node] = BLACK
        return node in cycle_nodes

    for n in list(graph):
        if colour[n] == WHITE:
            _dfs(n)

    return list(cycle_nodes)


def build_execution_waves[T: Hashable](graph: dict[T, set[T]]) -> list[list[T]]:
    """Topologically sort *graph* into parallel execution waves.

    Each wave contains nodes whose dependencies all appear in earlier waves,
    so every wave can be executed in parallel internally.

    Args:
        graph: ``{node: set_of_deps}`` as returned by
            :func:`build_dependency_graph`.

    Returns:
        Ordered list of waves; each wave is a list of nodes.

    Raises:
        ValueError: If the graph contains a cycle.
    """
    cycles = detect_cycles(graph)
    if cycles:
        raise ValueError(
            f"Dependency cycle detected involving: {sorted(str(n) for n in cycles)}"
        )

    # Kahn's algorithm
    in_degree: dict[T, int] = defaultdict(int)
    dependants: dict[T, list[T]] = defaultdict(list)  # dep → nodes that depend on it

    for node, deps in graph.items():
        in_degree.setdefault(node, 0)
        for dep in deps:
            in_degree[node] += 1
            dependants[dep].append(node)

    queue: deque[T] = deque(n for n, d in in_degree.items() if d == 0)
    waves: list[list[T]] = []

    while queue:
        wave = list(queue)
        queue.clear()
        waves.append(sorted(wave, key=str))  # deterministic order within wave
        for node in wave:
            for dependent in dependants[node]:
                in_degree[dependent] -= 1
                if in_degree[dependent] == 0:
                    queue.append(dependent)

    return waves
