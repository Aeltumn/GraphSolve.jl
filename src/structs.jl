# Contains basic structs which are publicly exposed.
@enum SolutionMode begin
    AllPaths
    IncrementalPathSearch
end
@enum AllPathsAlgorithm begin
    Cypher
    ApocAll
end
@enum Objective begin
    Minimize
    Maximize
end
@enum SolverType begin
    HiGHSSolver
    SCIPSolver
end
@enum GraphComponent Source Edges Destination
"""
    PathQueryGoal

    Defines the different goals a path query can have.

    [AssignSourcesToDestinations] attempts to find an assignment for each source to some destination.
    [MaximizeSelection] selects as many paths as possible, regardless of origin or target.
"""
@enum PathQueryGoal begin
    AssignSourcesToDestinations
    MaximizeSelection
end
const Edge = Tuple{Int, Int}
const NodePropertyDict = Dict{Int, Dict{String, Any}}
const EdgePropertyDict = Dict{Edge, Dict{String, Any}}

"""
    GraphSolveSettings

    Stores a number of settings that affect how GraphSolve attempts
    to solve a problem. Can be used to disable certain optimizations
    for testing purposes.

    [mode]
    The mode used to solve the problem, default is IncrementalPathSearch.

    [all_paths_algorithm]
    Defines the database algorithm to use.
    
    [embed_properties]
    Embeds fetching node and edge properties into a single query instead of running a separate
    request later to fetch the properties.

    [use_async_scheduling]
    Enables async scheduling of solving tasks.

    [preload_nodes]
    Pre-loads nodes in a separate database request instead of in a path query.

    [apply_path_constraints]
    Whether to apply path constraints.

    [push_down_constraints]
    Whether to push down constraints to database queries where possible.

    [re_use_constraint_solutions]
    Re-uses constraint solutions from previous runs when iterating.

    [solver_type]
    Which type of solver to use, SCIP performs better than HiGHS on large graphs.
"""
struct GraphSolveSettings
    mode::SolutionMode
    all_paths_algorithm::AllPathsAlgorithm
    embed_properties::Bool
    use_async_scheduling::Bool
    preload_nodes::Bool
    apply_path_constraints::Bool
    push_down_constraints::Bool
    re_use_constraint_solutions::Bool
    solver_type::SolverType
    profiler::TimerOutput
end

GraphSolveSettings(
    mode::SolutionMode,
    all_paths_algorithm::AllPathsAlgorithm,
    embed_properties::Bool,
    use_async_scheduling::Bool,
    preload_nodes::Bool,
    apply_path_constraints::Bool,
    push_down_constraints::Bool,
    re_use_constraint_solutions::Bool,
    solver_type::SolverType
) = GraphSolveSettings(mode, all_paths_algorithm, embed_properties, use_async_scheduling, preload_nodes, apply_path_constraints, push_down_constraints, re_use_constraint_solutions, solver_type, TimerOutput())

# Define a default variant with all the best options!
GraphSolveSettings() = GraphSolveSettings(IncrementalPathSearch, Cypher, true, true, true, true, true, true, SCIPSolver, TimerOutput())

"""
    PathConstraint

    Stores a constraint to apply to a set of paths.
"""
struct PathConstraint
    symbols::Set{Symbol}
    constraint
    cypher::Union{String, Nothing}
end

"""
    OptimalDefinition

    Defines the optimal value of a problem.
"""
struct OptimalDefinition
    p
    mode::Objective
    compiled
    timeout
    start_time
end

"""
    Path

    Stores a single path through a graph in terms of node ids.
    Elements are present or nothing based on the graph components
    that were requested.
"""
struct Path
    id::Int
    src::Int
    dst::Int
    edges::Union{Vector{Edge}, Nothing}
end

# Define equals and hash code for paths so we can put them in sets
Base.:(==)(a::Path, b::Path) = (
    a.src == b.src &&
    a.dst == b.dst &&
    (a.edges === b.edges || a.edges == b.edges)
)

Base.hash(p::Path, h::UInt) = hash((p.src, p.dst, p.edges === nothing ? () : p.edges), h)