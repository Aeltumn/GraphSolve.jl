"""
    An example where sources are assigned on a transport route to a destination.
"""
function define_transport_routes_graph(backend::GraphBackend, settings::GraphSolveSettings)
    graph = SolvableGraph(backend)

    # Define a query to find the paths
    paths = find_paths!(graph, LabelNodeSelector("Source"), LabelNodeSelector("Target"), true, true, "weight")

    # Define which properties to extract
    node_properties = NodePropertyDict()
    edge_properties = EdgePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Edges, "random") 
    extract_edge_properties!(graph, paths, edge_properties, "weight")
    
    # Ensure every route contains a high value node
    @apply_path_constraint(graph, paths, any(n -> node_properties[n]["random"] >= 70, nodes))
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        Minimize,
        false,
        Hour(1),
        2,
        # An optimal solution requires finding all eligible paths between source-target pairs as
        # we have to find the paths with minimal weight.
        nothing
    )

    # Define a problem to select paths from the path query
    function path_selection(model, paths, x)
        # Ensure that every source is assigned one route
        require_sources_exactly_one_target(model, paths, x)

        # Set the objective to minimize the total edge weights
        weighted_paths = [(p.id, sum([edge_properties[e]["weight"] for e in p.edges])) for p in paths]
        @objective(model, Min, sum(x[pid] * weight for (pid, weight) in weighted_paths))
    end
    define_problem!(graph, paths, path_selection)

    function print_path_results(graph)
        total_weight = isempty(paths) ? 0 : sum(sum([edge_properties[e]["weight"] for e in p.edges]) for p in paths)
        @info "For transport routes selected $(length(paths)) paths with a total weight of $(total_weight)"
        for path in paths
            @info "  -> $(path.src) to $(path.dst) with weight $(sum([edge_properties[e]["weight"] for e in path.edges])) through $(path.edges)"
        end
        return total_weight
    end
    return graph, settings, print_path_results
end