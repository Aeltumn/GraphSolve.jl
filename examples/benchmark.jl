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
using Logging
using LoggingExtras

include("bandwidth_constrained.jl")
include("maximized_assignments.jl")
include("random_length_paths.jl")
include("transport_routes.jl")

# Run all graph algorithms and determine database
manual = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "manual", true)
s100 = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "s100", true)
s1000 = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "s1000", true)
s10000 = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "s10000", true)
unitedPower = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "united-power", true)
mitPhone = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "mit-phone", true)
slashdot = Neo4jBackend("neo4j://localhost:7687", "neo4j", ENV["NEO4J_PASSWORD"], "slashdot", true)

benchmark!(
    0,
    [
        define_transport_routes_graph(s1000, GraphSolveSettings()),
    
        # define_maximized_assignments_graph(manual, GraphSolveSettings()),
        # define_maximized_assignments_graph(s1000, GraphSolveSettings()),
        # define_maximized_assignments_graph(unitedPower, GraphSolveSettings()),
        # define_maximized_assignments_graph(mitPhone, GraphSolveSettings()),
        # define_maximized_assignments_graph(99, s10000, GraphSolveSettings()),
        # define_maximized_assignments_graph(95, s10000, GraphSolveSettings()),
        # define_maximized_assignments_graph(90, s10000, GraphSolveSettings()),
        # define_maximized_assignments_graph(80, s10000, GraphSolveSettings()),
        # define_maximized_assignments_graph(75, s10000, GraphSolveSettings()),
        # define_maximized_assignments_graph(50, s10000, GraphSolveSettings()),
        # define_maximized_assignments_graph(25, s10000, GraphSolveSettings()),
        # define_maximized_assignments_graph(0, s10000, GraphSolveSettings()),
        
        # define_maximized_assignments_graph(manual, GraphSolveSettings()),
        # define_transport_routes_graph(manual, GraphSolveSettings()),
        # define_bandwidth_constrained_graph(manual, GraphSolveSettings()),
        # define_random_length_paths_graph(manual, GraphSolveSettings()),
    ]
)