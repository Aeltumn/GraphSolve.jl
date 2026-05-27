# GraphSolve.jl
## Overview
GraphSolve is a library for Julia that lets you solve constrained path traversal problems through [JuMP](https://jump.dev/JuMP.jl/stable/) contraint solving backed by the [Neo4j graph database](https://neo4j.com/). 

This library was developed as part of a Master's thesis at the [Eindhoven University of Technology](https://www.tue.nl/en/)'s [database group](https://www.tue.nl/en/research/research-groups/data-science/data-and-artificial-intelligence/database-group).

## Usage
GraphSolve is not available in the regular package repository, it has to be manually downloaded and referenced as a library as follows:
```julia
using Pkg
Pkg.develop(path="../path/to/GraphSolve")
```

You also have to install a Python package through CondaPkg to support [Neo4j's Bolt Protocol](https://neo4j.com/docs/bolt/current/bolt/):
```
conda add neo4j-python-driver
```

### Basic Usage
GraphSolve revolves around the creation of a `SolvableGraph` object which will hold all necessary information to formulate a constrained path traversal problem. This object can be instantiated by passing it a backend which determines which graph database is used. For example, this sets up a graph backed by a Neo4j database running locally:
```julia
graph = SolvableGraph(Neo4jBackend("http://localhost:7474", "neo4j", "password", "database", false))
```

This graph can defined with your constraints and problem definition:
```julia
# Define a query to find any paths from foo -> bar nodes
paths = find_paths!(graph, AssignSourcesToDestinations,LabelNodeSelector("foo"), LabelNodeSelector("bar"), false)

# Define which variables we want to involve in our constriants explicitly
node_properties = NodePropertyDict()
extract_node_properties!(graph, paths, node_properties, Destination, "paths")

# Define constraints to paths to only match nodes of the same color
@apply_path_constraint(graph, paths, node_properties[dst]["color"] == node_properties[src]["color"])

# Define the optimal value of the problem
@optimal(
    graph,
    paths,
    # Try to find a solution that is within 1% of the optimal value!
    0.99,
    # Maximize the value of the problem (should match the objective)
    Maximize,
    # Cap out at 1 hour of calculation time if we cannot find an optimal solution!
    Hour(1),
    begin
        # The maximum score is if every destination is maxed out!
        sum([node_properties[t]["paths"] for t in destinations])
    end
)

# Define the JuMP model with custom constraints
function configure(model, paths, x)
    # Ensure that the maximum of each destination node is not exceeded!
    for node in get_destination_nodes(paths)
        max = get(node_properties[node], "paths", typemax(Int64))
        node_paths = filter(it -> it.dst == node, paths)
        @constraint(model, sum(x[p.id] for p in node_paths) <= max)
    end

    # Set the objective, to maximize the number of selected paths!
    @objective(model, Max, sum(x[p.id] for p in paths))
end
define_problem!(graph, paths, configure)
```

And finally the graph can be executed to solve it:
```julia
execute!(graph, GraphSolveSettings())
```
By defining GraphSolveSettings with no fields the default settings will be used which will generally be the fastest. You can look at the documentation of the GraphSolveSettings struct for more information on the different available performance enchancements.

Look at the [examples](https://github.com/Aeltumn/GraphSolve.jl/tree/main/examples) folder for more examples on how to use the library.