# Implements the incremental path searching algorithm.
mutable struct PathOption
    src::Int
    dst::Int
    k::Int
end

mutable struct IncrementalState
    problem_instruction::ProblemInstruction
    candidate_paths::Vector{Path}
    best_score
    best_paths
    best_variables
    options::Dict{Tuple{Int, Int}, PathOption}
    sources::Set{Int}
    destinations::Set{Int}
end

"""
    has_finished_search

    Runs constraint solving with the current paths contents and returns whether a good-enough score
    has been found.
"""
function has_finished_search(context::ExecutionContext, state::IncrementalState, remaining)
    @timeit context.profiler "check if search completed" begin 
        # Run the constraint solver, determine the current score and determine if it's within
        # the allowed bounds to stop the algorithm.
        copy = Vector{Path}(state.candidate_paths)
        @info "Running verification with $(length(copy)) candidates"
        score, variables = solve_constraints(context, state.problem_instruction, copy, state.best_variables)
        @info "Finished constraint solving iteration with $(length(copy)) paths out of $(length(state.candidate_paths)) for a score of $(score) with $remaining remaining..."

        if context.instruction.optimal.mode == Minimize
            # Update the best score so far
            if isnothing(state.best_score) || score < state.best_score
                state.best_paths = copy
                state.best_score = score
                state.best_variables = variables
                @info "Obtained new best minimum score of $(score) with $(length(copy)) paths selected"

                # Determine if this is the optimal score!
                if context.instruction.optimal.compiled(state.sources, state.destinations, copy, score)
                    append!(context.instruction.output, copy)
                    return true
                end
            end
        else
            # Update the best score so far
            if isnothing(state.best_score) || score > state.best_score
                state.best_paths = copy
                state.best_score = score
                state.best_variables = variables
                @info "Obtained new best maximum score of $(score) with $(length(copy)) paths selected"

                # Determine if this is the optimal score!
                if context.instruction.optimal.compiled(state.sources, state.destinations, copy, score)
                    append!(context.instruction.output, copy)
                    return true
                end
            end
        end
        
        # If this instruction doesn't rely on edges, never iterate as there is nothing to find!
        if !context.instruction.include_edges
            append!(context.instruction.output, copy)
            return true
        end

        # If we've exceeded the timeout, stop the search!
        if time() - context.instruction.optimal.start_time >= (Dates.value(Millisecond(context.instruction.optimal.timeout)) / 1000)
            append!(context.instruction.output, copy)
            return true
        end
        return false
    end
end

