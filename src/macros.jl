# Defines macros available for usage alongside fucntions to define the graph instructions.
"""
    find_paths!

    Adds a new instruction to [graph] to determine all paths from nodes called [source] to
    nodes called [target] and store them into the returned vector. Edges are included if requested,
    otherwise we only find pairs of nodes that have some connection.

    If [unique] is true, paths can only be selected a single time. Otherwise, paths can be selected as
    many times as allowed within constraints.
"""
function find_paths!(graph::SolvableGraph, source::NodeSelector, target::NodeSelector, unique::Bool, include_edges::Bool=false, weight_property::Union{String, Nothing}=nothing)
    paths = Vector{Path}()
    push!(
        graph.instructions,
        PathInstruction(
            paths,
            source,
            target,
            unique,
            include_edges,
            weight_property,
            Vector{PathConstraint}(),
            nothing
        )
    )
    return paths
end

"""
   extract_node_properties!

   Adds a new instruction to [graph] to extract the property [name] from all [type] in [paths]
   and store it into [property_dict].
"""
function extract_node_properties!(graph::SolvableGraph, paths::Vector{Path}, property_dict::NodePropertyDict, type::GraphComponent, name::String)
    local instructions = graph.instructions
    local id = findfirst(it -> it isa PathInstruction && it.output === paths, instructions)
    if id === nothing
        error("Could not find the instruction for the paths variable, is it from this graph?")
    end
    local path_instruction = instructions[id]
    push!(
        graph.instructions,
        NodePropertyInstruction(
            property_dict,
            path_instruction,
            type,
            name
        )
    )
end

"""
   extract_edge_properties!

   Adds a new instruction to [graph] to extract the property [name] from all edges in [paths]
   and store it into [property_dict].
"""
function extract_edge_properties!(graph::SolvableGraph, paths::Vector{Path}, property_dict::EdgePropertyDict, name::String)
    local instructions = graph.instructions
    local id = findfirst(it -> it isa PathInstruction && it.output === paths, instructions)
    if id === nothing
        error("Could not find the instruction for the paths variable, is it from this graph?")
    end
    local path_instruction = instructions[id]
    push!(
        graph.instructions,
        EdgePropertyInstruction(
            property_dict,
            path_instruction,
            name
        )
    )
end

"""
    get_symbols_in
    
    Returns all symbols in the given expression [expr].
"""
function get_symbols_in(expr)
    symbols = Set{Symbol}()
    if expr isa Expr
        for a in expr.args
            union!(symbols, get_symbols_in(a))
        end
    elseif expr isa Symbol
        push!(symbols, expr)
    end
    return symbols
end

"""
    @apply_path_constraint

    Defines a new constraint on the given path variable.
    Use variables `src`, `dst`, `node`, `nodes`, `edge`, or `edges` to reference path elements.
"""
macro apply_path_constraint(graph, paths, constraint)
    esc(quote
        # Find the path instructions and append the constraint to its list
        local instructions = $graph.instructions
        local p = $paths
        local id = findfirst(it -> it isa PathInstruction && it.output === p, instructions)
        if id == nothing
            error("Could not find the instruction for the paths variable, is it from this graph?")
        end
        local expr = $(QuoteNode(constraint))
        local compiled = (src, dst, node, nodes, edge, edges) -> begin
            $constraint
        end
        push!(instructions[id].constraints, PathConstraint(get_symbols_in(expr), compiled, convert_to_cypher(expr)))
    end)
end

"""
    @optimal

    Defines the optimal value of the problem and how close to the optimal solution
    needs to be searched.

    [mode] should be Minimize or Maximize depending on if the value should be minimized or maximized.

    [dependent_paths] is whether there are dependencies between path constraints. If paths are independent
    (this value is `false`) then there should be no need to find multiple paths between sources & targets
    as there is no reason to deny paths outside of path constraints.

    [timeout] sets the maximum time the problem can take.

    [stopping_condition] sets the stopping condition of the algorithm. Provided with variables [sources] and [destinations]
    including all possible source and destination nodes, alongside [paths] which is the last best selection. It is also 
    provided [score] which is the value of the optimization function.
"""
macro optimal(graph, paths, mode, dependent_paths, timeout, stopping_condition)
    esc(quote
        # Find the path instructions and append the constraint to its list
        local instructions = $graph.instructions
        local pa = $paths
        local id = findfirst(it -> it isa PathInstruction && it.output === pa, instructions)
        if id == nothing
            error("Could not find the instruction for the paths variable, is it from this graph?")
        end
        local compiled = (sources, destinations, paths, score) -> begin
            $stopping_condition
        end
        instructions[id].optimal = OptimalDefinition($mode, $dependent_paths, compiled, $timeout, time())
    end)
