# Defines macros available for usage alongside fucntions to define the graph instructions.
"""
    find_paths!

    Adds a new instruction to [graph] to determine all paths from nodes called [source] to
    nodes called [target] and store them into the returned vector. Edges are included if requested,
    otherwise we only find pairs of nodes that have some connection.
"""
function find_paths!(graph::SolvableGraph, goal::PathQueryGoal, source::NodeSelector, target::NodeSelector, include_edges::Bool=false)
    paths = Vector{Path}()
    push!(
        graph.instructions,
        PathInstruction(
            paths,
            goal,
            source,
            target,
            include_edges,
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

    [p] should be a value between 0 and 1 that defines how close the found solution
    should be the the optimal value. 0.9 means it can be 10% lower, 0.99 means only 1% is allowed.

    [mode] should be Minimize or Maximize depending on if the value should be minimized or maximized.

    [timeout] sets the maximum time the problem can take.

    [provider] should be a function returning some number based on variables `sources`
    and `destinations`. This should equal the optimal value of the @objective function.
"""
macro optimal(graph, paths, p, mode, timeout, provider)
    esc(quote
        # Find the path instructions and append the constraint to its list
        local instructions = $graph.instructions
        local pa = $paths
        local id = findfirst(it -> it isa PathInstruction && it.output === pa, instructions)
        if id == nothing
            error("Could not find the instruction for the paths variable, is it from this graph?")
        end
        local compiled = (sources, destinations) -> begin
            $provider
        end
        instructions[id].optimal = OptimalDefinition($p, $mode, compiled, $timeout, time())
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
    # Create a connector instance
    connector = backend.connector
    if isnothing(connector)
        connector = create_connector(backend, settings)
        backend.connector = connector
    end

    # Start by creating the execution context
    context = ExecutionContext(
        settings.profiler, settings, instruction, instruction.include_edges, false,
        Set{Int}(), Set{Edge}(),
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

    # Use settings to see if we can use async scheduling
    if !settings.use_async_scheduling
        for instruction in path_instructions
            execute_path_instruction(graph.graph, settings, instruction, get!(property_instructions, instruction, Set{Instruction}()), get!(problem_instructions, instruction, Set{ProblemInstruction}()))
        end
    else
        # Start executing instructions one-by-one
        tasks = Vector{Task}()
        for instruction in path_instructions
            push!(
                tasks,
                @async begin
                    execute_path_instruction(graph.graph, settings, instruction, get!(property_instructions, instruction, Set{Instruction}()), get!(problem_instructions, instruction, Set{ProblemInstruction}()))
                end
            )
        end

        # Wait for all instructions to complete
        for task in tasks
            wait(task)
        end
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
    get_path_nodes

    Returns the set of nodes a path goes across.
"""
function get_path_nodes(path)
    return  [path.edges[1][1]; last.(path.edges)]
end
