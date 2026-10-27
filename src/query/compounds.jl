# Compound lookup that does not depend on how a name is spelled.
#
# A name is reduced to a normalised key (lower case, accents removed, only letters and
# digits kept), so "Iso-Butane", "isobutane" and "ISO BUTANE" are the same key. Every
# synonym that the sources gave for a compound is indexed once, on first use, and the
# index is rebuilt only when compounds or names have been added since. A lookup is then
# one hash probe per spelling variant instead of a scan of the compound table.

# ----------------------------------------------------------------------------------
# Normalisation, spelling variants and aliases
# ----------------------------------------------------------------------------------

"""
    normalize_name(text) -> String

Lower-case `text`, strip accents and keep only letters and digits.
"""
function normalize_name(text::AbstractString)
    folded = Unicode.normalize(text; casefold = true, stripmark = true)
    io = IOBuffer()
    for c in folded
        (isletter(c) || isdigit(c)) && write(io, c)
    end
    return String(take!(io))
end

# British/American and other common spelling differences, applied to normalised keys.
const SPELLING_VARIANTS = (
    "sulphur" => "sulfur",
    "sulphate" => "sulfate",
    "sulphide" => "sulfide",
    "sulphite" => "sulfite",
    "sulpho" => "sulfo",
    "sulphonic" => "sulfonic",
    "aluminium" => "aluminum",
    "caesium" => "cesium",
    "ethylene" => "ethene",
    "propylene" => "propene",
    "acetylene" => "ethyne",
    "dinitrogen" => "nitrogen",
    "dioxygen" => "oxygen",
    "dihydrogen" => "hydrogen",
)

# Abbreviations and common names that the sources rarely use. Each alias maps to the names
# under which the compound is usually listed; a target that is not in the database is
# simply skipped, so an entry never creates a match by itself.
const COMPOUND_ALIASES = Dict{String,Vector{String}}(
    "meoh" => ["methanol"],
    "etoh" => ["ethanol"],
    "ipa" => ["propan-2-ol", "2-propanol", "isopropanol", "isopropyl alcohol"],
    "dme" => ["dimethyl ether", "methoxymethane"],
    "dmso" => ["dimethyl sulfoxide", "methylsulfinylmethane"],
    "dmf" => ["N,N-dimethylformamide", "dimethylformamide"],
    "thf" => ["tetrahydrofuran", "oxolane"],
    "mtbe" => ["methyl tert-butyl ether", "2-methoxy-2-methylpropane"],
    "mek" => ["butan-2-one", "2-butanone", "methyl ethyl ketone"],
    "mea" => ["2-aminoethanol", "ethanolamine"],
    "dea" => ["diethanolamine", "2,2'-iminodiethanol"],
    "mdea" => ["N-methyldiethanolamine", "2,2'-(methylimino)diethanol"],
    "eg" => ["ethane-1,2-diol", "1,2-ethanediol", "ethylene glycol"],
    "deg" => ["diethylene glycol", "2,2'-oxydiethanol"],
    "teg" => ["triethylene glycol"],
    "isopentane" => ["2-methylbutane"],
    "neopentane" => ["2,2-dimethylpropane"],
    "isohexane" => ["2-methylpentane"],
)

# Spellings of the query, most literal first. Each tier is tried only if the previous one
# found nothing, so a loose variant never overrides an exact name.
function query_tiers(text::AbstractString)
    raw = lowercase(strip(text))
    base = normalize_name(raw)
    isempty(base) && return Vector{Vector{String}}()
    tiers = [[base]]
    variants = String[]
    # Prefix notations: n-butane, i-butane, t-butanol, s-butanol.
    m = match(r"^(n|i|t|s)[-\s]+(.+)$", raw)
    if m !== nothing
        rest = normalize_name(m.captures[2])
        prefix = Dict("n" => "", "i" => "iso", "t" => "tert", "s" => "sec")[m.captures[1]]
        push!(variants, prefix * rest)
    end
    for key in vcat(base, variants), (from, to) in SPELLING_VARIANTS
        occursin(from, key) && push!(variants, replace(key, from => to))
    end
    for name in get(COMPOUND_ALIASES, base, String[])
        push!(variants, normalize_name(name))
    end
    unique!(variants)
    filter!(!=(base), variants)
    isempty(variants) || push!(tiers, variants)
    return tiers
end

# ----------------------------------------------------------------------------------
# The index
# ----------------------------------------------------------------------------------

