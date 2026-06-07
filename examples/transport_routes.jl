"""
    An example where sources are assigned on a transport route to a destination.
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
    paths = find_paths!(graph, AssignSourcesToDestinations, LabelNodeSelector("Source"), LabelNodeSelector("Destination"), true)

    # Define which properties to extract
    node_properties = NodePropertyDict()
    edge_properties = EdgePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Edges, "random") 
    extract_edge_properties!(graph, paths, edge_properties, "weight")
    
    # Ensure every route contains a high value node
    @apply_path_constraint(graph, paths, any(node -> node["random"] >= 80, nodes))
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        0.9,
        Minimize,
        Hour(1),
        begin
            # An ideal solution uses minimal route weights.
            length(sources)
        end
    )

    # Define a problem to select paths from the path query
    function path_selection(model, paths, x)
        # Ensure that every source is assigned
        for node in get_source_nodes(paths)
            filtered_paths = filter(it -> it.src == node, paths)
            @constraint(model, sum(x[p.id] for p in filtered_paths) == 1)
        end

        # Set the objective to minimize the total edge weights
        weighted_paths = [(p, sum([edge_properties[e]["weight"] for e in p.edges])) for p in paths]
        @objective(model, Max, sum(x[p.id] * weight for (p, weight) in weighted_paths))
    end
    define_problem!(graph, paths, path_selection)

    function print_path_results(graph)
        total_weight = isempty(paths) ? 0 : sum(sum([edge_properties[e]["weight"] for e in p.edges]) for p in paths)
        println("Selected $(length(paths)) paths with a total weight of $(total_weight)")
        for path in paths
            println("  -> $(path.src) to $(path.dst) with weight $(sum([edge_properties[e]["weight"] for e in path.edges]))) through $(path.edges)")
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