end

"""
    define_problem!

    Defines a problem function [problem_definition] on [paths] to be solved as a part of [graph].
    [problem_definition] should be a function that takes in a JuMP Model object and JuMP variable object.

    Should be defined as a local function so it can access all variables within scope. This has to be wrapped
    in a function as it may be run multiple times on subsets of the full problem.

    The selection variable x[1:path_count] is provided to check for selection of certain paths, which can be 
    queried with x[p.id]. It is given as a parameter, e.g. function(model, paths, x)

    The second argument mirrors the passed paths vector, this should be named the same but may contain
    different values when the constraint solver is ran on a subset of the problem.
"""
function define_problem!(graph::SolvableGraph, paths::Vector{Path}, problem_definition)
    local instructions = graph.instructions
    local id = findfirst(it -> it isa PathInstruction && it.output === paths, instructions)
    if id === nothing
        error("Could not find the instruction for the paths variable, is it from this graph?")
    end
    local path_instruction = instructions[id]
    push!(
        graph.instructions,
        ProblemInstruction(
            path_instruction,
            problem_definition
        )
    )
end

"""
    execute_path_instruction

    Queries the given [backend] to find all paths that match [instruction].
"""
function execute_path_instruction(backend::GraphBackend, settings::GraphSolveSettings, instruction::PathInstruction, property_instructions::Set{Instruction}, problem_instructions::Set{ProblemInstruction})
    # Determine all referenced edge properties
    edge_properties = Set{String}()
    if !isnothing(instruction.weight_property)
        push!(edge_properties, instruction.weight_property)
    end
    for property in property_instructions
        if property isa EdgePropertyInstruction
            push!(edge_properties, property.name)
        end
    end
    
    # Create a connector instance
    connector = backend.connector
    if isnothing(connector) || backend.edge_properties != edge_properties
        connector = create_connector(backend, settings, edge_properties)
        backend.edge_properties = edge_properties
        backend.connector = connector
    end

    # Start by creating the execution context
    context = ExecutionContext(
        settings.profiler, settings, instruction, instruction.include_edges, false,
        Set{Int}(), Set{Int}(), Set{Int}(), Set{Edge}(),
        Vector{String}(), Vector{String}(), Vector{String}(), Vector{String}(),
        IdDict{NodePropertyDict, Vector{NodePropertyInstruction}}(), IdDict{NodePropertyDict, Vector{NodePropertyInstruction}}(), IdDict{NodePropertyDict, Vector{NodePropertyInstruction}}(), IdDict{EdgePropertyDict, Vector{EdgePropertyInstruction}}(),
        Vector{PathConstraint}(), Vector{PathConstraint}(), Vector{PathConstraint}(), Vector{PathConstraint}(), Vector{PathConstraint}(), Vector{PathConstraint}(),
        instruction.source, instruction.target
    )

    # Start by filtering instructions into execution instructions
    prepare_query_properties(context, property_instructions)
    if settings.apply_path_constraints
        prepare_constraints(context)
    end

    # Try to pre-fetch nodes
    if settings.preload_nodes
        perform_node_pre_fetch(context, connector)
    end

    # Run the algorithm based on the selected mode
    if settings.mode == AllPaths
        # Perform the main algorithm to determine all paths
        get_all_paths(context, connector, context.source, context.target)

        # Fetch remaining properties
        fetch_all_properties(context, connector, context.instruction.output)
        
        for problem_instruction in problem_instructions
            # Run the constraint solver
            solve_constraints(context, problem_instruction, context.instruction.output, nothing)
        end
    elseif settings.mode == IncrementalPathSearch
        # Require that there is a valid optimal value
        if isnothing(instruction.optimal)
            error("Cannot run incremental path searching without an optimal goal value")
        end

        for problem_instruction in problem_instructions
            # Runs the incremental path search system
            incremental_path_search(context, connector, problem_instruction)
        end
    end   
