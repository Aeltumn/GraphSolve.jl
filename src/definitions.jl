# Defines all available graph instructions per backend.
mutable struct ExecutionContext
    profiler::TimerOutput
    settings::GraphSolveSettings
    instruction::PathInstruction
    include_edges::Bool
    include_nodes::Bool

    fetched_sources::Set{Int}
    fetched_targets::Set{Int}
    fetched_nodes::Set{Int}
    fetched_edges::Set{Edge}

    source_properties::Vector{String}
    target_properties::Vector{String}
    node_properties::Vector{String}
    edge_properties::Vector{String}

    source_properties_instructions::IdDict{NodePropertyDict, Vector{NodePropertyInstruction}}
    target_properties_instructions::IdDict{NodePropertyDict, Vector{NodePropertyInstruction}}
    node_properties_instructions::IdDict{NodePropertyDict, Vector{NodePropertyInstruction}}
    edge_properties_instructions::IdDict{EdgePropertyDict, Vector{EdgePropertyInstruction}}

    source_constraints::Vector{PathConstraint}
    target_constraints::Vector{PathConstraint}
    source_target_constraints::Vector{PathConstraint}
    node_constraints::Vector{PathConstraint}
    edge_constraints::Vector{PathConstraint}
    path_constraints::Vector{PathConstraint}

    source::NodeSelector
    target::NodeSelector
end

"""
    create_connector

    Creates a new connector based on the backend type.
"""
function create_connector(backend::GraphBackend, settings::GraphSolveSettings, instruction::PathInstruction)
    error("Backend not fully implemented")
end

"""
    fetch_node_properties

    Fetches properties for nodes in all given paths, avoiding duplicates.
"""
function fetch_node_properties(profiler::TimerOutput, connector::Connector, nodes::Set{Int}, path_instructions)
    error("Backend not fully implemented")
end

"""
    fetch_edge_properties

    Fetches properties for edges in all given paths, avoiding duplication.
"""
function fetch_edge_properties(profiler::TimerOutput, connector::Connector, edges::Set{Edge}, path_instructions)
    error("Backend not fully implemented")
end

"""
    perform_node_pre_fetch

    Performs node pre-fetching in [context].
"""
function perform_node_pre_fetch(context::ExecutionContext, connector::Connector)
    error("Backend not fully implemented")
end

"""
    get_all_paths

    Executes a query to fetch all paths between the given sources and targets.
"""
function get_all_paths(context::ExecutionContext, connector::Connector, source::NodeSelector, target::NodeSelector)
    error("Backend not fully implemented")
end

"""
    get_shortest_paths

    Executes a query to fetch the shortest paths between the given sources and targets.
"""
function get_shortest_paths(context::ExecutionContext, connector::Connector, source::NodeSelector, target::NodeSelector, output::Vector{Path}, collection::Set{Path}, weight_property::Union{String, Nothing})
    error("Backend not fully implemented")
end

"""
    get_k_shortest_paths

    Executes a query to fetch the k shortest paths between the given source and target node.
"""
function get_k_shortest_paths(context::ExecutionContext, connector::Connector, source::Int, target::Int, k::Int, output::Vector{Path}, weight_property::Union{String, Nothing})
    error("Backend not fully implemented")
end

"""
    reset

    Resets all output data on [graph].
"""
function reset!(graph::SolvableGraph)
    for instruction in graph.instructions
        if instruction isa PathInstruction
            empty!(instruction.output)
        elseif instruction isa NodePropertyInstruction
            empty!(instruction.target)
        elseif instruction isa EdgePropertyInstruction
            empty!(instruction.target)
        end
    end
end