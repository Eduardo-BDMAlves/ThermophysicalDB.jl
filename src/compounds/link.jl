# Linking the compound database to the ThermoML compounds.
#
# The ThermoML dataset is never changed by this: a link only says which row of the compound
# database describes a compound of the dataset, how it was found, and whether the two agree.
# When they do not, both are shown and the user decides which to use.

# Element counts of a plain formula such as "C2H6O" or "CaCl2", or `nothing` when the text
# has anything but element symbols and numbers (charges, hydrates, brackets).
function element_counts(formula::AbstractString)
    s = strip(formula)
    isempty(s) && return nothing
    counts = Dict{String,Int}()
    position = 1
    for m in eachmatch(r"([A-Z][a-z]?)(\d*)", s)
        m.offset == position || return nothing
        position = m.offset + length(m.match)
        counts[m.captures[1]] =
            get(counts, m.captures[1], 0) +
            (isempty(m.captures[2]) ? 1 : parse(Int, m.captures[2]))
    end
    position == lastindex(s) + 1 || return nothing
    return counts
end

"""
    compare_formulas(a, b) -> Symbol

`:same` when both formulas have the same elements and counts (`"C2H6O"` and `"H6C2O"` are the
same), `:different` when they do not, and `:unknown` when one is missing or is not a plain
formula (a charge, a hydrate), which is compared only as written.
"""
function compare_formulas(a::AbstractString, b::AbstractString)
    (isempty(strip(a)) || isempty(strip(b))) && return :unknown
    strip(a) == strip(b) && return :same
    x, y = element_counts(a), element_counts(b)
    (x === nothing || y === nothing) && return :unknown
    return x == y ? :same : :different
end

# The layers of an InChI that describe the skeleton: everything except the stereochemistry
# (/b /t /m /s) and the isotopes (/i).
function inchi_skeleton(body::AbstractString)
    layers = split(body, '/')
    return join(
        (l for l in layers if isempty(l) || first(l) ∉ ('b', 't', 'm', 's', 'i')),
        '/',
    )
end

"""
    compare_inchis(a, b) -> Symbol

`:same` when the two InChIs are the same, `:stereo` when they differ only in the
stereochemistry or the isotopes (the same skeleton: `(E)-3-hexene` and `(Z)-3-hexene`,
`H2O` and `D2O`), `:different` when the skeletons differ and `:unknown` when one is missing.
The prefix `InChI=1S/` is ignored.
"""
function compare_inchis(a::AbstractString, b::AbstractString)
    x, y = inchi_body(a), inchi_body(b)
    (isempty(x) || isempty(y)) && return :unknown
    x == y && return :same
    return inchi_skeleton(x) == inchi_skeleton(y) ? :stereo : :different
end

"""
    CompoundLinks

What [`link_compounds`](@ref) returns: one row for each pair (ThermoML compound, compound of the
database that may describe it). `compound` is the identifier in the dataset (`0` in `record`
when nothing was found), `via` tells how it was found (`:inchikey`, `:inchi`, `:name` or
`:none`), `candidates` counts the rows that the compound has (more than one means the user has
to choose), `formula_check` compares the formula of the dataset with that of the database
(`:same`, `:different` or `:unknown`) and `inchi_check` compares the InChI (`:same`,
`:stereo` when only the stereochemistry or the isotopes differ, `:different` or `:unknown`).
It is a Tables.jl table.
"""
struct CompoundLinks
    compound::Vector{Int32}
    name::Vector{String}
    inchikey::Vector{String}
    formula::Vector{String}
    record::Vector{Int32}
    record_name::Vector{String}
    record_cas::Vector{String}
    record_cid::Vector{Int64}
    record_formula::Vector{String}
    molar_mass::Vector{Float64}
    via::Vector{Symbol}
    candidates::Vector{Int}
    formula_check::Vector{Symbol}
    inchi_check::Vector{Symbol}
end

Base.length(l::CompoundLinks) = length(l.compound)

Tables.istable(::Type{CompoundLinks}) = true
Tables.columnaccess(::Type{CompoundLinks}) = true
function Tables.columns(l::CompoundLinks)
    return NamedTuple{fieldnames(CompoundLinks)}(
        ntuple(i -> getfield(l, i), fieldcount(CompoundLinks)),
    )
end
Tables.schema(l::CompoundLinks) = Tables.schema(Tables.columns(l))

function Base.show(io::IO, l::CompoundLinks)
    n = length(unique(l.compound))
    linked = length(unique(l.compound[l.record .!= 0]))
    ambiguous = length(unique(l.compound[l.candidates .> 1]))
    return print(
        io,
        "CompoundLinks: ",
        linked,
        " of ",
        n,
        " compounds of the dataset found in the compound database (",
        ambiguous,
        " with more than one candidate)",
    )
end

