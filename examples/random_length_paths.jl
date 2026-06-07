"""
    An example that finds a very complicated set of paths with identical length.
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

    # Define a query to find the paths
    paths = find_paths!(graph, MaximizeSelection, LabelNodeSelector("Source"), LabelNodeSelector("Destination"), true)

    # Define which properties to extract
    node_properties = NodePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Source, "weight")
    extract_node_properties!(graph, paths, node_properties, Edges, "random")
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        0.9,
        Maximize,
        Hour(1),
        begin
            # The optimal solution assigns every source.
            sum([node_properties[s]["weight"] for s in sources])
        end
    )

    # Define a problem to select paths from the path query
    function path_selection(model, paths, x)
        # Define an integer for the random sum
        @variable(model, sum)

        # Ensure every path has the same random sum
        for path in paths
            path_sum = sum([node_properties[n]["random"] for n in get_path_nodes(path)])
            @constraint(model, x[p.id] * (path_sum - sum) == 0)
        end

        # Set the objective, to maximize weight of selected paths!
        @objective(model, Max, sum(x[p.id] * node_properties[p.src]["weight"] for p in paths))
    end
    define_problem!(graph, paths, path_selection)

    function print_path_results(graph)
        total_weight = isempty(paths) ? 0 : sum(node_properties[p.src]["weight"] for p in paths)
        println("Selected $(length(paths)) paths with a total weight of $(total_weight) and a random of $(isempty(paths) ? 0 : node_properties[paths[1].edges[1][1]]["random"])")
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
        define_graph(Neo4jBackend("http://localhost:7474", "neo4j", ENV["NEO4J_PASSWORD"], "s100", false), GraphSolveSettings())
    ],
)