# Implements instructions against Julia.
function create_connector(backend::JuliaGraphBackend, settings::GraphSolveSettings)
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
                if !haskey(target, node)
                    target[node] = connector.node_properties[node]
                end
            end
        end
    end
end

function fetch_edge_properties(profiler::TimerOutput, connector::JuliaConnectorWrapper, edges::Set{Edge}, path_instructions)
    @timeit profiler "copy edge properties" begin
        for edge in edges
            for (target, instructions) in path_instructions
                if !haskey(target, edge)
                    target[edge] = connector.edge_properties[edge]
                end
            end
        end
    end
end

function perform_node_pre_fetch(context::ExecutionContext, connector::JuliaConnectorWrapper)
    @timeit context.profiler "pre-filter sources" begin
        source_list = filter_nodes(connector, context.source)
        for constraint in context.source_constraints
            filter!(source -> evaluate_constraint(constraint, source, nothing, nothing), source_list)
        end
        empty!(context.source_constraints)
        context.source = IdNodeSelector(source_list)

        if context.settings.embed_properties
            fetch_node_properties(context.profiler, connector, source_list, context.source_properties_instructions)
        end
    end
    
    @timeit context.profiler "pre-filter targets" begin
        target_list = filter_nodes(connector, context.target)
        for constraint in context.target_constraints
            filter!(target -> evaluate_constraint(constraint, nothing, target, nothing), target_list)
        end
        empty!(context.target_constraints)
        context.target = IdNodeSelector(target_list)

        if context.settings.embed_properties
            fetch_node_properties(context.profiler, connector, target_list, context.target_properties_instructions)
        end
    end
end

function process_paths(context::ExecutionContext, connector::JuliaConnectorWrapper, sourceNode::Int, targetNode::Int, paths, output::Vector{Path}, is_shortest_path_search::Bool=false)
    # Ignore if there are no paths!
    if isempty(paths)
        return 0
    end

    # Fetch properties if requested
    if !isempty(context.source_properties_instructions)
        fetch_node_properties(context.profiler, connector, Set{Int}([sourceNode]), context.source_properties_instructions)
    end
    if !isempty(context.target_properties_instructions)
        fetch_node_properties(context.profiler, connector, Set{Int}([targetNode]), context.target_properties_instructions)
    end

    # Filter based on non-edge constraints after we've extracted properties
    if !context.settings.push_down_constraints
        for constraint in context.source_constraints
            if !evaluate_constraint(constraint, sourceNode, nothing, nothing)
                return 0
            end
        end
        for constraint in context.target_constraints
            if !evaluate_constraint(constraint, nothing, targetNode, nothing)
                return 0
            end
        end
        for constraint in context.non_edge_constraints
            if !evaluate_constraint(constraint, sourceNode, targetNode, nothing)
                return 0
            end
        end
    end

    count = 0
    @timeit context.profiler "process paths" begin
        for path in paths
            # Ignore paths of invalid size!
            if length(path) < 2
                continue
            end

            # Assemble the path from its edges
            edges = Vector{Edge}(undef, length(path) - 1)
            edge_nr = 1
            last_edge = nothing
            for vertex in path
                if isnothing(last_edge)
                    last_edge = vertex
                else
                    edge = (last_edge - 1, vertex - 1)
                    last_edge = vertex

                    # Fetch edge properties if applicable
                    if !isempty(context.edge_properties_instructions)
                        fetch_edge_properties(context.profiler, connector, Set{Edge}([edge]), context.edge_properties_instructions)
                    end

                    # Reject path based on edge constraints after resolving edge variables
                    if !context.settings.push_down_constraints && !is_shortest_path_search
                        for constraint in context.edge_constraints
                            if !evaluate_constraint(constraint, sourceNode, targetNode, edge)
                                return count
                            end
                        end
                    end

                    # Add the edge to the path
                    edges[edge_nr] = edge
                    edge_nr += 1
                end
            end
            
            # Insert the path now that we have read its data (avoiding duplicates)
            new_path = Path(0, sourceNode, targetNode, edges)
            if new_path ∉ output
                push!(output, new_path)
                count += 1
            end
        end
    end
    return count
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
                            process_paths(context, connector, s, t, collect(all_simple_paths(connector.graph, s + 1, t + 1)), output)
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
                    process_paths(context, connector, s, t, collect(all_simple_paths(connector.graph, s + 1, t + 1)), output)
                end
            end
        end
    end
end

function get_shortest_paths(context::ExecutionContext, connector::JuliaConnectorWrapper, source::NodeSelector, target::NodeSelector, output::Vector{Path})
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
                            # Mark this as the shortest path search, so don't deny any paths. Otherwise we don't have any eligible
                            # paths to branch off of when searching.
                            process_paths(context, connector, s, t, [collect(enumerate_paths(sp, t + 1))], output, true)
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
                    process_paths(context, connector, s, t, [collect(enumerate_paths(sp, t + 1))], output, true)
                end
            end
        end
    end
end

function get_k_shortest_paths(context::ExecutionContext, connector::JuliaConnectorWrapper, source::Int, target::Int, k::Int, output::Vector{Path})
    @timeit context.profiler "yen's k shortest paths" begin
        paths = yen_k_shortest_paths(connector.graph, source + 1, target + 1, weights(connector.graph), k).paths
        return process_paths(context, connector, source, target, paths, output)
    end
end