"""
    link_compounds(ds, db) -> CompoundLinks

Match every compound of the ThermoML dataset `ds` with the compound database `db`. The
InChIKey is tried first, then the InChI, then the names (with the usual spelling variants).
A compound with several candidates gets one row for each, and one found only by name is
marked `via = :name`, because a name can describe more than one species: trust such a link only
when `formula_check` and `inchi_check` are `:same`, and treat `:stereo` (the same skeleton with
other stereochemistry or isotopes) and `:different` (a hydrate and its anhydrous salt, for
example) as a related compound, not as the same one. `by_name = false` links by InChIKey and
InChI only. The dataset is not modified.

```julia
db = database()
cdb = compound_database()
links = link_compounds(db, cdb)
```
"""
function link_compounds(ds::Dataset, db::CompoundDB; by_name::Bool = true)
    t = ds.compounds
    ex = exact_index(db)
    names = name_index(db)
    out = (
        compound = Int32[],
        name = String[],
        inchikey = String[],
        formula = String[],
        record = Int32[],
        record_name = String[],
        record_cas = String[],
        record_cid = Int64[],
        record_formula = String[],
        molar_mass = Float64[],
        via = Symbol[],
        candidates = Int[],
        formula_check = Symbol[],
        inchi_check = Symbol[],
    )
    for c in eachindex(t.key)
        ids = Int32[]
        via = :none
        if !isempty(t.inchikey[c])
            ids = get(ex.inchikey, uppercase(t.inchikey[c]), Int32[])
            isempty(ids) || (via = :inchikey)
        end
        if isempty(ids) && !isempty(t.inchi[c])
            ids = get(ex.inchi, inchi_body(t.inchi[c]), Int32[])
            isempty(ids) || (via = :inchi)
        end
        if isempty(ids) && by_name
            found = Int32[]
            for name in t.names[c]
                append!(found, lookup_names(names, name))
            end
            if !isempty(found)
                ids = sort!(unique!(found))
                via = :name
            end
        end
        name = primary_name(t, c)
        rows = isempty(ids) ? Int32[0] : ids
        for r in rows
            push!(out.compound, Int32(c))
            push!(out.name, name)
            push!(out.inchikey, t.inchikey[c])
            push!(out.formula, t.formula[c])
            push!(out.record, r)
            push!(out.record_name, r == 0 ? "" : primary_name(db, r))
            push!(out.record_cas, r == 0 ? "" : db.cas[r])
            push!(out.record_cid, r == 0 ? Int64(-1) : db.cid[r])
            push!(out.record_formula, r == 0 ? "" : db.formula[r])
            push!(out.molar_mass, r == 0 ? NaN : db.molar_mass[r])
            push!(out.via, via)
            push!(out.candidates, length(ids))
            push!(
                out.formula_check,
                r == 0 ? :unknown : compare_formulas(t.formula[c], db.formula[r]),
            )
            push!(
                out.inchi_check,
                r == 0 ? :unknown : compare_inchis(t.inchi[c], db.inchi[r]),
            )
        end
    end
    return CompoundLinks(
        out.compound,
        out.name,
        out.inchikey,
        out.formula,
        out.record,
        out.record_name,
        out.record_cas,
        out.record_cid,
        out.record_formula,
        out.molar_mass,
        out.via,
        out.candidates,
        out.formula_check,
        out.inchi_check,
    )
end

"""
    find_compounds(dataset, db, text; limit = 10) -> CompoundMatches

[`find_compounds`](@ref) that also understands what the compound database knows: a CAS
number, a PubChem CID, an InChI, a SMILES (`"SMILES=..."`) or any synonym of a compound
leads to the ThermoML compounds with the same InChIKey. A ThermoML compound that has no
InChIKey is reached only through the names it has itself, so nothing is guessed. What the
ordinary search finds comes after.

```julia
find_compounds(db, cdb, "7732-18-5")        # water, from its CAS number
find_compounds(db, cdb, "oxidane")          # from a synonym that no article used
```
"""
function find_compounds(ds::Dataset, db::CompoundDB, text::AbstractString; limit::Int = 10)
    limit >= 1 || throw(ArgumentError("limit must be at least 1"))
    t = ds.compounds
    ids = Int32[]
    seen = Set{Int32}()
    for r in lookup_compounds(db, text; limit = max(limit, 25)).id
        key = db.inchikey[r]
        isempty(key) && continue
        id = get(t.index, key, NO_ID)
        id != NO_ID && !(id in seen) && (push!(seen, id); push!(ids, id))
    end
    plain = find_compounds(ds, text; limit)
    for id in plain.id
        id in seen || (push!(seen, id); push!(ids, id))
    end
    isempty(ids) && return plain
    length(ids) > limit && (ids = ids[1:limit])
    how = Symbol[
        id in plain.id ? plain.match[findfirst(==(id), plain.id)] : :exact for id in ids
    ]
    return CompoundMatches(
        String(text),
        ids,
        [primary_name(t, i) for i in ids],
        t.formula[ids],
        t.inchikey[ids],
        point_counts(ds, ids),
        how,
    )
end