function build_name_index(t::CompoundTable)
    ids = Dict{String,Vector{Int32}}()
    nnames = 0
    function add!(key::String, id::Int32)
        isempty(key) && return nothing
        list = get!(ids, key, Int32[])
        (isempty(list) || last(list) != id) && push!(list, id)
        return nothing
    end
    for c in eachindex(t.names)
        id = Int32(c)
        for name in t.names[c]
            nnames += 1
            add!(normalize_name(name), id)
            # "n-hexane" is also reachable as "hexane".
            occursin(r"^[nN][-\s]", name) && add!(normalize_name(name[3:end]), id)
        end
    end
    return NameIndex(length(t), nnames, ids, collect(String, Base.keys(ids)))
end

function name_index(t::CompoundTable)
    nnames = sum(length, t.names; init = 0)
    index = t.lookup[]
    if index === nothing || index.ncompounds != length(t) || index.nnames != nnames
        index = build_name_index(t)
        t.lookup[] = index
    end
    return index
end

# Compounds named by a single spelling tier (ids sorted and unique), or empty.
function lookup_names(index::NameIndex, text::AbstractString)
    for tier in query_tiers(text)
        found = Int32[]
        for key in tier
            append!(found, get(index.ids, key, Int32[]))
        end
        isempty(found) || return sort!(unique!(found))
    end
    return Int32[]
end

# ----------------------------------------------------------------------------------
# Approximate matching
# ----------------------------------------------------------------------------------

# Levenshtein distance, or `limit + 1` as soon as it is certain to exceed `limit`.
function edit_distance(a::AbstractString, b::AbstractString, limit::Int)
    x = codeunits(a)
    y = codeunits(b)
    abs(length(x) - length(y)) > limit && return limit + 1
    previous = collect(0:length(y))
    current = similar(previous)
    for i in eachindex(x)
        current[1] = i
        best = i
        for j in eachindex(y)
            cost = x[i] == y[j] ? 0 : 1
            current[j+1] = min(previous[j+1] + 1, current[j] + 1, previous[j] + cost)
            best = min(best, current[j+1])
        end
        best > limit && return limit + 1
        previous, current = current, previous
    end
    return previous[end]
end

function similarity_limit(n::Int)
    n <= 4 && return 1
    n <= 8 && return 2
    return 3
end

# Candidate compounds for a name that did not match, best first, as (id, how) pairs:
# names that contain the text (or are contained in it), then names a few edits away.
function approximate_matches(index::NameIndex, text::AbstractString)
    base = normalize_name(text)
    isempty(base) && return Tuple{Int32,Symbol}[]
    limit = similarity_limit(length(base))
    # (edit distance, 0 = contains / 1 = similar, name length, key); closest first.
    ranked = Tuple{Int,Int,Int,String}[]
    for key in index.keys
        if length(base) >= 3 && occursin(base, key) ||
           length(key) >= 4 && occursin(key, base)
            push!(ranked, (edit_distance(base, key, 64), 0, length(key), key))
        else
            d = edit_distance(base, key, limit)
            d <= limit && push!(ranked, (d, 1, length(key), key))
        end
    end
    sort!(ranked)
    out = Tuple{Int32,Symbol}[]
    for (_, kind, _, key) in ranked, id in index.ids[key]
        push!(out, (id, kind == 0 ? :contains : :similar))
    end
    return out
end

# ----------------------------------------------------------------------------------
# Exact identifiers and the public lookup
# ----------------------------------------------------------------------------------

# Compounds whose InChIKey or formula is the text, as written.
function identifier_matches(t::CompoundTable, text::AbstractString)
    wanted = strip(text)
    key = uppercase(wanted)
    found = Int32[]
    for c = 1:length(t)
        (t.inchikey[c] == key || t.formula[c] == wanted) && push!(found, Int32(c))
    end
    return found
end

function matching_compounds(ds::Dataset, text::AbstractString)
    t = ds.compounds
    found = identifier_matches(t, text)
    append!(found, lookup_names(name_index(t), text))
    if isempty(found)
        hints = didyoumean(ds, text)
        suffix = isempty(hints) ? "" : "; did you mean " * join(hints, ", ", " or ") * "?"
        throw(ArgumentError("no compound matches \"$text\"$suffix"))
    end
    return sort!(unique!(found))
end

# Up to `count` distinct primary names close to `text`, for error messages.
function didyoumean(ds::Dataset, text::AbstractString; count::Int = 4)
    names = String[]
    base = normalize_name(text)
    for (id, _) in approximate_matches(name_index(ds.compounds), text)
        # Show the synonym that is closest to what was typed, not just the first one.
        synonyms = ds.compounds.names[id]
        name =
            isempty(synonyms) ? primary_name(ds.compounds, id) :
            argmin(s -> edit_distance(base, normalize_name(s), 64), synonyms)
        name in names || push!(names, "\"$name\"")
        length(names) >= count && break
    end
    return names
end

