# Processes connecting with Neo4j through its Bolt protocol using the official Python driver through a PythonCall bridge.
using PythonCall

"""
    create_bolt_connector

    Creates a new session with the Neo4j Bolt protocol connection.
"""
function create_bolt_connector(backend::Neo4jBackend)    
    # Create the session object
    neo4j = pyimport("neo4j")
    driver = neo4j.GraphDatabase.driver(
        backend.url, 
        auth = (backend.user, backend.password),
        connection_timeout=60,
        max_connection_lifetime=24*3600
    )
    return BoltNeo4jConnector(driver, backend.database, false)
end

function query_cypher(profiler::TimerOutput, connector::BoltNeo4jConnector, query, process_row)
    display_query = strip(replace(replace(query, "\n" => " "), r"\s{2,}" => " "))
    @timeit profiler "query $(display_query)" begin
        @info "Query: $(display_query)"
        start = time()
        pywith(connector.driver.session(database = connector.database)) do session
            @timeit profiler "start query" result = session.run(query)
            if isnothing(process_row)
                return
            end
            @timeit profiler "process query" begin
                for record in result
                    # Fetch the entire row at once and pre-allocate correct size before converting types
                    values = collect(record.values())
                    len = length(values)
                    row = Vector{Any}(undef, len)
                    for i in 1:len
                        row[i] = pyconvert(Any, values[i])
                    end
                    process_row(row)
                end
            end
        end
        @info "Query took $(time() - start) seconds!"
    end
end