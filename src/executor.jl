# Implements the logic for executing solvable graphs.
"""
    get_merged_properties

    Returns the merged properties string from the context.
"""
function get_merged_properties(context::ExecutionContext, supports_edge_properties::Bool=true)
    # Weave properties so the first two elements are the first source and first target property (id(s), id(t)) then the rest
    parameters = Vector{String}(undef, length(context.source_properties) + length(context.target_properties))
    parameters[1] = context.source_properties[1]
    parameters[2] = context.target_properties[1]
    idx = 3
    for i in 2:length(context.source_properties)
        parameters[idx] = context.source_properties[i]
        idx += 1
    end
    for i in 2:length(context.target_properties)
        parameters[idx] = context.target_properties[i]
        idx += 1
    end
    if !isempty(context.node_properties)
        push!(parameters, "[n IN nodes(p) | [$(join(context.node_properties, ", "))]]")
    end
    if !isempty(context.edge_properties)
        push!(parameters, supports_edge_properties ? "[e IN relationships(p) | [$(join(context.edge_properties, ", "))]]" : "[e IN relationships(p) | [id(startNode(e)), id(endNode(e))]]")
    end
     return join(parameters, ", ")
end

"""
    process_properties

    Processes node properties from a given query result.
    Ignores nodes that already had properties parsed previously as
    all properties are fetched at once.
"""
function process_properties(
    context::ExecutionContext,
    source_properties,
    target_properties,
    sourceNode,
    targetNode,
    offset::Int,
    row_values
)
    idx = offset
    if !isnothing(source_properties) && !isempty(source_properties)
        @timeit context.profiler "parse source properties" begin
            for (target, instructions) in source_properties
                if !haskey(target, sourceNode)
                    subdict = Dict{String, Any}()
                    target[sourceNode] = subdict
                else
                    subdict = target[sourceNode]
                end
                
                for instruction in instructions
                    value = row_values[idx]
                    idx += 1
                    subdict[instruction.name] = value
                end
            end
            
            # Avoid doubling up on fetching node properties!
            push!(context.fetched_sources, sourceNode)
        end
    end
    if !isnothing(target_properties) && !isempty(target_properties)
        @timeit context.profiler "parse target properties" begin
            for (target, instructions) in target_properties
                if !haskey(target, targetNode)
                    subdict = Dict{String, Any}()
                    target[targetNode] = subdict
                else
                    subdict = target[targetNode]
                end

                for instruction in instructions
                    value = row_values[idx]
                    idx += 1
                    subdict[instruction.name] = value
                end
            end

            # Avoid doubling up on fetching node properties!
            push!(context.fetched_targets, targetNode)
        end
    end
end

