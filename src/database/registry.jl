# The global index of a `Database`. Every member numbers its compounds, properties and
# references from 1, which is what makes its own queries direct array reads. The registry gives
# the same thing one number in all members and maps both ways, so a question about "water" is
# put to each member in its own numbers and a member that does not know water is never read.

"""
    Registry

Global identifiers of the compounds, properties and references of the members of a
[`Database`](@ref), and for each member the map from its own identifiers to them.

- A compound is the same in two members when its key is: the InChIKey, or `"name:..."` for a
  compound the archive knows only by name. Nothing is merged by guessing; compounds known only by
  name are listed in `unkeyed`, so the user can give them an InChIKey.
- A property is the pair (label, unit), a reference is a DOI (a reference without one is
  never the same as another).
"""
struct Registry
    members::Vector{String}
    compound_keys::Vector{String}
    property_keys::Vector{Tuple{String,String}}
    references::Int
    compound::Vector{Vector{Int32}}
    property::Vector{Vector{Int32}}
    reference::Vector{Vector{Int32}}
    compound_index::Dict{String,Int32}
    doi_index::Dict{String,Int32}
    label_index::Dict{String,Vector{Int32}}
    name_index::Dict{String,Vector{Int32}}
    has_compound::Vector{BitVector}
    has_property::Vector{BitVector}
    has_reference::Vector{BitVector}
    unkeyed::Vector{Tuple{String,Int32}}
end

function build_registry(
    names::AbstractVector{<:AbstractString},
    catalogs::AbstractVector{Catalog},
)
    compound_keys = String[]
    compound_index = Dict{String,Int32}()
    property_keys = Tuple{String,String}[]
    property_index = Dict{Tuple{String,String},Int32}()
    label_index = Dict{String,Vector{Int32}}()
    name_index = Dict{String,Vector{Int32}}()
    doi_index = Dict{String,Int32}()
    references = 0
    unkeyed = Tuple{String,Int32}[]
    compound = Vector{Int32}[]
    property = Vector{Int32}[]
    reference = Vector{Int32}[]
    for (m, cat) in enumerate(catalogs)
        map = Vector{Int32}(undef, length(cat.compound_key))
        for (c, key) in enumerate(cat.compound_key)
            g = get(compound_index, key, Int32(0))
            if g == 0
                push!(compound_keys, key)
                g = Int32(length(compound_keys))
                compound_index[key] = g
                startswith(key, "name:") && push!(unkeyed, (String(names[m]), Int32(c)))
            end
            map[c] = g
            for text in (cat.compound_inchikey[c], cat.compound_formula[c])
                isempty(text) || push!(get!(Vector{Int32}, name_index, lowercase(text)), g)
            end
            for name in cat.compound_names[c]
                push!(get!(Vector{Int32}, name_index, normalize_name(name)), g)
            end
        end
        push!(compound, map)
        pmap = Vector{Int32}(undef, length(cat.property_label))
        for p in eachindex(pmap)
            key = (cat.property_label[p], cat.property_unit[p])
            g = get(property_index, key, Int32(0))
            if g == 0
                push!(property_keys, key)
                g = Int32(length(property_keys))
                property_index[key] = g
                push!(get!(Vector{Int32}, label_index, lowercase(strip(key[1]))), g)
            end
            pmap[p] = g
        end
        push!(property, pmap)
        rmap = Vector{Int32}(undef, length(cat.doi))
        for (r, doi) in enumerate(cat.doi)
            key = lowercase(strip(doi))
            g = isempty(key) ? Int32(0) : get(doi_index, key, Int32(0))
            if g == 0
                references += 1
                g = Int32(references)
                isempty(key) || (doi_index[key] = g)
            end
            rmap[r] = g
        end
        push!(reference, rmap)
    end
    foreach(unique!, values(name_index))
    present(maps, n) = [
        begin
            bits = falses(n)
            bits[map] .= true
            bits
        end for map in maps
    ]
    return Registry(
        String.(names),
        compound_keys,
        property_keys,
        references,
        compound,
        property,
        reference,
        compound_index,
        doi_index,
        label_index,
        name_index,
        present(compound, length(compound_keys)),
        present(property, length(property_keys)),
        present(reference, references),
        unkeyed,
    )
end

# The compounds of member `m` (its own identifiers) that are the global compound `g`.
function local_compounds(reg::Registry, m::Integer, globals)
    wanted = falses(length(reg.compound_keys))
    wanted[globals] .= true
    map = reg.compound[m]
    return Int32[c for c in eachindex(map) if wanted[map[c]]]
end

Base.show(io::IO, r::Registry) = print(
    io,
    "Registry(",
    length(r.members),
    " databases, ",
    length(r.compound_keys),
    " compounds, ",
    length(r.property_keys),
    " properties, ",
    r.references,
    " references)",
)
