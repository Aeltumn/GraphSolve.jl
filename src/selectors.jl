# Defines the different types of node selectors.
"""
    NodeSelector

    The basis for a type of selector that filters a group of nodes.
    Used for selecting source and destination nodes.
"""
abstract type NodeSelector end

"""
    AllNodeSelector

    Selects all nodes.
"""
struct AllNodeSelector <: NodeSelector end

"""
    IdNodeSelector

    Selects a number of nodes directly by id.
    Ids can be a vector or set.
"""
struct IdNodeSelector <: NodeSelector
    ids
end

"""
    LabelNodeSelector

    Selects a number of nodes directly by label.
"""
struct LabelNodeSelector <: NodeSelector
    label::String
end

"""
    CypherConditionNodeSelector

    Selects a number of nodes using a given condition,
    the condition should reference a node named `var`.
"""
struct CypherConditionNodeSelector <: NodeSelector
    base::NodeSelector
    condition::String
end