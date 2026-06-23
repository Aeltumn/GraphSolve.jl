# Implements the incremental path searching algorithm.
mutable struct PathOption
    src::Int
    dst::Int
    k::Int
end

mutable struct IncrementalState
    problem_instruction::ProblemInstruction
    optimal_score
    candidate_paths::Vector{Path}
    best_score
    best_paths
    best_variables
    options::Dict{Tuple{Int, Int}, PathOption}
end

"""
    has_finished_search

    Runs constraint solving with the current paths contents and returns whether a good-enough score
    has been found.
"""
function has_finished_search(context::ExecutionContext, state::IncrementalState)
    @timeit context.profiler "check if search completed" begin 
        # Run the constraint solver, determine the current score and determine if it's within
        # the allowed bounds to stop the algorithm.
        copy = Vector{Path}(state.candidate_paths)
        score, variables = solve_constraints(context, state.problem_instruction, copy, state.best_variables)
        p = context.instruction.optimal.p

        if context.instruction.optimal.mode == Minimize
            # Update the best score so far
            if isnothing(state.best_score) || score < state.best_score
                state.best_paths = copy
                state.best_score = score
                state.best_variables = variables
                @info "Obtained new best minimum score of $(score) (optimal: $(state.optimal_score)) with $(length(copy)) paths selected"
            end

            if p >= 0.0 && score * p <= state.optimal_score
                # Store the final solution in the output array!
                append!(context.instruction.output, copy)
                return true
            end
        else
            # Update the best score so far
            if isnothing(state.best_score) || score > state.best_score
                state.best_paths = copy
                state.best_score = score
                state.best_variables = variables
                @info "Obtained new best maximum score of $(score) (optimal: $(state.optimal_score)) with $(length(copy)) paths selected"
            end

            if p >= 0.0 && state.optimal_score * p <= score
                # Store the final solution in the output array!
                append!(context.instruction.output, copy)
                return true
            end
        end

        # Log for every iteration so there's some progress tracker
        @info "Finished constraint solving iteration with $(length(copy)) paths out of $(length(state.candidate_paths)) for a score of $(score)..."
        
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
    get_shortest_paths(context, connector, context.source, context.target, candidate_paths, collection)

    # Step 1b: Fetch properties for newly added nodes & edges
    fetch_all_properties(context, connector, collection)

    # Step 2: Determine the optimal value to strive for
    @timeit context.profiler "determine optimal value" begin
        sources = get_source_nodes(collection)
        destinations = get_destination_nodes(collection)
        optimal_score = context.instruction.optimal.compiled(sources, destinations)
    end

    # Step 3: Attempt to run constraint solving and end if we've reached the answers
    options = Dict{Tuple{Int, Int}, PathOption}()
    state = IncrementalState(problem_instruction, optimal_score, candidate_paths, nothing, nothing, nothing, options)
    @info "Running first verification with $(length(candidate_paths)) candidates and a collection of $(length(collection)) pairs"
    if has_finished_search(context, state)
        return
    end

    # Step 4: Determine all feasible (source, destination) pairs and create holding
    # objects for each of them which we can later test.
    @timeit context.profiler "prepare path options" begin
        for path in collection
            pair = (path.src, path.dst)
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

                # Fetch the k-shortest paths from each path, if we find enough new paths we keep
                # it in the list to try find more in a future iteration!
                new_valid_paths, new_paths = get_k_shortest_paths(context, connector, candidate.src, candidate.dst, new_k, candidate_paths)
                added_paths += new_valid_paths
                if new_paths < (increment - 5)
                    delete!(options, (candidate.src, candidate.dst))
                end

                # Never fetch more than the maximum paths!
                if new_k >= context.settings.max_k
                    delete!(options, (candidate.src, candidate.dst))
                end
            end

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
        if has_finished_search(context, state)
            return
        end
    end
    
    # Run constraint solving one more time and return the best result!
    if added_paths > 0
        fetch_all_properties(context, connector, candidate_paths)
        if has_finished_search(context, state)
            return
        end
    end
    if !isnothing(state.best_paths)
        append!(context.instruction.output, state.best_paths)
    end
end