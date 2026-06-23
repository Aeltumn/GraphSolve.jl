"""
    An example where reachability is used as foundational for an assignment problem.
"""
function define_maximized_assignments_graph(k, backend::GraphBackend, settings::GraphSolveSettings)
    graph = SolvableGraph(backend)

    # Define a query to find the reachable pairs, not returning edges
    paths = find_paths!(graph, LabelNodeSelector("Source"), LabelNodeSelector("Target"), false, false)

    # Define which properties to extract
    node_properties = NodePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Source, "max")
    extract_node_properties!(graph, paths, node_properties, Source, "random")
    extract_node_properties!(graph, paths, node_properties, Destination, "max")
    extract_node_properties!(graph, paths, node_properties, Destination, "random")

    @apply_path_constraint(graph, paths, node_properties[dst]["random"] >= k)
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        1.0,
        Maximize,
        Hour(1),
        begin
            # The optimal solution assigns every destination maximally, assuming there's enough sources.
            sum([node_properties[t]["random"] * node_properties[t]["max"] for t in destinations])
        end
    )

    # Define a problem to select paths from the path query
    function path_selection(model, paths, x)
        # Ensure sources are not over-assigned
        for node in get_source_nodes(paths)
            max = get(node_properties[node], "max", typemax(Int64))
            filtered_paths = filter(it -> it.src == node, paths)
            @constraint(model, sum(x[p.id] for p in filtered_paths) <= max)
        end

        # Ensure destinations are not over-assigned
        for node in get_destination_nodes(paths)
            max = get(node_properties[node], "max", typemax(Int64))
            filtered_paths = filter(it -> it.dst == node, paths)
            @constraint(model, sum(x[p.id] for p in filtered_paths) <= max)
        end

        # Set the objective to maximize the random values of all assignments
        @objective(model, Max, sum(x[p.id] * node_properties[p.dst]["random"] for p in paths))
    end
    define_problem!(graph, paths, path_selection)

    function print_path_results(graph)
        total_value = isempty(paths) ? 0 : sum(node_properties[p.dst]["random"] for p in paths)
        @info "For maximized assignment problem selected $(length(paths)) assignments with a total weight of $(total_value)"
        for path in paths
            @info "  -> $(path.src) to $(path.dst) with value $(node_properties[path.dst]["random"])"
        end
        return total_value
    end
    return graph, settings, print_path_results
end