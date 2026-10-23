"""
Identifier conventions shared by every table of the schema.

Identifiers are `Int32` positions into the owning table. `NO_ID` (zero) means "absent",
so a column of identifiers never needs `missing`.
"""
const NO_ID = Int32(0)

"""
    StringPool()

Interning table that maps repeated strings (methods, phases, composition kinds, source
names) to small integer identifiers. The empty string is always `NO_ID` and is never
stored.
"""
struct StringPool
    strings::Vector{String}
    index::Dict{String,Int32}
end

StringPool() = StringPool(String[], Dict{String,Int32}())

Base.length(pool::StringPool) = length(pool.strings)

"""
    intern!(pool, s) -> Int32

Return the identifier of `s`, adding it when new. `""` returns [`NO_ID`](@ref).
"""
function intern!(pool::StringPool, s::AbstractString)
    isempty(s) && return NO_ID
    id = get(pool.index, s, NO_ID)
    id != NO_ID && return id
    str = String(s)
    push!(pool.strings, str)
    id = Int32(length(pool.strings))
    pool.index[str] = id
    return id
end

"""
    pool_string(pool, id) -> String

Inverse of [`intern!`](@ref); `NO_ID` gives `""`.
"""
pool_string(pool::StringPool, id::Integer) = id == NO_ID ? "" : pool.strings[id]
