"""
    Sets up a benchmark for the other example problems.
"""

# Build against dev prototype
using Revise
using Pkg
Pkg.develop(path=".")

using GraphSolve
using JuMP
using Dates

include("bandwidth_constrained.jl")
include("maximized_assignments.jl")
include("random_length_paths.jl")
include("transport_routes.jl")

# Run all graph algorithms and determine database
neo4jHttp = Neo4jBackend("http://localhost:7474", "neo4j", ENV["NEO4J_PASSWORD"], "s1000", false)
neo4jBolt = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "s100", true)
julia = JuliaGraphBackend("run/test/s100")
benchmark!(
    3,
    [
        define_bandwidth_constrained_graph(neo4jHttp, GraphSolveSettings()),
        define_maximized_assignments_graph(neo4jHttp, GraphSolveSettings()),
        define_random_length_paths_graph(neo4jHttp, GraphSolveSettings()),
        define_transport_routes_graph(neo4jHttp, GraphSolveSettings()),
    ]
)