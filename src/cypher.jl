# Helper functions for generating Cypher queries.
"""
    CypherQuery

    Stores an element of a cypher query which can be efficiently
    converted.
"""
struct CypherQuery
    select::String
    conditions::Union{Nothing, Vector{String}}
end

"""
    merge_conditions

    Merges together a list of Cypher conditions.
"""
function merge_conditions(conditions)
    if isnothing(conditions) || isempty(conditions)
        return ""
    else
        return "WHERE $(join(conditions, " AND "))"
    end
end

"""
    flatten

    Flattens a cypher query into a single output.
"""
function flatten(query::CypherQuery)
    if isnothing(query.conditions)
        return query.select
    else
        return "$(query.select) WHERE $(join(query.conditions, " AND "))"
    end
end

"""
    as_query

    Converts a node selector into a CypherQuery object.
"""
function as_query(selector::NodeSelector, id::String)
    if selector isa AllNodeSelector
        return CypherQuery("($id)", nothing)
    elseif selector isa IdNodeSelector
        return CypherQuery("($id)", ["id($id) IN [$(join(selector.ids, ", "))]"])
    elseif selector isa LabelNodeSelector
        return CypherQuery("($id:`$(selector.label)`)", nothing)
    elseif selector isa CypherConditionNodeSelector
        # Modify the base query and add the additional condition!
        base = as_query(selector.base, id)
        condition = replace(selector.condition, "var" => id)
        new_conditions = isnothing(base.conditions) ? [condition] : [base.conditions... , condition]
        return @set base.conditions = new_conditions
    else
        error("Invalid selector type `$(selector)`")
    end
end

"""
    as_query_variable

    Converts a node selector into a query fragment that stores the list
    of nodes into variable id.
"""
function as_query_variable(selector::NodeSelector, id::String)
    return "MATCH $(flatten(as_query(selector, "n"))) WITH collect(n) as $(id)"
end

# Defines the operators and how they convert from Julia to Cypher.
const OPERATOR_MAPPINGS = Dict(
    :&& => "AND",
    :|| => "OR",
    :(==) => "=",
    :(!=) => "<>",
    :>= => ">=",
    :<= => "<=",
    :>  => ">",
    :<  => "<",
    :+ => "+",
    :- => "-",
    :* => "*",
    :/ => "/",
)

function ref_to_cypher(expr::Expr)
    obj = expr.args[1]
    key = expr.args[2]
    if !(key isa String)
        error("Property key must be string literal")
    end

    if obj isa Expr && obj.head == :ref
        idx = obj.args[2]
        var = idx == :src ? "s" :
            idx == :dst ? "t" :
            idx == :edge || idx == :edges ? "e" :
            idx == :node || idx == :nodes ? "n" :
            error("Unknown node variable $(idx)")
        return "$var.$key"
    end

    error("Unsupported expression reference")
end

function call_to_cypher(expr::Expr)
    operator = expr.args[1]
    if haskey(OPERATOR_MAPPINGS, operator)
        lhs = expr_to_cypher(expr.args[2])
        rhs = expr_to_cypher(expr.args[3])
        return "($lhs $(OPERATOR_MAPPINGS[operator]) $rhs)"
    end
    error("Unsupported operator $operator")
end

function expr_to_cypher(expr)
     if expr isa Symbol
        return symbol_to_cypher(expr)
    elseif expr isa String
        return repr(expr)
    elseif expr isa Number
        return string(expr)
    elseif expr isa Expr
        if expr.head == :call
            return call_to_cypher(expr)
        elseif expr.head == :ref
            return ref_to_cypher(expr)
        else
            error("Unsupported expression head $(expr.head)")
        end
    end
    error("Unsupported expression type $(typeof(expr))")
end

"""
    convert_to_cypher

    Attempts to convert the given expression into a Cypher condition
    which can be resolved by a Cypher-compatible database backend.
"""
function convert_to_cypher(expr::Expr)
    try
        return expr_to_cypher(expr)
    catch err
        # showerror(stdout, err, catch_backtrace())
        return nothing
    end
end

"""
    evaluate_constraint

    Evaluates if a path constraint holds for a path, based on the given source, destination and edge ids.
"""
function evaluate_constraint(constraint::PathConstraint, src, dst, node, nodes, edge, edges)
    return constraint.constraint(src, dst, node, nodes, edge, edges)
end