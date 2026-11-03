# The compound database: one row per chemical species, with every way of naming it.
#
# It is separate from the ThermoML dataset on purpose. The ThermoML archive stays exactly as
# NIST publishes it; this table only helps to find, identify and complete compounds, and it is
# linked to the dataset by the InChIKey (see `link_compounds`). Each row keeps where it came
# from (`source`, and `retrieved` for data fetched later) and whether the user added or
# changed it (`custom`).

const COMPOUNDS_FORMAT = "thermophysicaldb-compounds"
const COMPOUNDS_SCHEMA_VERSION = 1

"""
    ExactIndex

Hash lookups of the identifiers that are matched as written: InChIKey, CAS number, PubChem
CID, InChI (without its `InChI=1S/` prefix), SMILES and formula. Derived data, rebuilt on
first use after the table changed.
"""
struct ExactIndex
    ncompounds::Int
    inchikey::Dict{String,Vector{Int32}}
    cas::Dict{String,Vector{Int32}}
    cid::Dict{Int64,Vector{Int32}}
    inchi::Dict{String,Vector{Int32}}
    smiles::Dict{String,Vector{Int32}}
    formula::Dict{String,Vector{Int32}}
end

"""
    CompoundDB

The compound database returned by [`compound_database`](@ref). Columns: `inchikey`, `cas`,
`cid` (PubChem CID, `-1` when unknown), `formula`, `molar_mass` (g/mol, `NaN` when unknown),
`smiles`, `inchi`, `iupac`, `names` (the first is the common name), `source` and `retrieved`.
"""
struct CompoundDB
    key::Vector{String}
    inchikey::Vector{String}
    inchi::Vector{String}
    cas::Vector{String}
    cid::Vector{Int64}
    formula::Vector{String}
    molar_mass::Vector{Float64}
    smiles::Vector{String}
    iupac::Vector{String}
    names::Vector{Vector{String}}
    source::Vector{String}
    retrieved::Vector{String}
    custom::Vector{Bool}
    index::Dict{String,Int32}
    lookup::Base.RefValue{Union{Nothing,NameIndex}}
    exact::Base.RefValue{Union{Nothing,ExactIndex}}
    meta::Dict{String,Any}
end

function CompoundDB()
    return CompoundDB(
        String[],
        String[],
        String[],
        String[],
        Int64[],
        String[],
        Float64[],
        String[],
        String[],
        Vector{String}[],
        String[],
        String[],
        Bool[],
        Dict{String,Int32}(),
        Ref{Union{Nothing,NameIndex}}(nothing),
        Ref{Union{Nothing,ExactIndex}}(nothing),
        Dict{String,Any}(),
    )
end

Base.length(db::CompoundDB) = length(db.key)

function Base.show(io::IO, db::CompoundDB)
    return print(
        io,
        "CompoundDB: ",
        length(db),
        " compounds, ",
        count(db.custom),
        " added or changed by the user",
    )
end

# ----------------------------------------------------------------------------------
# Normalising identifiers
# ----------------------------------------------------------------------------------

const CAS_REGEX = r"^\d{2,7}-\d{2}-\d$"
const INCHIKEY_REGEX = r"^[A-Z]{14}-[A-Z]{10}-[A-Z]$"

"The CAS number written as `digits-digits-digit`, or `\"\"` when `text` is not one."
function normalize_cas(text::AbstractString)::String
    s = strip(text)
    return occursin(CAS_REGEX, s) ? String(s) : ""
end

"The InChI without its `InChI=1S/` (or `InChI=1/`) prefix, which is what is compared."
function inchi_body(text::AbstractString)::String
    s = strip(text)
    startswith(s, "InChI=") || return String(s)
    slash = findfirst('/', s)
    slash === nothing && return ""
    return String(s[(slash+1):end])
end

# The identifier lists write the InChI without its prefix; the ThermoML archive and PubChem
# write it in full. The database keeps the full form.
function full_inchi(text::AbstractString)::String
    s = strip(text)
    isempty(s) && return ""
    return startswith(s, "InChI=") ? String(s) : "InChI=1S/" * s
end

# ----------------------------------------------------------------------------------
# Adding and merging rows
# ----------------------------------------------------------------------------------

# The first name given becomes the primary name when `front` is set; the others are added
# after the names that are already there. Names that are already there are not repeated.
function merge_names!(list::Vector{String}, names, front::Bool)
    given = String[n for n in names if !isempty(n)]
    isempty(given) && return list
    if front
        head = first(given)
        filter!(!=(head), list)
        pushfirst!(list, head)
        popfirst!(given)
    end
    for n in given
        n in list || push!(list, n)
    end
    return list
end