"""
    incremental_path_search

    Runs the incremental path search algorithm which runs multiple rounds of shortest path finding
    and constraint solving until it finds a feasible solution to the problems.
"""
function incremental_path_search(context::ExecutionContext, connector::Connector, problem_instruction::ProblemInstruction)
    # Step 1: Find shortest paths once to determine all feasible pairs, separate the feasible source/targets from
    # the feasible paths.
    collection = Set{Path}()
    candidate_paths = Vector{Path}()
    get_shortest_paths(context, connector, context.source, context.target, candidate_paths, collection, problem_instruction.path.weight_property)
    @info "Found initial collection of $(length(collection)) pairs"

    # Step 1b: Fetch properties for newly added nodes & edges
    fetch_all_properties(context, connector, collection)

    # Step 2: Determine original sources and destinations for optimal solution
    @timeit context.profiler "determine sources and destinations for stopping condition" begin
        sources = get_source_nodes(collection)
        destinations = get_destination_nodes(collection)
    end

    # Step 3: Attempt to run constraint solving and end if we've reached the answers
    options = Dict{Tuple{Int, Int}, PathOption}()
    state = IncrementalState(problem_instruction, candidate_paths, nothing, nothing, nothing, options, sources, destinations)
    if has_finished_search(context, state, "n/a")
        return
    end

    # Step 4: Determine all feasible (source, destination) pairs and create holding
    # objects for each of them which we can later test.
    @timeit context.profiler "prepare path options" begin
        solved_pairs = Set{Tuple{Int, Int}}()
        if !context.instruction.optimal.dependent_paths
            for path in candidate_paths
                pair = (path.src, path.dst)
                push!(solved_pairs, pair)
            end
        end

        for path in collection
            pair = (path.src, path.dst)

            # If paths are independent we can ignore any paths that we
            # already selected in the candidate paths, we only have to
            # search until we can find one valid path for each pair.
            if !context.instruction.optimal.dependent_paths
                if pair ∈ solved_pairs
                    continue
                end
            end

            if !haskey(options, pair)
                options[pair] = PathOption(path.src, path.dst, 0)
            end
        end
    end

    # Step 5: Run a loop where we continously select k random paths to find improvements for
    # we select this from all holding objects, finding any pairs that have not yet been
    # selected in the solution (if applicable), and selecting an improvement strategy to try.
    # After every loop completes, we attempt constraint solving again with the new candidates.
    added_paths = 0
    i = 1
    rng = MersenneTwister(1451861561)
    while i < 1000
        i += 1

        # We iterate over a lot of paths per solver attempts, finding paths is much, much faster
        # than solving because it's parallel whereas solving isn't. So we run a lot of tasks
        # before we make an attempt to solve again.
        @timeit context.profiler "search for additional candidate paths" begin
            # Shuffle the candidates randomly before sorting by lowest k
            selectable = collect(values(options))
            shuffle!(rng, selectable)
            sort!(selectable, by = it -> it.k)

            # If there were no valid tasks, we cannot improve the score anymore!
            if isempty(selectable)
                break
            end

            # Go through the first k selectables
            scheduled_paths = 0
            tasks = Vector{Task}()
            for candidate in selectable
                # Stop iterating when we reach the limit!
                if scheduled_paths > context.settings.maximum_paths
                    break
                end

                # Get k-shortest paths for this candidate, keep finding more paths every iteration
                increment = floor(Int, context.settings.delta_k * (1 + candidate.k / context.settings.delta_k))
                new_k = candidate.k + increment
                candidate.k = new_k

                # Find the k-shortest paths for this group
                scheduled_paths += increment
                push!(
                    tasks,
                    @schedule_task context.settings begin
                        # Fetch the k-shortest paths from each path, if we find enough new paths we keep
                        # it in the list to try find more in a future iteration!
                        new_valid_paths, new_paths = get_k_shortest_paths(context, connector, candidate.src, candidate.dst, new_k, candidate_paths, problem_instruction.path.weight_property)
                        added_paths += new_valid_paths
                        if new_paths < (increment - 5)
                            delete!(options, (candidate.src, candidate.dst))
                        end

                        # If paths are independent we only need to find a single path
                        # before we can stop trying this pair for options.
                        if !context.instruction.optimal.dependent_paths && new_paths > 0
                            delete!(options, (candidate.src, candidate.dst))
                        end
                    end
                )

                # Never fetch more than the maximum paths!
                if new_k >= context.settings.max_k
                    delete!(options, (candidate.src, candidate.dst))
                end
            end

            # Await all tasks
            @info "Scheduled $scheduled_paths paths to be found out in $(length(tasks)) tasks"
            for task in tasks
                wait(task)
            end
            @info "After all tasks $(length(selectable)) options remain"

            # If there were no tasks, break the loop!
            if scheduled_paths <= 0
                break
            end
        end

        # Skip constraint solving if there's not enough new paths!
        if added_paths <= context.settings.minimum_paths
            continue
        end

        # Fetch new edge properties for newly found edges
        fetch_all_properties(context, connector, candidate_paths)

        # Run constraint solving with new candidates and find a valid solution to the problem
        added_paths = 0
        if has_finished_search(context, state, length(options))
            return
        end
    end
    
    # Run constraint solving one more time and return the best result!
    if added_paths > 0
        fetch_all_properties(context, connector, candidate_paths)
        if has_finished_search(context, state, 0)
            return
        end
    end
    if !isnothing(state.best_paths)
        append!(context.instruction.output, state.best_paths)
    end
end