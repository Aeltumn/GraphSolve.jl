# Implements instructions against Neo4j.
function create_connector(backend::Neo4jBackend, settings::GraphSolveSettings, edge_properties::Set{String})
    if backend.bolt
        connector = create_bolt_connector(backend)
    else
        connector = HttpNeo4jConnector("$(backend.url)/db/$(backend.database)/tx/commit", determine_connection_headers(backend), backend.database, false)
    end
    
    # Project the database into GDS if we want to use shortest path searching
    if settings.mode == IncrementalPathSearch
        query_cypher(settings.profiler, connector, "CALL gds.graph.drop('$(connector.database)', false)", nothing)
        if length(edge_properties) > 0
            query_cypher(settings.profiler, connector, "CALL gds.graph.project('$(connector.database)', '*', {ALL: { type: '*', properties: ['$(join(edge_properties, "', '"))']}})", nothing) 
        else
            query_cypher(settings.profiler, connector, "CALL gds.graph.project('$(connector.database)', '*', '*')", nothing) 
        end
    end
    return connector
end

function fetch_node_properties(profiler::TimerOutput, connector::CypherConnector, nodes::Set{Int}, path_instructions)
    # Run a singular query to fetch all relevant properties
    properties = Vector{String}()
    push!(properties, "id(n)")
    for (target, instructions) in path_instructions
        for instruction in instructions
            push!(properties, "n.$(instruction.name)")
        end
    end

    function process_node_row(row_values)
        node = row_values[1]
        idx = 2
        for (target, instructions) in path_instructions
            if !haskey(target, node)
                subdict = Dict{String, Any}()
                target[node] = subdict
            else
                subdict = target[node]
            end
            
            for instruction in instructions
                value = row_values[idx]
                idx += 1
                subdict[instruction.name] = value
            end
        end
        return false
    end
    query_cypher(profiler, connector, "MATCH (n) WHERE id(n) IN [$(join(nodes, ","))] RETURN $(join(properties, ", "))", process_node_row)
end

function fetch_edge_properties(profiler::TimerOutput, connector::CypherConnector, edges::Set{Edge}, path_instructions)
    # Run a singular query to fetch all relevant properties
    properties = Vector{String}()
    for (target, instructions) in path_instructions
        for instruction in instructions
            push!(properties, "e.$(instruction.name)")
        end
    end
    if isempty(properties)
        return
    end
    function process_edge_row(edge_values)
        edge = (edge_values[1], edge_values[2])
        idx = 3
        for (target, instructions) in path_instructions
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
        return false
    end
    query_cypher(profiler, connector, """
        WITH [
            $(join(["{src: $(it[1]), dst: $(it[2])}" for it in edges], ", "))
        ] as pairs
        UNWIND pairs as p
        MATCH (s)-[e]->(t)
        WHERE id(s) = p.src AND id(t) = p.dst
        RETURN id(s), id(t), $(join(properties, ", "))
    """, process_edge_row)
end

function perform_node_pre_fetch(context::ExecutionContext, connector::CypherConnector)
    @timeit context.profiler "node pre-fetching" begin
        # Run an estimation query to determine if fetching all paths if feasible
        source_conditions = Vector{String}()
        source_query = as_query(context.source, "s")
        if !isnothing(source_query.conditions)
            append!(source_conditions, source_query.conditions)
        end
        if context.settings.push_down_constraints
            i = 0
            for constraint in context.source_constraints
                i += 1
                if isnothing(constraint.cypher)
                    continue
                end
                push!(source_conditions, constraint.cypher)
                deleteat!(context.source_constraints, i)
                i -= 1
            end
        end
        source_list = Vector{Int}()
        function process_source_row(row_values)
            sourceNode = row_values[1]
            push!(source_list, sourceNode)
            process_properties(context, context.source_properties_instructions, nothing, sourceNode, nothing, 2, row_values)
            return false
        end
        query_cypher(context.profiler, connector, """
            MATCH $(source_query.select)
            $(merge_conditions(source_conditions))
            RETURN $(join(context.source_properties, ", "))
        """, process_source_row)
        for constraint in context.source_constraints
            filter!(source -> evaluate_constraint(constraint, source, nothing, nothing, nothing, nothing, nothing), source_list)
        end
        empty!(context.source_constraints)
        empty!(context.source_properties)
        push!(context.source_properties, "id(s)")
        empty!(context.source_properties_instructions)
        context.source = IdNodeSelector(source_list)

        target_conditions = Vector{String}()
        target_query = as_query(context.target, "t")
        if !isnothing(target_query.conditions)
            append!(target_conditions, target_query.conditions)
        end
        if context.settings.push_down_constraints
            i = 0
            for constraint in context.target_constraints
                i += 1
                if isnothing(constraint.cypher)
                    continue
                end
                push!(target_conditions, constraint.cypher)
                deleteat!(context.target_constraints, i)
                i -= 1
            end
        end
        target_list = Vector{Int}()
        function process_target_row(row_values)
            targetNode = row_values[1]
            push!(target_list, targetNode)
            process_properties(context, nothing, context.target_properties_instructions, nothing, targetNode, 2, row_values)
            return false
        end
        query_cypher(context.profiler, connector, """
            MATCH $(target_query.select)
            $(merge_conditions(target_conditions))
            RETURN $(join(context.target_properties, ", "))
        """, process_target_row)
        for constraint in context.target_constraints
            filter!(target -> evaluate_constraint(constraint, nothing, target, nothing, nothing, nothing, nothing), target_list)
        end
        empty!(context.target_constraints)
        empty!(context.target_properties)
        push!(context.target_properties, "id(t)")
        empty!(context.target_properties_instructions)
        context.target = IdNodeSelector(target_list)
    end
