module GraphSolve

using Dates
using Random
using Graphs
using TimerOutputs
using Accessors
using JuMP
using HiGHS
using SCIP

include("selectors.jl")
include("structs.jl")
include("instructions.jl")
include("connectors.jl")
include("graph.jl")
include("definitions.jl")
include("incremental.jl")
include("executor.jl")
include("macros.jl")
include("benchmark.jl")
include("cypher.jl")

include("julia/loader.jl")
include("julia/implementation.jl")
include("neo4j/http_connector.jl")
include("neo4j/bolt_connector.jl")
include("neo4j/implementation.jl")

export
    # Structs
    GraphBackend,
    JuliaGraphBackend,
    Neo4jBackend,
    SolvableGraph,
    Path,
    NodePropertyDict,
    EdgePropertyDict,
    PathInstruction,
    PathConstraint,
    GraphSolveSettings,
    OptimalDefinition,
    NodeSelector,
    AllNodeSelector,
    IdNodeSelector,
    LabelNodeSelector,
    CypherConditionNodeSelector,

    # Enums
    Source,
    Edges,
    Destination,

    AllPaths,
    IncrementalPathSearch,

    Cypher,
    ApocAll,
    Yen,

    AllPairs,
    SingleSource,
    ApocShortest,
    
    AssignSourcesToDestinations,
    MaximizeSelection,

    Minimize,
    Maximize,

    HiGHSSolver,
    SCIPSolver,

    # Functions
    find_paths!,
    extract_node_properties!,
    extract_edge_properties!,
    define_problem!,
    execute!,
    get_symbols_in,
    get_source_nodes,
    get_destination_nodes,
    get_unique_edges,
    benchmark!,
    convert_to_cypher,

    # Macros
    @apply_path_constraint,
    @optimal
end