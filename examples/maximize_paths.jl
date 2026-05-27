"""
    An example designed to force paths to be found incrementally
    as multiple paths are allowed per source.
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

    # Define a query to find the paths starting in half the sources and going to the destination
    # include edges so we can add bandwidth constraints!
    paths = find_paths!(
        graph, 
        MaximizeSelection, 
        LabelNodeSelector("Source"),
        LabelNodeSelector("Destination"),
        true
    )

    # Define which properties should be extracted so they are available to reference later
    node_properties = NodePropertyDict()
    edge_properties = EdgePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Source, "weight")
    extract_node_properties!(graph, paths, node_properties, Destination, "max") 
    extract_edge_properties!(graph, paths, edge_properties, "max")

    # Define path constraints which apply to the path query directly
    @apply_path_constraint(graph, paths, edge_properties[edge]["max"] >= node_properties[src]["weight"])
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        0.99,
        Maximize,
        Minute(10),
        begin
            1500
        end,
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
        println("Selected $(length(paths)) paths with a total weight of $(total_weight)")
        for path in paths
            println("  -> $(path.src) to $(path.dst) with weight $(node_properties[path.src]["weight"]) through $(path.edges) which have $(join([edge_properties[e]["max"] for e in path.edges], ", "))")
        end
        return total_weight
    end
    return graph, settings, print_path_results
end

# Run all graph algorithms and determine data
neo4jHttp = Neo4jBackend("http://localhost:7474", "neo4j", ENV["NEO4J_PASSWORD"], "mit-phone", false)
neo4jBolt = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "mit-phone", true)
julia = JuliaGraphBackend("run/test/mit-phone")
benchmark!(
    5,
    [
        define_graph(julia, GraphSolveSettings()),
        define_graph(neo4jHttp, GraphSolveSettings()),
        define_graph(neo4jBolt, GraphSolveSettings()),
    ]
)