# An optional system for benchmarking GraphSolve.
using Dates
using Statistics

"""
    benchmark

    Benchmarks the given set of graphs for each of the given settings.
    First, all combinations are ran once to ensure all code paths are JIT compiled.
    Secondly, each combination is run [iter] times and results are averaged.
"""
function benchmark!(iter, graphs)
    # Set up output logging to log files for later checking
    mkpath("logs")
    average_times = []
    
    # Dry run twice to warm up everything
    println("### Performing dry run")
    j = 0
    m = 1
    for (graph, settings, handler) in graphs
        for n in 1:m
            # Execute with a new profiler so the base one isn't modified
            modified_settings = @set settings.profiler = TimerOutput()

            # Execute the graph itself
            execute!(graph, modified_settings)
            handler(graph)

            # Reset all data afterwards
            reset!(graph)
            j += 1
            println("## Finished running dry run $(j)/$(length(graphs)*m)")
        end
    end
    
    # Run and average results with logging
    println("### Finished warming up, starting benchmark runs")
    logfile = "logs/$(Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")).log"
    open(logfile, "w") do io
        redirect_stdout(io) do
            redirect_stderr(io) do
                for (graph, settings, handler) in graphs
                    # Determine the type of the graph for the log message
                    graph_type = "$(typeof(graph.graph))"
                    if graph.graph isa Neo4jBackend
                        graph_type = graph.graph.bolt ? "Neo4jBoltBackend(dataset=$(graph.graph.database))" : "Neo4jHttpBackend(dataset=$(graph.graph.database))"
                    end
                    
                    # Stringify the settings nicely for readability
                    stringified_settings = "[mode = $(settings.mode), all_paths_algorithm = $(settings.all_paths_algorithm), embed_properties = $(settings.embed_properties), use_async_scheduling = $(settings.use_async_scheduling), preload_nodes = $(settings.preload_nodes), apply_path_constraints = $(settings.apply_path_constraints), push_down_constraints = $(settings.push_down_constraints), re_use_constraint_solutions = $(settings.re_use_constraint_solutions), solver_type = $(settings.solver_type)]"

                    times = []
                    results = []
                    for n in 1:iter
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
                        println("## Finished running iteration $(n) of $(stringified_settings) on $(graph_type), profiler statistics:")
                        show(modified_settings.profiler)
                        println("")
                    end

                    # Print the average time of this series
                    average_time = "## Average series time: $(round(mean(times), digits=3))s ($(round(minimum(times), digits=3))s / $(round(maximum(times), digits=3))s), results: [$(join(results, ", "))] for $(stringified_settings) on $(graph_type)"
                    push!(average_times, average_time)
                end
                
                # Print average times at the end of the file so they are easy to find!
                println("")
                println("### Average time results")
                for average_time in average_times
                    println(average_time)
                end
            end
        end
    end

    # Print the logs back to the IO after we're done for convenience
    println(read(logfile, String))
end