"""
    process_output_row

    Processes one output row from a query with all properties baked in.
"""
function process_output_row(context::ExecutionContext, target::Vector{Path}, row_values, supports_edge_properties::Bool, collection::Union{Set{Path}, Nothing})
    # Extract the node ids
    sourceNode = row_values[1]
    targetNode = row_values[2]
    edges = nothing

    # Process node properties if applicable
    process_properties(
        context,
        context.source_properties_instructions,
        context.target_properties_instructions,
        sourceNode,
        targetNode,
        3,
        row_values
    )

    # Filter based on non-edge constraints after we've extracted properties
    for constraint in context.source_constraints
        if !evaluate_constraint(constraint, sourceNode, nothing, nothing, nothing, nothing, nothing)
            return false
        end
    end
    for constraint in context.target_constraints
        if !evaluate_constraint(constraint, nothing, targetNode, nothing, nothing, nothing, nothing)
            return false
        end
    end
    for constraint in context.source_target_constraints
        if !evaluate_constraint(constraint, sourceNode, targetNode, nothing, nothing, nothing, nothing)
            return false
        end
    end

    valid = true
    @timeit context.profiler "parse query nodes" begin
        # Parse the node properties if we included them
        if context.include_nodes
            path_nodes = row_values[3 + length(context.source_properties_instructions) + length(context.target_properties_instructions)]
            for node_values in path_nodes
                node = node_values[1]
                idx = 2
                if !isnothing(context.node_properties_instructions) && !isempty(context.node_properties_instructions)
                    @timeit context.profiler "parse node properties" begin
                        for (target, instructions) in context.node_properties_instructions
                            if !haskey(target, node)
                                subdict = Dict{String, Any}()
                                target[node] = subdict
                            else
                                subdict = target[node]
                            end
                            
                            for instruction in instructions
                                value = node_values[idx]
                                idx += 1
                                subdict[instruction.name] = value
                            end
                        end
                        
                        # Avoid doubling up on fetching node properties!
                        push!(context.fetched_nodes, node)
                    end
                end

                # Reject path based on edge constraints after resolving edge variables
                for constraint in context.node_constraints
                    if !evaluate_constraint(constraint, sourceNode, targetNode, node, nothing, nothing, nothing)
                        if isnothing(collection)
                            return false
                        else
                            valid = false
                        end
                    end
                end
            end
        end
    end

    @timeit context.profiler "parse query edges" begin
        # Parse the edge properties if we included them
        if context.include_edges
            path_edges = row_values[3 + length(context.source_properties_instructions) + length(context.target_properties_instructions) + (context.include_nodes ? 1 : 0)]
            edges = Vector{Edge}(undef, length(path_edges))
            edge_nr = 1
            for edge_values in path_edges
                # The node id is the first entry in the list
                edge = (edge_values[1], edge_values[2])
                
                if supports_edge_properties
                    # Read out properties on this edge if we didn't
                    # already previously fetch this edge
                    if !isempty(context.edge_properties_instructions)
                        @timeit context.profiler "parse edge properties" begin
                            idx = 3
                            for (target, instructions) in context.edge_properties_instructions
                                if !haskey(target, edge)
                                    subdict = Dict{String, Any}()
                                    target[edge] = subdict
                                else
                                    subdict = target[edge]
                                end

                                for instruction in instructions
                                    value = edge_values[idx]
                                    idx += 1
                                    subdict[instruction.name] = value
                                end
                            end
                            
                            # Track which edges have been fetched already so we don't double up!
                            push!(context.fetched_edges, edge)
                        end
                    end

                    # Reject path based on edge constraints after resolving edge variables
                    for constraint in context.edge_constraints
                        if !evaluate_constraint(constraint, sourceNode, targetNode, nothing, nothing, edge, nothing)
                            if isnothing(collection)
                                return false
                            else
                                valid = false
                            end
                        end
                    end
                end
                
                # Add the edge to the final path
                edges[edge_nr] = edge
                edge_nr += 1
            end
        end
    end

    # Deny path based on constraints on the entire path
    new_path = Path(0, sourceNode, targetNode, edges)
    if !isempty(context.path_constraints)
        path_nodes = get_path_nodes(new_path)
        for constraint in context.path_constraints
            if !evaluate_constraint(constraint, sourceNode, targetNode, nothing, path_nodes, nothing, edges)
                if isnothing(collection)
                    return false
                else
                    valid = false
                end
            end
        end
    end
    
    # Insert the path now that we have read its data (avoiding duplicates)
    if !isnothing(collection)
        push!(collection, new_path)
        if !valid
            return false
        end
    end
    if new_path ∉ target
        push!(target, new_path)
        return true
    end
    return false
end

""" 
    prepare_query_properties

    Prepares query properties into subsets with the right contents.
"""
function prepare_query_properties(context::ExecutionContext, property_instructions::Set{Instruction})
    @timeit context.profiler "property preparation" begin
        # Prepare properties which fetch base ids
        push!(context.source_properties, "id(s)")
        push!(context.target_properties, "id(t)")

        # Go through all properties and append them to the appropriate lists
        for instruction in property_instructions
            if instruction isa NodePropertyInstruction
                # If we bake fetching into the path query we add properties
                if instruction.component == Source
                    push!(context.source_properties, "s.$(instruction.name)")
                    sublist = get!(context.source_properties_instructions, instruction.target, Vector{NodePropertyInstruction}())
                    push!(sublist, instruction)
                elseif instruction.component == Destination
                    push!(context.target_properties, "t.$(instruction.name)")
                    sublist = get!(context.target_properties_instructions, instruction.target, Vector{NodePropertyInstruction}())
                    push!(sublist, instruction)
                elseif instruction.component == Edges
                    # If we want node properties we have to add node parsing!
                    context.include_nodes = true

                    push!(context.node_properties, "n.$(instruction.name)")
                    sublist = get!(context.node_properties_instructions, instruction.target, Vector{NodePropertyInstruction}())
                    push!(sublist, instruction)
                end
            elseif instruction isa EdgePropertyInstruction
                # If we want edge properties we want to extract the path if possible!
                context.include_edges = true

                # If we bake fetching into the path query we add edge properties
                push!(context.edge_properties, "e.$(instruction.name)")
                sublist = get!(context.edge_properties_instructions, instruction.target, Vector{EdgePropertyInstruction}())
                push!(sublist, instruction)
            end
        end

        # Determine if we need to include node information
        if context.include_nodes
            pushfirst!(context.node_properties, "id(n)")
        end

        # Determine if we need to include edge information
        if context.include_edges
            pushfirst!(context.edge_properties, "id(endNode(e))")
            pushfirst!(context.edge_properties, "id(startNode(e))")
        else
            empty!(context.edge_properties)
        end
    end
end

