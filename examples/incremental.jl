"""
    An example which shows how the algorithm performs
    on an adversarial dataset.
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
        AssignSourcesToDestinations, 
        LabelNodeSelector("Source"),
        LabelNodeSelector("Destination"),
        true
    )

    # Define which properties should be extracted so they are available to reference later
    node_properties = NodePropertyDict()
    edge_properties = EdgePropertyDict()
    extract_node_properties!(graph, paths, node_properties, Source, "weight")
    extract_edge_properties!(graph, paths, edge_properties, "max")

    # Define path constraints which apply to the path query directly
    @apply_path_constraint(graph, paths, edge_properties[edge]["max"] >= node_properties[src]["weight"])
    
    # Define the optimal value of the problem
    @optimal(
        graph,
        paths,
        # Try to find the optimal solution!
        1.0,
        # Maximize the value of the problem (should match the objective)
        Maximize,
        # Cap out at 1 hour of calculation time if we cannot find an optimal solution!
        Hour(1),
        begin
            min(
                # The optimal value is the less of either the maximum weight or the minimum capacity depending
                # on which is lower as it bounds the other.
                sum([node_properties[s]["weight"] for s in sources])
            )
        end
    )

    # Define a problem to select paths from the path query
    function path_selection(model, paths, x)
        # Ensure bandwidth of edges are not exceeded!
        edges = get_unique_edges(paths)
        for edge in edges
            # Best practice: cache all properties referenced in constraints so they are quickly re-resolved!
            max = get(edge_properties[edge], "max", typemax(Int64))
            edge_paths = filter(it -> edge ∈ it.edges, paths)
            @constraint(model, sum(x[p.id] * node_properties[p.src]["weight"] for p in edge_paths) <= max)
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

# Run all graph algorithms and determine database
benchmark!(
    5,
    [
        define_graph(JuliaGraphBackend("run/dataset/adversarial"), GraphSolveSettings())
    ]
)