end

"""
    execute!

    Instructs the given graph to execute all instructions.
"""
function execute!(graph::SolvableGraph, settings::GraphSolveSettings)
    # Start by filtering incoming instructions to determine execution order and combining
    # them into groups we can merge into combined instructions.
    path_instructions = Set{PathInstruction}()
    property_instructions = Dict{PathInstruction, Set{Instruction}}()
    problem_instructions = Dict{PathInstruction, Set{ProblemInstruction}}()
    @timeit settings.profiler "filter instructions" begin
        for instruction in graph.instructions
            if instruction isa PathInstruction
                # Path instructions are executed separately, order does not matter.
                push!(path_instructions, instruction)
            elseif instruction isa NodePropertyInstruction || instruction isa EdgePropertyInstruction
                # Property instructions are fetched nested with path instructions so
                # backends can merge them into the same query to immediately fetch them
                # for all relevant nodes.
                sublist = get!(property_instructions, instruction.path, Set{Instruction}())
                property_instructions[instruction.path] = sublist
                push!(sublist, instruction)
            elseif instruction isa ProblemInstruction
                # Problem instructions are solved on top of a path instruction to refine its results.
                sublist = get!(problem_instructions, instruction.path, Set{ProblemInstruction}())
                problem_instructions[instruction.path] = sublist
                push!(sublist, instruction)
            end
        end
    end

    # Start executing instructions one-by-one
    tasks = Vector{Task}()
    for instruction in path_instructions
        push!(
            tasks,
            @schedule_task settings begin
                execute_path_instruction(graph.graph, settings, instruction, get!(property_instructions, instruction, Set{Instruction}()), get!(problem_instructions, instruction, Set{ProblemInstruction}()))
            end
        )
    end

    # Wait for all instructions to complete
    for task in tasks
        wait(task)
    end
end

"""
   get_source_nodes
   
   Returns a set of all unique source nodes in the given paths list.
"""
function get_source_nodes(paths)
    return Set(p.src for p in paths)
end

"""
   get_destination_nodes
   
   Returns a set of all unique destination nodes in the given paths list.
"""
function get_destination_nodes(paths)
    return Set(p.dst for p in paths)
end

"""
   get_unique_edges
   
   Returns a set of all unique edges in the given paths list.
"""
function get_unique_edges(paths)
   return Set(Iterators.flatten(p.edges for p in paths))
end

"""
   get_unique_nodes
   
   Returns a set of all unique nodes in the given paths list.
"""
function get_unique_nodes(paths)
   return Set(Iterators.flatten(get_path_nodes(p) for p in paths))
end

"""
    get_path_nodes

    Returns the set of nodes a path goes across.
"""
function get_path_nodes(path)
    return  [path.edges[1][1]; last.(path.edges)]
end

"""
    require_sources_at_least_one_target

    Ensures that all source nodes have at least one target
    which ensures all sources are at least assigned.
"""
function require_sources_at_least_one_target(model, paths, x)
    for node in get_source_nodes(paths)
        filtered_paths = map(it -> it.id, filter(it -> it.src == node, paths))
        @constraint(model, sum(x[pid] for pid in filtered_paths) >= 1)
    end
end

"""
    require_sources_at_most_one_target

    Ensures that all source nodes have at most one target
    which ensures no sources are assigned twice.
"""
function require_sources_at_most_one_target(model, paths, x)
    for node in get_source_nodes(paths)
        filtered_paths = map(it -> it.id, filter(it -> it.src == node, paths))
        @constraint(model, sum(x[pid] for pid in filtered_paths) <= 1)
    end
end

"""
    require_sources_exactly_one_target

    Ensures that all source nodes must be assigned to exactly
    one target.
"""
function require_sources_exactly_one_target(model, paths, x)
    for node in get_source_nodes(paths)
        filtered_paths = map(it -> it.id, filter(it -> it.src == node, paths))
        @constraint(model, sum(x[pid] for pid in filtered_paths) == 1)
    end
end