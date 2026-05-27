# Adds logic for loading graphs into Julia.
using CSV

"""
    load_julia_graph

    Loads a Julia graph from two csv files.
"""
function load_julia_graph(backend::JuliaGraphBackend)
    nodes = Dict{Int, String}()
    max_node = 0
    node_properties = NodePropertyDict() 
    edge_properties = EdgePropertyDict()

    open(backend.nodes, "r") do io
        for row in CSV.File(io)
            # Add this node to the list
            nodes[row.id] = row.label
            max_node = max(max_node, row.id + 1)

            # Parse any properties into the properties data
            for (name, value) in pairs(row)
                if name == :id || name == :label
                    continue
                end

                get!(node_properties, row.id, Dict{String, Any}())[String(name)] = value
            end
        end
    end

    graph = SimpleDiGraph(max_node)

    open(backend.edges, "r") do io
        for row in CSV.File(io)
            # Add this edge to the graph
            add_edge!(graph, row.from + 1, row.to + 1)

            # Parse any properties into the properties data
            edge = (row.from, row.to)
            for (name, value) in pairs(row)
                if name == :from || name == :to || name == :label || name == :id
                    continue
                end

                get!(edge_properties, edge, Dict{String, Any}())[String(name)] = value
            end
        end
    end
    return graph, nodes, node_properties, edge_properties
end
