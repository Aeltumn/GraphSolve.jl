# Defines the different graph types for each backend.
"""
    GraphBackend

    The basis for a type of graph based on a backend.
"""
abstract type GraphBackend end

"""
    JuliaGraphBackend

    Implements a graph backend based directly on Graphs.jl. Relies on two csv files to load
    graph data from.
    
    Nodes should have columns for `id`, `label`.
    Edges should have columns for `from`, and `to`.

    Ids should be from 0 to n.
    
    Remaining columns are read as properties.
"""
mutable struct JuliaGraphBackend <: GraphBackend
    nodes::String
    edges::String
    connector::Union{JuliaConnectorWrapper, Nothing}
end

JuliaGraphBackend(folder::String) = JuliaGraphBackend("$(folder)/nodes.csv", "$(folder)/edges.csv", nothing)
JuliaGraphBackend(nodes::String, edges::String) = JuliaGraphBackend(nodes, edges, nothing)

"""
    Neo4jBackend

    Implements a graph backend using Neo4J. Supports either the HTTP or Bolt protocol. Bolt protocol is implemented
    through a Python bridge using the official driver. The HTTP protocol is faster but only works on short queries
    whereas the Bolt protocol works for any query.

    HTTP protocol is normally https://hostname:7474, Bolt protocol is normally neo4j://hostname:7687.
"""
mutable struct Neo4jBackend <: GraphBackend
    url::String
    user::String
    password::String
    database::String
    bolt::Bool
    connector::Union{CypherConnector, Nothing}
end

Neo4jBackend(url::String, user::String, password::String, database::String, bolt::Bool) = Neo4jBackend(url, user, password, database, bolt, nothing)

"""
    SolvableGraph

    Stores relevant information for performing an optimization query
    on a graph.
"""
mutable struct SolvableGraph{T<:GraphBackend}
    graph::T
    instructions::Vector{Instruction}
end

SolvableGraph(graph::T) where {T<:GraphBackend} =
    SolvableGraph{T}(graph, Vector{Instruction}())