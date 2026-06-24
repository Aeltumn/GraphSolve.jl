"""
    An example that finds a very complicated set of paths with identical length.
"""
function define_random_length_paths_graph(backend::GraphBackend, settings::GraphSolveSettings)
    graph = SolvableGraph(backend)

    # Define a query to find the paths
    paths = find_paths!(graph, LabelNodeSelector("Source"), LabelNodeSelector("Target"), true, true)

    # Define which properties to extract
    node_properties = NodePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Source, "weight")
    extract_node_properties!(graph, paths, node_properties, Edges, "random")
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        1.0,
        Maximize,
        true,
        Hour(1),
        begin
            # The optimal solution assigns every source.
            sum([node_properties[s]["weight"] for s in sources])
        end
    )

    # Define a problem to select paths from the path query
    function path_selection(model, paths, x)
        # Determine the sum of each path
        path_sums = Dict(
            p.id => sum(node_properties[n]["random"] for n in get_path_nodes(p))
            for p in paths
        )

        # Define a variable for each sum that could be chosen
        unique_sums = unique(values(path_sums))
        @variable(model, y[s in unique_sums], Bin)

        # Choose exactly one sum
        @constraint(model, sum(y) == 1)

        # Bind paths to the sum selection
        for p in paths
            s = path_sums[p.id]
            @constraint(model, x[p.id] <= y[s])
        end

        # Set the objective, to maximize weight of selected paths!
        @objective(model, Max, sum(x[p.id] * node_properties[p.src]["weight"] for p in paths))
    end
    define_problem!(graph, paths, path_selection)

    function print_path_results(graph)
        total_weight = isempty(paths) ? 0 : sum(node_properties[p.src]["weight"] for p in paths)
        @info "For random length paths problem selected $(length(paths)) paths with a total weight of $(total_weight) and a random of $(isempty(paths) ? 0 : node_properties[paths[1].edges[1][1]]["random"])"
        for path in paths
            @info "  -> $(path.src) to $(path.dst) with weight $(node_properties[path.src]["weight"]) through $(path.edges)"
        end
        return total_weight
    end
    return graph, settings, print_path_results
end