# Implements instructions against Julia.
function create_connector(backend::JuliaGraphBackend, settings::GraphSolveSettings, instruction::PathInstruction)
    @timeit settings.profiler "read graph from csv" graph, nodes, node_properties, edge_properties = load_julia_graph(backend)
    return JuliaConnectorWrapper(graph, nodes, node_properties, edge_properties)
end

function filter_nodes(connector::JuliaConnectorWrapper, selector::NodeSelector)
    if selector isa AllNodeSelector
        return Set{Int}(collect(keys(connector.nodes)))
    elseif selector isa IdNodeSelector
        return selector.ids
    elseif selector isa LabelNodeSelector
        result = Set{Int}()
        for (node, label) in connector.nodes
            if label == selector.label
                push!(result, node)
            end
        end
        return result
    else
        error("Invalid selector type `$(selector)`")
    end
end

function fetch_node_properties(profiler::TimerOutput, connector::JuliaConnectorWrapper, nodes::Set{Int}, path_instructions)
    @timeit profiler "copy node properties" begin
        for node in nodes
            for (target, instructions) in path_instructions
                target[node] = connector.node_properties[node]
            end
        end
    end
end

function fetch_edge_properties(profiler::TimerOutput, connector::JuliaConnectorWrapper, edges::Set{Edge}, path_instructions)
    @timeit profiler "copy edge properties" begin
        for edge in edges
            for (target, instructions) in path_instructions
                target[edge] = connector.edge_properties[edge]
            end
        end
    end
end

function perform_node_pre_fetch(context::ExecutionContext, connector::JuliaConnectorWrapper)
    @timeit context.profiler "pre-filter sources" begin
        source_list = filter_nodes(connector, context.source)
        for constraint in context.source_constraints
            filter!(source -> evaluate_constraint(constraint, source, nothing, nothing, nothing, nothing, nothing), source_list)
        end
        empty!(context.source_constraints)
        context.source = IdNodeSelector(source_list)
        fetch_all_node_properties(context, connector, source_list, nothing, nothing)
    end
    
    @timeit context.profiler "pre-filter targets" begin
        target_list = filter_nodes(connector, context.target)
        for constraint in context.target_constraints
            filter!(target -> evaluate_constraint(constraint, nothing, target, nothing, nothing, nothing, nothing), target_list)
        end
        empty!(context.target_constraints)
        context.target = IdNodeSelector(target_list)
        fetch_all_node_properties(context, connector, nothing, target_list, nothing)
    end
end

function process_path(context::ExecutionContext, sourceNode::Int, targetNode::Int, output::Vector{Path}, collection::Union{Set{Path}, Nothing}, path)
    # Ignore paths of invalid size!
    if length(path) < 2
        return false
    end

    # Assemble the path from its edges
    edges = Vector{Edge}(undef, length(path) - 1)
    edge_nr = 1
    last_edge = nothing
    valid = true
    for vertex in path
        # Reject path based on node constraints after resolving node variables
        if !isempty(context.node_constraints)
            fetch_all_node_properties(context, connector, nothing, nothing, [vertex])
            for constraint in context.node_constraints
                if !evaluate_constraint(constraint, sourceNode, targetNode, vertex, nothing, nothing, nothing)
                    if isnothing(collection)
                        return false
                    else
                        valid = false
                    end
                end
            end
        end

        if isnothing(last_edge)
            last_edge = vertex
        else
            edge = (last_edge - 1, vertex - 1)
            last_edge = vertex

            # Reject path based on edge constraints after resolving edge variables
            if !isempty(context.edge_constraints)
                fetch_all_edge_properties(context, connector, [edge])
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

            # Add the edge to the path
            edges[edge_nr] = edge
            edge_nr += 1
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
    if new_path ∉ output
        push!(output, new_path)
        return true
    end
    return false
end

function process_paths(context::ExecutionContext, connector::JuliaConnectorWrapper, sourceNode::Int, targetNode::Int, output::Vector{Path}, collection::Union{Set{Path}, Nothing}, func)
    # Fetch source/target if requested
    fetch_all_node_properties(context, connector, [sourceNode], [targetNode], nothing)

    # Filter based on non-edge constraints after we've extracted properties
    for constraint in context.source_constraints
        if !evaluate_constraint(constraint, sourceNode, nothing, nothing, nothing, nothing, nothing)
            return 0, 0
        end
    end
    for constraint in context.target_constraints
        if !evaluate_constraint(constraint, nothing, targetNode, nothing, nothing, nothing, nothing)
            return 0, 0
        end
    end
    for constraint in context.source_target_constraints
        if !evaluate_constraint(constraint, sourceNode, targetNode, nothing, nothing, nothing, nothing)
            return 0, 0
        end
    end

    # Fetch the paths only after denying combinations of sources/targets through constraints
    paths = func()

    # Ignore if there are no paths!
    if isempty(paths)
        return 0, 0
    end

    count = 0
    @timeit context.profiler "process paths" begin    
        for path in paths
            if process_path(context, sourceNode, targetNode, output, collection, path)
                count += 1
            end
        end
    end
    return count, length(paths)
end

function get_all_paths(context::ExecutionContext, connector::JuliaConnectorWrapper, source::NodeSelector, target::NodeSelector)
    output = context.instruction.output
    sources = filter_nodes(connector, source)
    targets = filter_nodes(connector, target)
    
    if context.settings.use_async_scheduling
        tasks = Vector{Task}()
        for s in sources
            for t in targets
                push!(
                    tasks,
                    @async begin
                        @timeit context.profiler "all simple paths" begin
                            process_paths(context, connector, s, t, output, nothing, () -> collect(all_simple_paths(connector.graph, s + 1, t + 1)))
                        end
                    end
                )
            end
        end

        for task in tasks
            wait(task)
        end
    else
        for s in sources
            for t in targets
                @timeit context.profiler "all simple paths" begin
                    process_paths(context, connector, s, t, output, nothing, () -> collect(all_simple_paths(connector.graph, s + 1, t + 1)))
                end
            end
        end
    end
end

function get_shortest_paths(context::ExecutionContext, connector::JuliaConnectorWrapper, source::NodeSelector, target::NodeSelector, output::Vector{Path}, collection::Set{Path}, weight_property::Union{String, Nothing})
    sources = filter_nodes(connector, source)
    targets = filter_nodes(connector, target)

    if context.settings.use_async_scheduling
        tasks = Vector{Task}()

        for s in sources
            push!(
                tasks,
                @async begin
                    @timeit context.profiler "dijkstra's shortest paths" begin
                        sp = dijkstra_shortest_paths(connector.graph, s + 1)
                        for t in targets
                            process_paths(context, connector, s, t, output, collection, () -> [collect(enumerate_paths(sp, t + 1))])
                        end
                    end
                end
            )
        end

        for task in tasks
            wait(task)
        end
    else
        for s in sources
            @timeit context.profiler "dijkstra's shortest paths" begin
                sp = dijkstra_shortest_paths(connector.graph, s + 1)
                for t in targets
                    process_paths(context, connector, s, t, output, collection, () -> [collect(enumerate_paths(sp, t + 1))])
                end
            end
        end
    end
end

function get_k_shortest_paths(context::ExecutionContext, connector::JuliaConnectorWrapper, source::Int, target::Int, k::Int, output::Vector{Path}, weight_property::Union{String, Nothing})
    @timeit context.profiler "yen's k shortest paths" begin
        return process_paths(context, connector, source, target, output, nothing, () -> yen_k_shortest_paths(connector.graph, source + 1, target + 1, weights(connector.graph), k).paths)
    end
end