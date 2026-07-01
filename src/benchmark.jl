# An optional system for benchmarking GraphSolve.
"""
    benchmark

    Benchmarks the given set of graphs for each of the given settings.
    For each combination, it is ran once to ensure all code paths are JIT compiled,
    then it is run [iter] times and results are averaged from these [iter] runs.
"""
function benchmark!(iter, graphs, print_profiler::Bool=false)
    # Set up output logging to log files for later checking
    mkpath("logs")
    result_messages = []

    if iter == 0
        logger = ConsoleLogger(stdout)
    else    
        logfile = "logs/$(Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")).log"
        logger = TeeLogger(ConsoleLogger(stdout), FileLogger(logfile))
    end

    # Prepend a timestamp to all log messages
    timestampLogger = TransformerLogger(logger) do log
        merge(log, (; message = "[$(Dates.format(now(), "yyyy-mm-dd HH:MM:SS.sss"))] $(log.message)"))
    end
    global_logger(timestampLogger)

    # Determine how many iterations should be run
    if iter == 0
        iterations = 1
    else
        iterations = iter
    end
        
    # Run and average results with logging
    graphId = 1
    for (graph, settings, handler) in graphs
        # Determine the type of the graph for the log message
        graph_type = "$(typeof(graph.graph))"
        if graph.graph isa Neo4jBackend
            graph_type = graph.graph.bolt ? "Neo4jBoltBackend(dataset=$(graph.graph.database))" : "Neo4jHttpBackend(dataset=$(graph.graph.database))"
        end
        
        # Stringify the settings nicely for readability
        stringified_settings = "[mode = $(settings.mode), use_async_scheduling = $(settings.use_async_scheduling), preload_nodes = $(settings.preload_nodes), apply_path_constraints = $(settings.apply_path_constraints), push_down_constraints = $(settings.push_down_constraints), re_use_constraint_solutions = $(settings.re_use_constraint_solutions), solver_type = $(settings.solver_type)]"

        times = []
        results = []
        for n in 1:iterations
            # Create a copy of the settings with a new profiler
            modified_settings = @set settings.profiler = TimerOutput()

            # Execute the graph itself
            @timeit modified_settings.profiler "full execution" begin
                start = time()
                execute!(graph, modified_settings)
                result = handler(graph)
                push!(times, time() - start)
                push!(results, result)
            end

            # Reset all data afterwards
            reset!(graph)

            # Print out the profiling information
            @info "# Finished running iteration $(n) on graph #$(graphId) in $(time() - start) seconds of $(stringified_settings) on $(graph_type), profiler statistics:"
            if print_profiler
                @info sprint(show, MIME"text/plain"(), modified_settings.profiler)
            end

            # Wait a moment to print the profiler
            sleep(1)
        end

        # Print the average time of this series
        if length(times) > 0
            average_time = "-> ## Average series time on graph #$(graphId): $(round(mean(times), digits=3))s ($(round(minimum(times), digits=3))s / $(round(maximum(times), digits=3))s), results: [$(join(results, ", "))] for $(stringified_settings) on $(graph_type)"
            push!(result_messages, average_time)
            @info average_time
        end
        benchmark_time = "-> ## Benchmarking times: $(get_benchmark_times())"
        push!(result_messages, benchmark_time)
        @info benchmark_time
        push!(result_messages, "")

        graphId += 1
        
        # Wait a moment between benchmarks
        sleep(3)
    end
    
    # Print average times at the end of the file so they are easy to find!
    @info ""
    @info "### Results"
    for message in result_messages
        @info message
    end
    @info ""
end