end

function get_all_paths(context::ExecutionContext, connector::CypherConnector, source::NodeSelector, target::NodeSelector)
    @timeit context.profiler "get all paths" begin
        function process_output(row_values)
            process_output_row(context, context.instruction.output, row_values, true, true, nothing)
            return false
        end
        if context.settings.all_paths_algorithm == Cypher
            # Bake everything into the pre-conditions in this
            # mode as we match against the path directly!
            conditions = Vector{String}()
            from = as_query(source, "s")
            to = as_query(target, "t")
            if !isnothing(from.conditions)
                append!(conditions, from.conditions)
            end
            if !isnothing(to.conditions)
                append!(conditions, to.conditions)
            end
            append!(conditions, get_query_conditions(context))

            query_cypher(context.profiler, connector, """
                MATCH p = $(from.select)-[*]->$(to.select)
                $(merge_conditions(conditions))
                RETURN $(get_merged_properties(context))
            """, process_output)
        elseif context.settings.all_paths_algorithm == ApocAll
            conditions = get_query_conditions(context)
            query_cypher(context.profiler, connector, """
                $(as_query_variable(target, "target"))
                MATCH $(flatten(as_query(source, "s")))
                CALL apoc.path.expandConfig(s, {
                    relationshipFilter: ">",
                    endNodes: target
                })
                YIELD path
                WITH path as p, nodes(path) AS elements
                WITH p, elements[0] as s, elements[-1] as t
                $(merge_conditions(conditions))
                RETURN $(get_merged_properties(context))
            """, process_output)
        else
            error("No valid strategy selected")
        end
    end
end

function get_shortest_paths(context::ExecutionContext, connector::CypherConnector, source::NodeSelector, target::NodeSelector, output::Vector{Path}, collection::Set{Path}, weight_property::Union{String, Nothing})
    @timeit context.profiler "get shortest paths" begin
        if !isnothing(weight_property)
            # GDS is slower and doesn't return edge properties, but it does support a weight
            # property which is required to get accurate shortest paths.
            function process_output_false(row_values)
                process_output_row(context, output, row_values, false, false, collection)
                return false
            end
            query_cypher(context.profiler, connector, """
                $(as_query_variable(target, "target"))
                MATCH $(flatten(as_query(source, "s")))
                CALL gds.shortestPath.dijkstra.stream(
                    '$(connector.database)',
                    {
                        sourceNode: s,
                        targetNodes: target,
                        relationshipWeightProperty: '$(weight_property)'
                    }
                )
                YIELD sourceNode, targetNode, path
                WITH path as p, gds.util.asNode(sourceNode) as s, gds.util.asNode(targetNode) as t
                RETURN $(get_merged_properties(context, false))
            """, process_output_false)
        else
            function process_output_true(row_values)
                process_output_row(context, output, row_values, true, false, collection)
                return false
            end
            query_cypher(context.profiler, connector, """
                $(as_query_variable(target, "target"))
                MATCH $(flatten(as_query(source, "s")))
                CALL apoc.path.expandConfig(s, {
                    bfs: true,
                    endNodes: target,
                    relationshipFilter: ">",
                    uniqueness: "NODE_GLOBAL"
                })
                YIELD path
                WITH path as p, nodes(path) AS elements
                WITH p, elements[0] as s, elements[-1] as t
                RETURN $(get_merged_properties(context))
            """, process_output_true)
        end
    end
end

function get_k_shortest_paths(context::ExecutionContext, connector::CypherConnector, source::Int, target::Int, k::Int, output::Vector{Path}, weight_property::Union{String, Nothing})
    @timeit context.profiler "get k shortest paths" begin
        conditions = get_query_conditions(context, false)
        count = 0
        total = 0
        function process_output(row_values)
            total += 1

            # If we only need one path because they are not dependent then we stop returning after
            # the first valid answer, we do this to save on constraint solving time by not including
            # paths that will not be picked.
            if !context.instruction.optimal.dependent_paths && count > 0
                return true
            elseif process_output_row(context, output, row_values, false, true, nothing)
                count += 1
            end
            return false
        end
        if !isnothing(weight_property)
            query_cypher(context.profiler, connector, """
                MATCH (s)
                WHERE id(s) = $source
                MATCH (t)
                WHERE id(t) = $target
                CALL gds.shortestPath.yens.stream(
                    '$(connector.database)',
                    {
                        sourceNode: s,
                        targetNode: t,
                        k: $k,
                        relationshipWeightProperty: '$(weight_property)'
                    }
                )
                YIELD sourceNode, targetNode, path
                WITH path as p, gds.util.asNode(sourceNode) as s, gds.util.asNode(targetNode) as t
                $(merge_conditions(conditions))
                RETURN $(get_merged_properties(context, false))
            """, process_output)
        else
            query_cypher(context.profiler, connector, """
                MATCH (s)
                WHERE id(s) = $source
                MATCH (t)
                WHERE id(t) = $target
                CALL gds.shortestPath.yens.stream(
                    '$(connector.database)',
                    {
                        sourceNode: s,
                        targetNode: t,
                        k: $k
                    }
                )
                YIELD sourceNode, targetNode, path
                WITH path as p, gds.util.asNode(sourceNode) as s, gds.util.asNode(targetNode) as t
                $(merge_conditions(conditions))
                RETURN $(get_merged_properties(context, false))
            """, process_output)
        end
        return count, total
    end
end