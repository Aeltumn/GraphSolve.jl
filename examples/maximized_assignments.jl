"""
    An example where reachability is used as foundational for an assignment problem.
"""

# Build against dev prototype
using Revise
using Pkg
Pkg.develop(path=".")

using GraphSolve
using JuMP
using Dates

function define_graph(backend::GraphBackend, settings::GraphSolveSettings)
    graph = SolvableGraph(backend)

    # Define a query to find the reachable pairs, not returning edges
    paths = find_paths!(graph, MaximizeSelection, LabelNodeSelector("Source"), LabelNodeSelector("Destination"), false)

    # Define which properties to extract
    node_properties = NodePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Source, "max")
    extract_node_properties!(graph, paths, node_properties, Destination, "max")
    extract_node_properties!(graph, paths, node_properties, Destination, "random")
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        0.9,
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
        total_weight = isempty(paths) ? 0 : sum(node_properties[p.src]["weight"] for p in paths)
        println("Selected $(length(paths)) paths with a total weight of $(total_weight)")
        for path in paths
            println("  -> $(path.src) to $(path.dst) with weight $(node_properties[path.src]["weight"]) through $(path.edges) which have $(join([edge_properties[e]["max"] for e in path.edges], ", "))")
        end
        return total_weight
    end
    return graph, settings, print_path_results
end

# Run all graph algorithms and determine database
benchmark!(
    3,
    [
        define_graph(Neo4jBackend("http://localhost:7474", "neo4j", ENV["NEO4J_PASSWORD"], "manual", false), GraphSolveSettings()),
        define_graph(Neo4jBackend("http://localhost:7474", "neo4j", ENV["NEO4J_PASSWORD"], "s1000", false), GraphSolveSettings())
    ],
)