"""
    insert_record!(db; names, inchikey, ..., source, override = false) -> Int32

Add a compound, or merge it into the row that has the same identity key (the InChIKey, or
the first name when there is none). The values that are already there are kept unless
`override` is set; empty values never replace anything. The names of both are kept.
"""
function insert_record!(
    db::CompoundDB;
    inchikey::AbstractString = "",
    inchi::AbstractString = "",
    cas::AbstractString = "",
    cid::Integer = -1,
    formula::AbstractString = "",
    molar_mass::Real = NaN,
    smiles::AbstractString = "",
    iupac::AbstractString = "",
    names::AbstractVector{<:AbstractString} = String[],
    source::AbstractString = "user",
    retrieved::AbstractString = "",
    custom::Bool = false,
    override::Bool = false,
)
    inchikey = String(strip(inchikey))
    names = String[strip(n) for n in names if !isempty(strip(n))]
    key = compound_key(inchikey, names)
    inchi = full_inchi(inchi)
    cas = normalize_cas(cas)
    db.exact[] = nothing
    db.lookup[] = nothing
    id = get(db.index, key, NO_ID)
    if id != NO_ID
        take(old, new) = (isempty(new) || (!override && !isempty(old))) ? old : new
        db.inchi[id] = take(db.inchi[id], inchi)
        db.cas[id] = take(db.cas[id], cas)
        db.formula[id] = take(db.formula[id], String(formula))
        db.smiles[id] = take(db.smiles[id], String(smiles))
        db.iupac[id] = take(db.iupac[id], String(iupac))
        db.retrieved[id] = take(db.retrieved[id], String(retrieved))
        if cid > 0 && (override || db.cid[id] <= 0)
            db.cid[id] = Int64(cid)
        end
        if isfinite(molar_mass) && (override || !isfinite(db.molar_mass[id]))
            db.molar_mass[id] = Float64(molar_mass)
        end
        merge_names!(db.names[id], names, override)
        custom && (db.custom[id] = true)
        return id
    end
    push!(db.key, key)
    push!(db.inchikey, inchikey)
    push!(db.inchi, inchi)
    push!(db.cas, cas)
    push!(db.cid, Int64(cid))
    push!(db.formula, String(formula))
    push!(db.molar_mass, Float64(molar_mass))
    push!(db.smiles, String(smiles))
    push!(db.iupac, String(iupac))
    push!(db.names, merge_names!(String[], names, false))
    push!(db.source, String(source))
    push!(db.retrieved, String(retrieved))
    push!(db.custom, custom)
    id = Int32(length(db.key))
    db.index[key] = id
    return id
end

# ----------------------------------------------------------------------------------
# Indexes
# ----------------------------------------------------------------------------------

function add_to!(dict::Dict{K,Vector{Int32}}, key::K, id::Int32) where {K}
    list = get!(dict, key, Int32[])
    (isempty(list) || last(list) != id) && push!(list, id)
    return nothing
end

function build_exact_index(db::CompoundDB)
    inchikey = Dict{String,Vector{Int32}}()
    cas = Dict{String,Vector{Int32}}()
    cid = Dict{Int64,Vector{Int32}}()
    inchi = Dict{String,Vector{Int32}}()
    smiles = Dict{String,Vector{Int32}}()
    formula = Dict{String,Vector{Int32}}()
    for c in eachindex(db.key)
        id = Int32(c)
        isempty(db.inchikey[c]) || add_to!(inchikey, uppercase(db.inchikey[c]), id)
        isempty(db.cas[c]) || add_to!(cas, db.cas[c], id)
        db.cid[c] > 0 && add_to!(cid, db.cid[c], id)
        isempty(db.inchi[c]) || add_to!(inchi, inchi_body(db.inchi[c]), id)
        isempty(db.smiles[c]) || add_to!(smiles, db.smiles[c], id)
        isempty(db.formula[c]) || add_to!(formula, db.formula[c], id)
    end
    return ExactIndex(length(db), inchikey, cas, cid, inchi, smiles, formula)
end

function exact_index(db::CompoundDB)
    index = db.exact[]
    if index === nothing || index.ncompounds != length(db)
        index = build_exact_index(db)
        db.exact[] = index
    end
    return index
end

function name_index(db::CompoundDB)
    nnames = sum(length, db.names; init = 0)
    index = db.lookup[]
    if index === nothing || index.ncompounds != length(db) || index.nnames != nnames
        index = build_name_index(db.names)
        db.lookup[] = index
    end
    return index
end

# ----------------------------------------------------------------------------------
# Looking a compound up
# ----------------------------------------------------------------------------------

