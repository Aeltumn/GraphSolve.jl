# Processes connecting with Neo4j through its Bolt protocol using the official Python driver through a PythonCall bridge.
using PythonCall

"""
    create_bolt_connector

    Creates a new session with the Neo4j Bolt protocol connection.
"""
function create_bolt_connector(backend::Neo4jBackend)    
    # Create the session object
    neo4j = pyimport("neo4j")
    driver = neo4j.GraphDatabase.driver(backend.url, auth = (backend.user, backend.password))
    session = driver.session(database = backend.database)
    return BoltNeo4jConnector(session, backend.database, false)
end

function query_cypher(profiler::TimerOutput, connector::BoltNeo4jConnector, query)
    display_query = strip(replace(replace(query, "\n" => " "), r"\s{2,}" => " "))
    @timeit profiler "query $(display_query)" begin
        @timeit profiler "start query" result = connector.session.run(query)
        @timeit profiler "process query" begin
            records = Vector{Vector{Any}}()
            for record in result
                # Fetch the entire row at once and pre-allocate correct size before converting types
                values = collect(record.values())
                len = length(values)
                row = Vector{Any}(undef, len)
                for i in 1:len
                    row[i] = pyconvert(Any, values[i])
                end
                push!(records, row)
            end
        end
        return records
    end
end