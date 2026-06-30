# An optional system for benchmarking GraphSolve.
using Dates
using Statistics

"""
    benchmark

    Benchmarks the given set of graphs for each of the given settings.
    For each combination, it is ran once to ensure all code paths are JIT compiled,
    then it is run [iter] times and results are averaged from these [iter] runs.
"""
function benchmark!(iter, graphs, print_profiler::Bool=false)
    # Set up output logging to log files for later checking
    mkpath("logs")
    average_times = []
    
    logfile = "logs/$(Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")).log"
    logger = TeeLogger(ConsoleLogger(stdout), FileLogger(logfile))
    global_logger(logger)
        
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
        for n in 1:(iter + 1)
            # Create a copy of the settings with a new profiler
            modified_settings = @set settings.profiler = TimerOutput()

            # Execute the graph itself
            @timeit modified_settings.profiler "full execution" begin
                start = time()
                execute!(graph, modified_settings)
                result = handler(graph)
                if iter == 0 || n > 1
                    push!(times, time() - start)
                    push!(results, result)
                end
            end

            # Reset all data afterwards
            reset!(graph)

            # Print out the profiling information
            @info "## Finished running iteration $(n) on graph #$(graphId) in $(time() - start) seconds of $(stringified_settings) on $(graph_type), profiler statistics:"
            if print_profiler
                @info sprint(show, MIME"text/plain"(), modified_settings.profiler)
            end

            # Wait a moment to print the profiler
            sleep(1)
        end

        # Print the average time of this series
        if length(times) > 0
            average_time = "## Average series time on graph #$(graphId): $(round(mean(times), digits=3))s ($(round(minimum(times), digits=3))s / $(round(maximum(times), digits=3))s), results: [$(join(results, ", "))] for $(stringified_settings) on $(graph_type)"
            push!(average_times, average_time)
        end
        graphId += 1
        
        # Wait a moment between benchmarks
        sleep(3)
    end
    
    # Print average times at the end of the file so they are easy to find!
    @info ""
    @info "### Average time results"
    for average_time in average_times
        @info average_time
    end
end