"""
    CompoundMatches

What [`find_compounds`](@ref) returns: the compounds found, as columns `id`, `name`
(the first name given by the sources), `formula`, `inchikey`, `points` (measurements in
systems that contain the compound) and `match` (`:exact`, `:contains` or `:similar`). It is
a Tables.jl table, and it can be passed as `component` to [`points`](@ref).
"""
struct CompoundMatches
    query::String
    id::Vector{Int32}
    name::Vector{String}
    formula::Vector{String}
    inchikey::Vector{String}
    points::Vector{Int}
    match::Vector{Symbol}
end

Base.length(m::CompoundMatches) = length(m.id)
Base.isempty(m::CompoundMatches) = isempty(m.id)

Tables.istable(::Type{CompoundMatches}) = true
Tables.columnaccess(::Type{CompoundMatches}) = true
Tables.columns(m::CompoundMatches) = (;
    id = m.id,
    name = m.name,
    formula = m.formula,
    inchikey = m.inchikey,
    points = m.points,
    match = m.match,
)
Tables.schema(m::CompoundMatches) = Tables.schema(Tables.columns(m))

function Base.show(io::IO, m::CompoundMatches)
    n = length(m)
    print(
        io,
        "CompoundMatches: ",
        n,
        n == 1 ? " compound" : " compounds",
        " for \"",
        m.query,
        "\"",
    )
    n == 0 && return nothing
    cells =
        [string.(m.id), m.name, m.formula, m.inchikey, string.(m.points), string.(m.match)]
    heads = ["id", "name", "formula", "InChIKey", "points", "match"]
    clip(s) = length(s) > 40 ? first(s, 37) * "..." : s
    cells = [clip.(c) for c in cells]
    widths = [max(length(h), maximum(length, c)) for (h, c) in zip(heads, cells)]
    println(io)
    println(io, join((rpad(h, w) for (h, w) in zip(heads, widths)), "  "))
    for i = 1:n
        println(io, join((rpad(c[i], w) for (c, w) in zip(cells, widths)), "  "))
    end
    return nothing
end

primary_name(t::CompoundTable, id::Integer) =
    isempty(t.names[id]) ? t.key[id] : first(t.names[id])

# Measurements in systems that contain each of the compounds `ids`.
function point_counts(ds::Dataset, ids::AbstractVector{Int32})
    position = Dict(id => i for (i, id) in enumerate(ids))
    ex = ds.experiments
    per_experiment = zeros(Int, length(ex))
    for e in ds.measurements.experiment
        per_experiment[e] += 1
    end
    counts = zeros(Int, length(ids))
    for e in eachindex(per_experiment)
        per_experiment[e] == 0 && continue
        for i = 1:Int(ex.ncomp[e])
            slot = get(position, ex.components[i][e], 0)
            slot == 0 || (counts[slot] += per_experiment[e])
        end
    end
    return counts
end

"""
    find_compounds(dataset, text; limit = 10) -> CompoundMatches

Find the compounds that `text` refers to, however it is spelled. Case, accents, hyphens
and spaces are ignored (`"Iso-Butane"` is `"isobutane"`), `"n-hexane"` also finds
`"hexane"`, and a short list of abbreviations and alternative spellings is understood
(`"IPA"`, `"sulphur"`, `"propylene"`). An InChIKey or a formula (`"N2"`) is matched as
written; a formula can be shared by several compounds (`"C4H10"` is butane and isobutane).

The result lists exact matches first (`:exact`), then names that contain the text or are
contained in it (`:contains`, so `"butane"` also lists `"isobutane"`), then names a few
spelling errors away (`:similar`). `points` tells how many measurements are in systems that
contain each compound, which shows at a glance which spelling is the one with data.

Pass the result as `component` to [`points`](@ref) to select every compound it lists, or
pick rows with `component = result.id[2]`.

```julia
find_compounds(db, "iso-butane")
points(db; component = find_compounds(db, "isobutane"; limit = 1))
```
"""
function find_compounds(ds::Dataset, text::AbstractString; limit::Int = 10)
    limit >= 1 || throw(ArgumentError("limit must be at least 1"))
    t = ds.compounds
    index = name_index(t)
    ids = Int32[]
    how = Symbol[]
    seen = Set{Int32}()
    function add!(id, kind)
        id in seen && return nothing
        push!(seen, id)
        push!(ids, id)
        push!(how, kind)
        return nothing
    end
    for id in identifier_matches(t, text)
        add!(id, :exact)
    end
    for id in lookup_names(index, text)
        add!(id, :exact)
    end
    for (id, kind) in approximate_matches(index, text)
        length(ids) >= limit && break
        add!(id, kind)
    end
    length(ids) > limit && (ids = ids[1:limit]; how = how[1:limit])
    counts = point_counts(ds, ids)
    return CompoundMatches(
        String(text),
        ids,
        [primary_name(t, i) for i in ids],
        t.formula[ids],
        t.inchikey[ids],
        counts,
        how,
    )
end
