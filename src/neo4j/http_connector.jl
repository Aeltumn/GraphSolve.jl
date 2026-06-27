# Processes connecting to the Neo4j database and handling authentication.
using HTTP
using Base64
using JSON3

"""
    determine_connection_headers

    Determines the headers to append to the request to Neo4j.
"""
function determine_connection_headers(backend::Neo4jBackend)::Dict{String, String}
    headers = Dict{String, String}()
    headers["Accept"] = "application/json;charset=UTF-8"
    headers["Content-Type"] = "application/json"
    headers["Authorization"] = "Basic $(base64encode("$(backend.user):$(backend.password)"))"
    return headers
end

function query_cypher(profiler::TimerOutput, connector::HttpNeo4jConnector, query, process_row)
    # display_query = strip(replace(replace(query, "\n" => " "), r"\s{2,}" => " "))
    @timeit profiler "execute query" begin
        @timeit profiler "serialize query" body = JSON3.write(Dict("statements" => [Dict("statement" => query)]))
        @timeit profiler "run query" resp = HTTP.post(connector.url, headers=connector.headers, body=body, readtimeout=0)

        # Check that the POST request was succesful and didn't have connection issues
        if resp.status != 200
            error("Request to Neo4j database failed with status code `$(resp.status)`\n$(String(resp.body))")
        end
        if isnothing(process_row)
            return
        end
        @timeit profiler "parse query" data = JSON3.read(resp.body)

        @timeit profiler "process query" begin
            # Check if there were any errors reported
            if !isempty(data["errors"])
                for err in data["errors"]
                    @error "Neo4j database reported error ($(err["code"])): $(err["message"])"
                end
                error("Neo4j database returned one or more errors that have to be fixed")
            end

            # If there's no results there was no valid query?
            if isempty(data["results"])
                error("Neo4j database returned no results, is the query valid?")
            end

            for row in data["results"][1]["data"]
                if process_row(row["row"])
                    break
                end
            end
        end
    end
end