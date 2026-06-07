"""
    A simple example of a bandwidth constrained configuration.
    Assigns sources to destinations without exceeding any limits.
"""
function define_bandwidth_constrained_graph(backend::GraphBackend, settings::GraphSolveSettings)
    graph = SolvableGraph(backend)

    # Define a query to find the paths
    paths = find_paths!(graph, AssignSourcesToDestinations, LabelNodeSelector("Source"), LabelNodeSelector("Destination"), true)

    # Define which properties to extract
    node_properties = NodePropertyDict()
    edge_properties = EdgePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Source, "weight")
    extract_node_properties!(graph, paths, node_properties, Destination, "max") 
    extract_edge_properties!(graph, paths, edge_properties, "max")

    # Define path constraints which apply to the path query directly
    @apply_path_constraint(graph, paths, edge_properties[edge]["max"] >= node_properties[src]["weight"])
    @apply_path_constraint(graph, paths, node_properties[dst]["max"] >= node_properties[src]["weight"])
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        0.9,
        Maximize,
        Hour(1),
        begin
            min(
                # The optimal value is the less of either the maximum weight or the minimum capacity depending
                # on which is lower as it bounds the other.
                sum([node_properties[s]["weight"] for s in sources]),
                sum([node_properties[t]["max"] for t in destinations])
            )
        end
    )

    # Define a problem to select paths from the path query
    function path_selection(model, paths, x)
        # Ensure bandwidth of edges are not exceeded!
        edges = get_unique_edges(paths)
        for edge in edges
            max = get(edge_properties[edge], "max", typemax(Int64))
            edge_paths = filter(it -> edge ∈ it.edges, paths)
            @constraint(model, sum(x[p.id] * node_properties[p.src]["weight"] for p in edge_paths) <= max)
        end

        # Ensure that the capacity of each destination node is not exceeded!
        for node in get_destination_nodes(paths)
            max = get(node_properties[node], "max", typemax(Int64))
            node_paths = filter(it -> it.dst == node, paths)
            @constraint(model, sum(x[p.id] * node_properties[p.src]["weight"] for p in node_paths) <= max)
        end

        # Set the objective, to maximize weight of selected paths!
        @objective(model, Max, sum(x[p.id] * node_properties[p.src]["weight"] for p in paths))
    end
    define_problem!(graph, paths, path_selection)

    function print_path_results(graph)
        total_weight = isempty(paths) ? 0 : sum(node_properties[p.src]["weight"] for p in paths)
        println("For bandwidth constrained problem selected $(length(paths)) paths with a total weight of $(total_weight)")
        for path in paths
            println("  -> $(path.src) to $(path.dst) with weight $(node_properties[path.src]["weight"]) through $(path.edges) which have $(join([edge_properties[e]["max"] for e in path.edges], ", "))")
        end
        return total_weight
    end
    return graph, settings, print_path_results
end