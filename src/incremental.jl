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
            end

            if p >= 0.0 && state.optimal_score * p <= score
                # Store the final solution in the output array!
                append!(context.instruction.output, copy)
                return true
            end
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
    # Step 1: Find shortest paths once to determine all feasible pairs
    candidate_paths = Vector{Path}()
    get_shortest_paths(context, connector, context.source, context.target, candidate_paths)

    # Step 1b: Fetch properties for newly added nodes & edges
    if !context.settings.embed_properties
        fetch_all_properties(context, connector, candidate_paths)
    end

    # Step 2: Determine the optimal value to strive for
    @timeit context.profiler "determine optimal value" begin
        sources = get_source_nodes(candidate_paths)
        destinations = get_destination_nodes(candidate_paths)
        optimal_score = context.instruction.optimal.compiled(sources, destinations)
    end

    # Step 3: Attempt to run constraint solving and end if we've reached the answers
    options = Dict{Tuple{Int, Int}, PathOption}()
    state = IncrementalState(problem_instruction, optimal_score, candidate_paths, nothing, nothing, nothing, options)
    if has_finished_search(context, state)
        return
    end

    # Step 4: Determine all feasible (source, destination) pairs and create holding
    # objects for each of them which we can later test.
    @timeit context.profiler "prepare path options" begin
        for path in candidate_paths
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
            max_tasks = 500
            added_k_value = 25
            max_k_value = 100
            minimum_paths = 5000

            # Determine sets of previously used logic
            goal = context.instruction.goal
            used_sources = goal == AssignSourcesToDestinations ? get_source_nodes(state.best_paths) : nothing
            
            # If we're assigning every source to a destination we ignore
            # paths if we've already assigned that source.
            if goal == AssignSourcesToDestinations
                selectable = Vector{PathOption}()
                for candidate in values(options)
                    if candidate.src ∈ used_sources
                        continue
                    end
                    push!(selectable, candidate)
                end
            else
                selectable = collect(values(options))
            end

            # Shuffle the candidates randomly before sorting by lowest k
            shuffle!(rng, selectable)
            sort!(selectable, by = it -> it.k)

            # If there were no valid tasks, we cannot improve the score! Just return the best score.
            if isempty(selectable)
                append!(context.instruction.output, state.best_paths)
                return
            end

            # Go through the first k selectables and create tasks
            tasks = Vector{Task}()
            j = 0
            l = 0
            for candidate in selectable
                # Stop iterating when we reach the limit!
                if j >= max_tasks
                    break
                end
                j += 1

                # Get k-shortest paths for this candidate, keep finding more paths every iteration
                new_k = max(added_k_value, candidate.k + added_k_value)
                candidate.k = new_k

                # Never fetch more than the maximum paths!
                if new_k > max_k_value
                    continue
                end

                # Find the k-shortest paths for this group
                l += 1
                if context.settings.use_async_scheduling
                    push!(
                        tasks,
                        @async begin
                            # Fetch the k-shortest paths from each path, if we find enough new paths we keep
                            # it in the list to try find more in a future iteration!
                            new_paths = get_k_shortest_paths(context, connector, candidate.src, candidate.dst, new_k, candidate_paths)
                            added_paths += new_paths
                            if new_paths < (added_k_value - 5)
                                delete!(options, (candidate.src, candidate.dst))
                            end
                        end
                    )
                else
                    # Fetch the k-shortest paths from each path, if we find enough new paths we keep
                    # it in the list to try find more in a future iteration!
                    new_paths = get_k_shortest_paths(context, connector, candidate.src, candidate.dst, new_k, candidate_paths)
                    added_paths += new_paths
                    if new_paths < (added_k_value - 5)
                        delete!(options, (candidate.src, candidate.dst))
                    end
                end
            end

            # Wait for all queries to complete, otherwise return immediately!
            if l <= 0
                append!(context.instruction.output, state.best_paths)
                return
            end
            for task in tasks
                wait(task)
            end
        end

        # Skip constraint solving if there's not enough new paths!
        if added_paths <= minimum_paths
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
    
    # Run constraint solving one more time!
    if added_paths > 0 && has_finished_search(context, state)
        return
    end
end