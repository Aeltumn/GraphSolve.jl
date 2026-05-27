# Defines various instructions that have to be executed on the graph.
"""
    Instructions

    The basis for any instructions executed on a graph.
"""
abstract type Instruction end

"""
    PathInstruction

    Stores a set of instructions used to populate an array of
    paths into [output]. Only [components] will be fetched from
    the graph.
"""
mutable struct PathInstruction <: Instruction
    output::Vector{Path}
    goal::PathQueryGoal
    source::NodeSelector
    target::NodeSelector
    include_edges::Bool
    constraints::Vector{PathConstraint}
    optimal::Union{OptimalDefinition, Nothing}
end

"""
    ProblemInstruction

    Stores a problem that needs to be solved on a set of paths.
"""
struct ProblemInstruction <: Instruction
    path::PathInstruction
    problem_definition
end

"""
    NodePropertyInstruction

    Stores an instruction to store the property [name]
    of all [component] type nodes in [path] to [target].
"""
struct NodePropertyInstruction <: Instruction
    target::NodePropertyDict
    path::PathInstruction
    component::GraphComponent
    name::String
end

"""
    EdgePropertyInstruction

    Stores an instruction to store the property [name]
    of all edges in [path] to [target].
"""
struct EdgePropertyInstruction <: Instruction
    target::EdgePropertyDict
    path::PathInstruction
    name::String
end