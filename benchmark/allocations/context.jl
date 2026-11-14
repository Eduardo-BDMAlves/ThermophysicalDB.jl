# The data the scenarios run on: the synthetic database of the benchmarks (fast, the same for every
# revision, usable in a workflow) or the real ThermoML archive of this computer (the numbers that
# matter). Both give the same `Context`, so a scenario is written once.

using ThermophysicalDB: ThermophysicalDB
const T = ThermophysicalDB

"""
    Context

What the scenarios use: the database `db` (and `linked`, the same with a compound database), a
compound (`key`, and `name`, a synonym that only the linked database knows), a `property` and the
ranges of temperature (K) and pressure (kPa) that have points; `whole` is every point of the
property, `outlier_set` the pure-compound points of the property; `pair` is the two compounds of
one binary system. `path` is the stored file of the synthetic database (`nothing` for the real
one).
"""
struct Context
    kind::Symbol
    label::String
    db::Any
    linked::Any
    compounds::Any
    key::String
    name::String
    property::String
    temperature::Tuple{Float64,Float64}
    pressure::Tuple{Float64,Float64}
    path::Union{Nothing,String}
    whole::Any
    outlier_set::Any
    doi::String
    author::String
    year::Tuple{Int,Int}
    pair::Union{Nothing,Tuple{Int,Int}}
    assets::String
end

# The first reference with a DOI and an author, a binary system, and the dataset they come from.
function find_examples(db)
    ds = T.member_dataset(db.members[1])
    rf, ex = ds.references, ds.experiments
    r = findfirst(i -> !isempty(rf.doi[i]) && !isempty(rf.authors[i]), eachindex(rf.doi))
    r === nothing && error("the database has no reference with a DOI and an author")
    author = strip(first(split(first(rf.authors[r]), ",")))
    e = findfirst(==(2), ex.ncomp)
    pair = e === nothing ? nothing : (Int(ex.components[1][e]), Int(ex.components[2][e]))
    return (; doi = rf.doi[r], author = String(author), pair)
end

# ----------------------------------------------------------------------------------
# The synthetic database
# ----------------------------------------------------------------------------------

include(joinpath(dirname(@__DIR__), "data.jl"))

function synthetic_context(scale::Symbol)
    prepared = prepared_database(T; scale)
    db = T.Database([T.Member(BENCH_MEMBER; kind = :user, path = String(prepared.path))])
    compounds = Synthetic.compound_database()
    linked = T.link_compounds(db, compounds)
    temperature, pressure = (300.0, 400.0), (100.0, 30000.0)
    chosen = nothing
    for i = 1:Synthetic.COMPOUND_COUNT, (property,) in Synthetic.PROPERTIES
        try
            v = T.points(
                db;
                component = Synthetic.inchikey(i),
                property,
                temperature,
                pressure,
            )
            if length(v) >= 30
                chosen = (; key = Synthetic.inchikey(i), index = i, property)
                break
            end
        catch err
            err isa ArgumentError || rethrow()
        end
    end
    chosen === nothing &&
        error("the synthetic database has no compound with points in the ranges")
    example = find_examples(db)
    whole = T.points(db; property = chosen.property)
    return Context(
        :synthetic,
        string("synthetic ", scale, " ", data_key(T, scale)),
        db,
        linked,
        compounds,
        chosen.key,
        string("synthetic compound ", chosen.index),
        chosen.property,
        temperature,
        pressure,
        String(prepared.path),
        whole,
        T.points(db; property = chosen.property, pure = true),
        example.doi,
        example.author,
        (1995, 2005),
        example.pair,
        joinpath(pkgdir(T), "docs", "src", "assets"),
    )
end

# ----------------------------------------------------------------------------------
# The real archive
# ----------------------------------------------------------------------------------

function real_context()
    db = T.database(; progress = false)
    compounds = T.compound_database(; progress = false)
    key = get(ENV, "TDB_ALLOC_COMPONENT", "hexane")
    property = get(ENV, "TDB_ALLOC_PROPERTY", "Thermal conductivity")
    temperature, pressure = (273.15, 373.15), (90.0, 110.0)
    linked = try
        T.link_compounds(db, compounds)
    catch err
        err isa InterruptException && rethrow()
        @warn "link_compounds failed; the scenarios of the linked database are left out" reason =
            sprint(showerror, err)
        nothing
    end
    example = find_examples(db)
    ds = T.member_dataset(db.members[1])
    return Context(
        :real,
        string("real archive ", length(ds.measurements), " points"),
        db,
        linked,
        compounds,
        key,
        key,
        property,
        temperature,
        pressure,
        nothing,
        T.points(db; property),
        T.points(db; property, pure = true),
        example.doi,
        example.author,
        (2000, 2010),
        example.pair,
        joinpath(pkgdir(T), "docs", "src", "assets"),
    )
end
