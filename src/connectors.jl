# Defines the different connectors.
"""
    Connector

    The generic base for a connector.
"""
abstract type Connector end

"""
    JuliaConnectorWrapper

    A wrapper around a connector storing a Julia graph instance.
"""
struct JuliaConnectorWrapper <: Connector
    graph::SimpleDiGraph
    nodes::Dict{Int, String}
    node_properties::NodePropertyDict
    edge_properties::EdgePropertyDict
end

"""
    CypherConnector

    The generic base for a Cypher-based connector.
"""
abstract type CypherConnector <: Connector end

"""
    HttpNeo4jConnector

    Implements an HTTP connection to Neo4j.
"""
mutable struct HttpNeo4jConnector <: CypherConnector
    url::String
    headers::Dict{String, String}
    database::String
    projected::Bool
end

"""
    BoltNeo4jConnector

    Implements a connection to Neo4j over the Bolt protocol.
"""
mutable struct BoltNeo4jConnector <: CypherConnector
    driver
    database::String
    projected::Bool
end

"""
    query_cypher

    Queries the given [connector] with the given [query].
"""
function query_cypher(profiler::TimerOutput, connector::CypherConnector, query, process_row)
    error("Selected connector has not been implemented properly")
end