"""
    prepare_constraints

    Prepares constraints and sorts them into correct subets.
"""
function prepare_constraints(context::ExecutionContext)
    @timeit context.profiler "constraint filtering" begin
        # Filter the lists using any source and destination only constraints
        for constraint in context.instruction.constraints
            has_src = :src in constraint.symbols
            has_dst = :dst in constraint.symbols
            has_edge = :edge in constraint.symbols
            has_edges = :edges in constraint.symbols
            has_node = :node in constraint.symbols
            has_nodes = :nodes in constraint.symbols
            
            # If none of the correct values are used, ignore this constraint!
            if !has_src && !has_dst && !has_edge && !has_edges && !has_node && !has_nodes
                continue
            end
            
            # Sort constraints into the right buckets
            if has_edges || has_nodes
                if has_edge || has_node
                    error("Cannot have both constraints on individual components and the whole path")
                end
                push!(context.path_constraints, constraint)
            elseif has_edge
                if has_node
                    error("Cannot have both constraints on edge and node components")
                end
                push!(context.edge_constraints, constraint)
            elseif has_node
                push!(context.node_constraints, constraint)
            elseif has_src || has_dst
                push!(context.source_target_constraints, constraint)
            elseif has_src
                push!(context.source_constraints, constraint)
            else
                push!(context.target_constraints, constraint)
            end
        end
    end
end

"""
    fetch_all_node_properties

    Fetches all properties for the given nodes if unfetched.
"""
function fetch_all_node_properties(context::ExecutionContext, connector::Connector, sources::Union{Vector{Int}, Nothing}, targets::Union{Vector{Int}, Nothing}, nodes::Union{Vector{Int}, Nothing})
    @timeit context.profiler "fetch all node properties" begin
        # If requested, run separate simultaneous queries to determine properties without
        # duplicate data as we fetch a lot of paths
        tasks = Vector{Task}()
        if length(sources) > 0 && length(context.source_properties_instructions) > 0
            push!(
                tasks,
                @async begin
                    new_nodes = filter(it -> it ∉ context.fetched_sources, sources)
                    union!(context.fetched_sources, new_nodes)
                    if length(new_nodes) > 0
                        fetch_node_properties(context.profiler, connector, new_nodes, context.source_properties_instructions)
                    end
                end
            )
        end
        if length(targets) > 0 && length(context.target_properties_instructions) > 0
            push!(
                tasks,
                @async begin
                    new_nodes = filter(it -> it ∉ context.fetched_targets, targets)
                    union!(context.fetched_targets, new_nodes)
                    if length(new_nodes) > 0
                        fetch_node_properties(context.profiler, connector, new_nodes, context.target_properties_instructions)
                    end
                end
            )
        end
        if length(nodes) > 0 && length(context.node_properties_instructions) > 0
            push!(
                tasks,
                @async begin
                    new_nodes = filter(it -> it ∉ context.fetched_nodes, nodes)
                    union!(context.fetched_nodes, new_nodes)
                    if length(new_nodes) > 0
                        fetch_node_properties(context.profiler, connector, new_nodes, context.node_properties_instructions)
                    end
                end
            )
        end

        # Early exit if no tasks were scheduled
        if isempty(tasks)
            return
        end
        
        # Wait for all queries to complete
        for task in tasks
            wait(task)
        end
    end
end

"""
    fetch_all_edge_properties

    Fetches all properties for the given edges if unfetched.
"""
function fetch_all_node_properties(context::ExecutionContext, connector::Connector, edges::Vector{Edge})
    @timeit context.profiler "fetch all edge properties" begin
        if length(edges) > 0 && length(context.edge_properties_instructions) > 0
            new_edges = filter(it -> it ∉ context.fetched_edges, edges)
            union!(context.fetched_edges, new_edges)
            if length(new_edges) > 0
                fetch_edge_properties(context.profiler, connector, new_edges, context.edge_properties_instructions)
            end
        end
    end
end