"""
    CompoundRecords

What [`lookup_compounds`](@ref) returns: the compounds found, as columns `id`, `name`,
`cas`, `cid`, `formula`, `molar_mass` (g/mol), `inchikey`, `source` and `match` (how the
text was matched: `:inchikey`, `:inchi`, `:cas`, `:cid`, `:smiles`, `:formula`, `:name`,
`:contains` or `:similar`). It is a Tables.jl table.
"""
struct CompoundRecords
    query::String
    id::Vector{Int32}
    name::Vector{String}
    cas::Vector{String}
    cid::Vector{Int64}
    formula::Vector{String}
    molar_mass::Vector{Float64}
    inchikey::Vector{String}
    source::Vector{String}
    match::Vector{Symbol}
end

Base.length(r::CompoundRecords) = length(r.id)
Base.isempty(r::CompoundRecords) = isempty(r.id)

Tables.istable(::Type{CompoundRecords}) = true
Tables.columnaccess(::Type{CompoundRecords}) = true
Tables.columns(r::CompoundRecords) = (;
    id = r.id,
    name = r.name,
    cas = r.cas,
    cid = r.cid,
    formula = r.formula,
    molar_mass = r.molar_mass,
    inchikey = r.inchikey,
    source = r.source,
    match = r.match,
)
Tables.schema(r::CompoundRecords) = Tables.schema(Tables.columns(r))

function Base.show(io::IO, r::CompoundRecords)
    n = length(r)
    print(
        io,
        "CompoundRecords: ",
        n,
        n == 1 ? " compound" : " compounds",
        " for \"",
        r.query,
        "\"",
    )
    n == 0 && return nothing
    cells = [
        string.(r.id),
        r.name,
        r.cas,
        [c > 0 ? string(c) : "" for c in r.cid],
        r.formula,
        [isfinite(m) ? string(round(m; digits = 4)) : "" for m in r.molar_mass],
        r.inchikey,
        string.(r.match),
    ]
    heads = ["id", "name", "CAS", "CID", "formula", "g/mol", "InChIKey", "match"]
    clip(s) = length(s) > 30 ? first(s, 27) * "..." : s
    cells = [clip.(c) for c in cells]
    widths = [max(length(h), maximum(length, c)) for (h, c) in zip(heads, cells)]
    println(io)
    println(io, join((rpad(h, w) for (h, w) in zip(heads, widths)), "  "))
    for i = 1:n
        println(io, join((rpad(c[i], w) for (c, w) in zip(cells, widths)), "  "))
    end
    return nothing
end

primary_name(db::CompoundDB, id::Integer) =
    isempty(db.names[id]) ? db.key[id] : first(db.names[id])

"The kind of identifier that `text` is, judging only by how it is written."
function identifier_kind(text::AbstractString)::Symbol
    s = strip(text)
    startswith(lowercase(s), "inchi=") && return :inchi
    startswith(lowercase(s), "smiles=") && return :smiles
    occursin(INCHIKEY_REGEX, uppercase(s)) && return :inchikey
    occursin(CAS_REGEX, s) && return :cas
    return :name
end

function matches_by(db::CompoundDB, text::AbstractString, by::Symbol)
    s = String(strip(text))
    ex = exact_index(db)
    found = Int32[]
    kinds = Symbol[]
    function add!(ids, kind)
        for id in ids
            id in found && continue
            push!(found, id)
            push!(kinds, kind)
        end
        return nothing
    end
    if by == :inchikey
        add!(get(ex.inchikey, uppercase(s), Int32[]), :inchikey)
    elseif by == :cas
        add!(get(ex.cas, normalize_cas(s), Int32[]), :cas)
    elseif by == :cid
        cid = tryparse(Int64, replace(s, r"^(?i:cid)\s*:?\s*" => ""))
        cid === nothing || add!(get(ex.cid, cid, Int32[]), :cid)
    elseif by == :inchi
        add!(get(ex.inchi, inchi_body(s), Int32[]), :inchi)
    elseif by == :smiles
        add!(get(ex.smiles, replace(s, r"^(?i:smiles)=" => ""), Int32[]), :smiles)
    elseif by == :formula
        add!(get(ex.formula, s, Int32[]), :formula)
    elseif by == :name
        add!(lookup_names(name_index(db), s), :name)
    else
        throw(
            ArgumentError(
                "unknown identifier kind $(repr(by)); use :auto, :name, :cas, :cid, :inchikey, :inchi, :smiles or :formula",
            ),
        )
    end
    return found, kinds
end

"""
    lookup_compounds(db, text; by = :auto, limit = 10) -> CompoundRecords

Find the compounds that `text` identifies. With `by = :auto` the kind of identifier is
recognised from how it is written: an InChIKey, a CAS number (`"7732-18-5"`), a text that
starts with `InChI=`, or one that starts with `SMILES=`; anything else is a name, a PubChem
CID (digits only) or a formula, tried in that order. Pass `by` (`:name`, `:cas`, `:cid`,
`:inchikey`, `:inchi`, `:smiles`, `:formula`) to say what it is: a SMILES or a number cannot
be told from a name by looking at it. Identifiers are compared as written (a SMILES is not
canonicalised, and a formula must be written as the database writes it). Names follow the
same rules as [`find_compounds`](@ref): case, accents, hyphens and spaces are ignored,
and when nothing matches, names that contain the text or are close to it are listed.

```julia
cdb = compound_database()
lookup_compounds(cdb, "7732-18-5")      # by CAS number
lookup_compounds(cdb, "cesium formate")  # by name
lookup_compounds(cdb, "CO"; by = :smiles)
```
"""
function lookup_compounds(
    db::CompoundDB,
    text::AbstractString;
    by::Symbol = :auto,
    limit::Int = 10,
)
    limit >= 1 || throw(ArgumentError("limit must be at least 1"))
    s = String(strip(text))
    ids = Int32[]
    how = Symbol[]
    if by == :auto
        kind = identifier_kind(s)
        if kind == :name
            f, k = matches_by(db, s, :name)
            append!(ids, f)
            append!(how, k)
            if all(isdigit, s) && !isempty(s)
                f, k = matches_by(db, s, :cid)
                for (id, kd) in zip(f, k)
                    id in ids || (push!(ids, id); push!(how, kd))
                end
            end
            f, k = matches_by(db, s, :formula)
            for (id, kd) in zip(f, k)
                id in ids || (push!(ids, id); push!(how, kd))
            end
        else
            f, k = matches_by(db, s, kind)
            append!(ids, f)
            append!(how, k)
        end
    else
        f, k = matches_by(db, s, by)
        append!(ids, f)
        append!(how, k)
    end
    # Only a name can be misspelled: offer close names when nothing matched.
    if isempty(ids) && (by == :auto && identifier_kind(s) == :name || by == :name)
        for (id, kind) in approximate_matches(name_index(db), s)
            length(ids) >= limit && break
            id in ids || (push!(ids, id); push!(how, kind))
        end
    end
    length(ids) > limit && (ids = ids[1:limit]; how = how[1:limit])
    return CompoundRecords(
        s,
        ids,
        [primary_name(db, i) for i in ids],
        db.cas[ids],
        db.cid[ids],
        db.formula[ids],
        db.molar_mass[ids],
        db.inchikey[ids],
        db.source[ids],
        how,
    )
end

"""
    compound_record(db, id) -> NamedTuple

Everything the database knows about compound number `id` (a value of the `id` column of
[`lookup_compounds`](@ref)), including all its names.
"""
function compound_record(db::CompoundDB, id::Integer)
    1 <= id <= length(db) || throw(BoundsError(db, id))
    return (;
        id = Int32(id),
        names = copy(db.names[id]),
        iupac = db.iupac[id],
        cas = db.cas[id],
        cid = db.cid[id],
        formula = db.formula[id],
        molar_mass = db.molar_mass[id],
        smiles = db.smiles[id],
        inchi = db.inchi[id],
        inchikey = db.inchikey[id],
        source = db.source[id],
        retrieved = db.retrieved[id],
        custom = db.custom[id],
    )
end

"""
    register_compound!(db; names, inchikey = "", cas = "", cid = -1, formula = "",
                       molar_mass = NaN, smiles = "", inchi = "", iupac = "",
                       save = false, dir = nothing) -> Int32

Add a compound of your own, or complete one that is already there (found by its InChIKey,
or by its first name when you give none): what you give replaces what the row had, and
your names go first. `molar_mass` is in g/mol. The row is marked as yours, so that it
survives an update of the list, and it is stored by [`save_compounds`](@ref).

By default the database is changed only in the session. With `save = true` the compounds
that are yours (this one and the ones added before) are written at once to the file of your
own compounds, which `compound_database()` lays over the lists in every session. `dir` is
the folder to write to; by default it is the one the database was loaded from. The lists
themselves are never changed.
"""
function register_compound!(
    db::CompoundDB;
    names::AbstractVector{<:AbstractString},
    save::Bool = false,
    dir::Union{Nothing,AbstractString} = nothing,
    kwargs...,
)
    id = insert_record!(
        db;
        names,
        source = "user",
        custom = true,
        override = true,
        kwargs...,
    )
    if save
        folder = dir === nothing ? get(db.meta, "dir", compounds_dir()) : dir
        save_compounds(db; dir = folder)
    end
    return id
end