"""
    fetch_all_properties

    Fetches all properties for nodes and edges in [context], only
    runs once per node or edge and can be safely re-called to fetch
    for all newly added nodes/edges.
"""
function fetch_all_properties(context::ExecutionContext, connector::Connector, paths)
    @timeit context.profiler "fetch all properties" begin
        # If requested, run separate simultaneous queries to determine properties without
        # duplicate data as we fetch a lot of paths
        tasks = Vector{Task}()
        if length(context.source_properties_instructions) > 0
            push!(
                tasks,
                @async begin
                    all_nodes = get_source_nodes(paths)
                    new_nodes = filter(it -> it ∉ context.fetched_sources, all_nodes)
                    union!(context.fetched_sources, new_nodes)
                    if length(new_nodes) > 0
                        fetch_node_properties(context.profiler, connector, new_nodes, context.source_properties_instructions)
                    end
                end
            )
        end
        if length(context.target_properties_instructions) > 0
            push!(
                tasks,
                @async begin
                    all_nodes = get_destination_nodes(paths)
                    new_nodes = filter(it -> it ∉ context.fetched_targets, all_nodes)
                    union!(context.fetched_targets, new_nodes)
                    if length(new_nodes) > 0
                        fetch_node_properties(context.profiler, connector, new_nodes, context.target_properties_instructions)
                    end
                end
            )
        end
        if length(context.node_properties_instructions) > 0
            push!(
                tasks,
                @async begin
                    all_nodes = get_unique_nodes(paths)
                    new_nodes = filter(it -> it ∉ context.fetched_nodes, all_nodes)
                    union!(context.fetched_nodes, new_nodes)
                    if length(new_nodes) > 0
                        fetch_node_properties(context.profiler, connector, new_nodes, context.node_properties_instructions)
                    end
                end
            )
        end
        if length(context.edge_properties_instructions) > 0
            push!(
                tasks,
                @async begin
                    all_edges = get_unique_edges(paths)
                    new_edges = filter(it -> it ∉ context.fetched_edges, all_edges)
                    union!(context.fetched_edges, new_edges)
                    if length(new_edges) > 0
                        fetch_edge_properties(context.profiler, connector, new_edges, context.edge_properties_instructions)
                    end
                end
            )
        end

        # Early exit if no tasks were scheduled
        if isempty(tasks)
            return
        end
        
        # Wait for all queries to complete
        for task in tasks
            wait(task)
        end
    end
end

""" 
    solve_constraints

    Solves the [context] for constraints with [problem_instruction].
"""
function solve_constraints(context::ExecutionContext, problem_instruction::ProblemInstruction, paths::Vector{Path}, init_values)
    @timeit context.profiler "solve constraints" begin
        # If there are zero paths, we have nothing to solve!
        if isempty(paths)
            return 0.0, nothing
        end

        # Relabel remaining paths so their ids are referencable
        @timeit context.profiler "relabel paths" begin
            path_count = length(paths)
            for i in eachindex(paths)
                p = paths[i]
                paths[i] = Path(i, p.src, p.dst, p.edges)
            end
        end

        # Define the JuMP model
        @timeit context.profiler "define model" begin
            # Support either HiGHS or SCIP for the solver
            if context.settings.solver_type == HiGHSSolver
                model = Model(HiGHS.Optimizer)

                # Set to multi-threaded mode (only applies to pre-solving as main solving doesn't parallelize well)
                set_optimizer_attribute(model, "threads", Sys.CPU_THREADS)
            else
                model = Model(SCIP.Optimizer)
                set_attribute(model, "display/verblevel", 0)
                set_attribute(model, "limits/gap", 0.05)
                set_optimizer_attribute(model, "parallel/maxnthreads", Sys.CPU_THREADS)
            end

            # Disable variable names for speed-up
            set_string_names_on_creation(model, false)

            # If we are assigning sources directly we limit each source to at most one path!
            if context.instruction.goal == AssignSourcesToDestinations
                # Define a variable for selecting from the paths
                @variable(model, x[p=1:path_count], Bin)

                for node in get_source_nodes(paths)
                    filtered_paths = filter(it -> it.src == node, paths)
                    @constraint(model, sum(x[p.id] for p in filtered_paths) <= 1)
                end
            elseif context.instruction.goal == MaximizeSelection
                # If we want to maximize the selection we allow selecting
                # entries multiple times.
                @variable(model, x[p=1:path_count] >= 0, Int)
            end

            # Apply the user-defined constraints the model
            problem_instruction.problem_definition(model, paths, x)
        end

        # Before running, initialize the previous best state so we can "resume" solving which
        # saves a lot of time in the incremental approach.
        if context.settings.re_use_constraint_solutions && !isnothing(init_values)
            @timeit context.profiler "set up initial values" begin
                i = 1
                for val in init_values
                    set_start_value(x[i], val)
                    i += 1
                end
            end
        end

        # Run the model through JuMP
        @timeit context.profiler "run constraint solver" optimize!(model)

        # Collect the values within the model to start future runs with these as initial values
        out_values = collect([value(x[p.id]) for p in paths])

        # Filter paths vector based on inclusion in the variable
        @timeit context.profiler "filter selected paths" begin
            if context.instruction.goal == MaximizeSelection
                # Create a list of all selected paths multiplied by how many
                # copies we want of each!
                paths_copy = Vector{Path}(paths)
                empty!(paths)
                for p in paths_copy
                    count = round(Int, value(x[p.id]))
                    append!(paths, fill(p, count))
                end
            else
                filter!(p -> value(x[p.id]) >= 0.5, paths)
            end
        end

        # Store the score of the optimization
        return objective_value(model), out_values
    end
end