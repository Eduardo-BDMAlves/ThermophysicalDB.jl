# Several databases that look like one. A `Database` keeps its members in order of priority and the
# registry that maps their identifiers to global ones; the dataset of a member is read only when a
# query can find something in it.

"""
    Database

The databases that a user works with as one: the ThermoML archive (`:thermoml`), literature
points (`:literature`) and the user's own measurements (`:user`), each a [`Member`](@ref) with
its own file. [`database`](@ref) returns it. [`points`](@ref) asks every member that can answer
and returns a [`DatabaseView`](@ref); [`members`](@ref), [`add_member!`](@ref) and
[`remove_member!`](@ref) manage the members, and [`member_dataset`](@ref) gives the
[`Dataset`](@ref) of one of them. The members are independent: none changes another.
"""
mutable struct Database
    members::Vector{Member}
    registry::Registry
end

function build_registry(members::AbstractVector{Member})
    return build_registry(
        String[m.name for m in members],
        Catalog[member_catalog(m) for m in members],
    )
end

function Database(members::AbstractVector{Member})
    names = [m.name for m in members]
    allunique(names) ||
        throw(ArgumentError("the databases need different names, got $names"))
    ordered = sort(collect(members); by = m -> m.priority)
    return Database(ordered, build_registry(ordered))
end

Database(ds::Dataset; name::AbstractString = "thermoml", kind::Symbol = :thermoml) =
    Database([Member(name; kind, dataset = ds)])

Base.length(db::Database) = sum(m -> length(member_dataset(m).measurements), db.members)
Base.isempty(db::Database) = isempty(db.members)

"""
    members(db) -> Vector{Member}

The databases of `db`, first the one that wins when a point is in several.
"""
members(db::Database) = db.members

function member_index(db::Database, name::AbstractString)
    i = findfirst(m -> m.name == name, db.members)
    i === nothing && throw(
        ArgumentError(
            "no database called \"$name\"; the databases are $(join(repr.(m.name for m in db.members), ", "))",
        ),
    )
    return i
end

member_dataset(db::Database, name::AbstractString) =
    member_dataset(db.members[member_index(db, name)])

"""
    add_member!(db, member) -> Database

Add a database. Its name must be new; the order of the members follows their priority.
"""
function add_member!(db::Database, member::Member)
    any(m -> m.name == member.name, db.members) &&
        throw(ArgumentError("there is already a database called \"$(member.name)\""))
    push!(db.members, member)
    sort!(db.members; by = m -> m.priority)
    db.registry = build_registry(db.members)
    return db
end

"""
    remove_member!(db, name) -> Database

Take a database out of `db` (its file is not touched).
"""
function remove_member!(db::Database, name::AbstractString)
    deleteat!(db.members, member_index(db, name))
    db.registry = build_registry(db.members)
    return db
end

# Number of points of a member: from its dataset when it is read, otherwise from one small column of
# its file (the dataset is not read for this).
function member_points(m::Member)
    is_open(m) && return length(m.dataset.measurements)
    return JLD2.jldopen(path -> length(path["measurements/property"]), m.path, "r")
end

function group_digits(n::Integer)
    digits = string(n)
    return replace(digits, r"(?<=\d)(?=(\d{3})+$)" => ",")
end

function Base.show(io::IO, ::MIME"text/plain", db::Database)
    n = length(db.members)
    println(io, "Database: ", n, n == 1 ? " database" : " databases")
    n == 0 && return nothing
    headers = [
        "database",
        "kind",
        "priority",
        "points",
        "references",
        "compounds",
        "properties",
        "state",
    ]
    rows = map(db.members) do m
        cat = member_catalog(m)
        [
            m.name,
            String(m.kind),
            string(m.priority),
            group_digits(member_points(m)),
            group_digits(length(cat.doi)),
            group_digits(length(cat.compound_key)),
            group_digits(length(cat.property_label)),
            is_open(m) ? "read" : "not read",
        ]
    end
    left = Set([1, 2, 8])
    widths = [
        max(length(headers[j]), maximum(length(r[j]) for r in rows)) for
        j in eachindex(headers)
    ]
    pad(text, j) = j in left ? rpad(text, widths[j]) : lpad(text, widths[j])
    println(io, rstrip(join((pad(headers[j], j) for j in eachindex(headers)), "  ")))
    println(io, join((repeat("─", w) for w in widths), "  "))
    for r in rows
        println(io, rstrip(join((pad(r[j], j) for j in eachindex(headers)), "  ")))
    end
    return nothing
end

function Base.show(io::IO, db::Database)
    print(io, "Database(", length(db.members), " databases")
    for m in db.members
        print(
            io,
            "\n  ",
            rpad(m.name, 20),
            rpad(m.kind, 12),
            m.priority,
            "  ",
            is_open(m) ? "open" : "not read",
        )
    end
    return print(io, ")")
end

# ----------------------------------------------------------------------------------
# Which members can answer
# ----------------------------------------------------------------------------------

# The global compounds that the text names exactly (name, InChIKey or formula), as the registry
# knows them; empty when nothing names it exactly, and then no member is left out.
function registered_compounds(reg::Registry, text::AbstractString)
    found = Int32[]
    append!(found, get(reg.name_index, normalize_name(text), Int32[]))
    append!(found, get(reg.name_index, lowercase(strip(text)), Int32[]))
    return unique!(found)
end

# The members that can hold a point that matches, from their catalogs alone. A member is left out
# only when the catalog proves it has nothing to match; whatever cannot be told here (a pattern,
# a text that no member knows exactly) leaves every member in.
function candidate_members(
    db::Database,
    component,
    match::Symbol,
    exact::Bool,
    property,
    doi,
)
    reg = db.registry
    keep = trues(length(db.members))
    if doi isa AbstractString
        g = get(reg.doi_index, lowercase(doi), Int32(0))
        for m in eachindex(keep)
            keep[m] &= g != 0 && reg.has_reference[m][g]
        end
    end
    if property isa AbstractString
        globals = get(reg.label_index, lowercase(strip(property)), Int32[])
        for m in eachindex(keep)
            keep[m] &= any(g -> reg.has_property[m][g], globals)
        end
    end
    texts = if component isa AbstractString
        [component]
    elseif component isa AbstractVector && all(c -> c isa AbstractString, component)
        component
    else
        nothing
    end
    if texts !== nothing
        groups = [registered_compounds(reg, t) for t in texts]
        if !isempty(groups) && all(!isempty, groups)
            for m in eachindex(keep)
                has = [any(g -> reg.has_compound[m][g], group) for group in groups]
                keep[m] &= (exact || match === :all) ? all(has) : any(has)
            end
        end
    end
    return findall(keep)
end

# A component in the identifiers of member `m`: texts are the same everywhere, the result of
# `find_compounds(db, ...)` carries global identifiers and is translated. `nothing` when the
# member does not have it.
function member_component(reg::Registry, m::Integer, component)
    component isa AbstractString && return component
    if component isa CompoundMatches
        locals = local_compounds(reg, m, component.id)
        isempty(locals) && return nothing
        n = length(locals)
        return CompoundMatches(
            component.query,
            locals,
            fill("", n),
            fill("", n),
            fill("", n),
            zeros(Int, n),
            fill(:exact, n),
        )
    end
    throw(
        ArgumentError(
            "a component of a selection over several databases is a name, an InChIKey, a formula " *
            "or the result of `find_compounds(db, ...)`, not $(typeof(component))",
        ),
    )
end

function member_components(reg::Registry, m::Integer, component, match::Symbol, exact::Bool)
    component === nothing && return (true, nothing)
    if component isa AbstractVector
        translated = [member_component(reg, m, c) for c in component]
        present = filter(!isnothing, translated)
        needed = exact || match === :all
        ((needed && length(present) < length(translated)) || isempty(present)) &&
            return (false, nothing)
        return (true, present)
    end
    translated = member_component(reg, m, component)
    return (translated !== nothing, translated)
end

const NO_MATCH_MESSAGES = ("no compound matches", "no property matches", "unknown source")
no_match(err) = err isa ArgumentError && any(p -> startswith(err.msg, p), NO_MATCH_MESSAGES)

# ----------------------------------------------------------------------------------
# A selection over several databases
# ----------------------------------------------------------------------------------

"""
    DatabaseView

A selection of points made of one [`DataView`](@ref) for each database that had some: `parts(v)`.
Its length is the number of points. [`points`](@ref) refines it, [`table`](@ref) joins the columns
of the parts (adding the column `database` when there are several), and with one part it is used
wherever a `DataView` is.
"""
struct DatabaseView
    database::Database
    index::Vector{Int}
    parts::Vector{DataView}
end

"""
    parts(view) -> Vector{DataView}

The selection of each database that has points, in the order of the databases.
"""
parts(v::DatabaseView) = v.parts

Base.length(v::DatabaseView) = sum(length, v.parts; init = 0)
Base.isempty(v::DatabaseView) = all(isempty, v.parts)

function Base.show(io::IO, v::DatabaseView)
    print(io, "DatabaseView(", length(v), " points")
    for (i, part) in zip(v.index, v.parts)
        print(io, "\n  ", rpad(v.database.members[i].name, 20), length(part))
    end
    return print(io, ")")
end

# The first `maxrows` points, taking each database in order, as a table.
function Base.show(io::IO, ::MIME"text/plain", v::DatabaseView; maxrows::Int = 12)
    println(io, "DatabaseView: ", length(v), " points")
    for (i, part) in zip(v.index, v.parts)
        println(io, "  ", rpad(v.database.members[i].name, 20), length(part))
    end
    isempty(v) && return nothing
    left = maxrows
    index, trimmed = Int[], DataView[]
    for (i, part) in zip(v.index, v.parts)
        (left == 0 || isempty(part)) && continue
        take = min(length(part), left)
        push!(index, i)
        push!(trimmed, DataView(part.dataset, part.rows[1:take]))
        left -= take
    end
    println(io)
    shown = DatabaseView(v.database, index, trimmed)
    print_points(io, table(shown), length(shown), length(v) - length(shown))
    return nothing
end

function select_parts(db::Database, candidates, sources, component, kwargs)
    reg = db.registry
    match = get(kwargs, :match, :any)
    exact = get(kwargs, :exact, false)
    index, found = Int[], DataView[]
    failure = nothing
    for (m, source) in zip(candidates, sources)
        ok, comp = member_components(reg, m, component, match, exact)
        ok || continue
        try
            view =
                comp === nothing ? points(source; kwargs...) :
                points(source; component = comp, kwargs...)
            push!(index, m)
            push!(found, view)
        catch err
            no_match(err) || rethrow()
            failure === nothing && (failure = err)
        end
    end
    if isempty(found)
        failure !== nothing && throw(failure)
        # Every member was left out by the translation of the component: say so with the message
        # of the first one.
        throw(ArgumentError("no compound matches the given components in any database"))
    end
    return DatabaseView(db, index, found)
end

"""
    points(db::Database; kwargs...) -> DatabaseView

Select points in every database that can have them, with the keywords of
[`points`](@ref) over a dataset. A component or property that no database knows is an
`ArgumentError`; one that some databases lack is not. A component given as the result of
`find_compounds(db, text)` is translated to the identifiers of each database.
"""
function points(db::Database; component = nothing, kwargs...)
    isempty(db.members) && throw(ArgumentError("the database has no members"))
    if length(db.members) > 1 &&
       (component isa Integer || component isa AbstractVector{<:Integer})
        throw(
            ArgumentError(
                "a compound number belongs to one database; give a name, an InChIKey, a formula " *
                "or the result of `find_compounds(db, ...)`",
            ),
        )
    end
    match = get(kwargs, :match, :any)
    exact = get(kwargs, :exact, false)
    candidates = candidate_members(
        db,
        component,
        match,
        exact,
        get(kwargs, :property, nothing),
        get(kwargs, :doi, nothing),
    )
    # Nothing left: ask them all, which gives the usual message (with its suggestions).
    isempty(candidates) && (candidates = collect(eachindex(db.members)))
    sources = [member_dataset(db.members[m]) for m in candidates]
    if length(db.members) == 1
        return DatabaseView(db, [1], [points(sources[1]; component, kwargs...)])
    end
    return select_parts(db, candidates, sources, component, kwargs)
end

function points(v::DatabaseView; component = nothing, kwargs...)
    db = v.database
    return select_parts(db, v.index, v.parts, component, kwargs)
end

# Counts of the points of every compound that matches, joined over the databases.
"""
    find_compounds(db::Database, text; limit = 10) -> CompoundMatches

The compounds of all the databases that `text` names, one row for each compound (the same compound in
several databases is one), with the points that all the databases have of it. The identifiers of
the result are global: use it as `component` of [`points`](@ref).
"""
function find_compounds(db::Database, text::AbstractString; limit::Int = 10)
    reg = db.registry
    if length(db.members) == 1
        return find_compounds(member_dataset(db.members[1]), text; limit)
    end
    order = Int32[]
    name = Dict{Int32,String}()
    formula = Dict{Int32,String}()
    inchikey = Dict{Int32,String}()
    count = Dict{Int32,Int}()
    how = Dict{Int32,Symbol}()
    for (m, member) in enumerate(db.members)
        found = try
            find_compounds(member_dataset(member), text; limit)
        catch err
            err isa ArgumentError || rethrow()
            continue
        end
        for (k, id) in enumerate(found.id)
            g = reg.compound[m][id]
            if !haskey(name, g)
                push!(order, g)
                name[g], formula[g], inchikey[g] =
                    found.name[k], found.formula[k], found.inchikey[k]
                how[g] = found.match[k]
                count[g] = 0
            end
            count[g] += found.points[k]
            found.match[k] === :exact && (how[g] = :exact)
        end
    end
    sort!(order; by = g -> how[g] === :exact ? 0 : 1, alg = MergeSort)
    order = order[1:min(end, limit)]
    return CompoundMatches(
        String(text),
        order,
        [name[g] for g in order],
        [formula[g] for g in order],
        [inchikey[g] for g in order],
        [count[g] for g in order],
        [how[g] for g in order],
    )
end

# ----------------------------------------------------------------------------------
# Tables
# ----------------------------------------------------------------------------------

sole_part(v::DatabaseView) =
    length(v.parts) == 1 ? v.parts[1] :
    throw(
        ArgumentError(
            "this selection has points of $(length(v.parts)) databases and the function does not " *
            "join them yet; use it on one database with `parts(view)`",
        ),
    )

sole_dataset(db::Database) =
    length(db.members) == 1 ? member_dataset(db.members[1]) :
    throw(
        ArgumentError(
            "the function does not work over $(length(db.members)) databases yet; " *
            "use `member_dataset(db, name)` for one of them",
        ),
    )

"""
    table(view::DatabaseView; kwargs...)

The columns of [`table`](@ref) of every part, one after the other. When the selection has points
of several databases the column `database` says which one each point comes from.
"""
function table(v::DatabaseView; kwargs...)
    length(v.parts) == 1 && return table(v.parts[1]; kwargs...)
    tables = [
        (v.database.members[i].name, table(p; kwargs...)) for
        (i, p) in zip(v.index, v.parts) if !isempty(p)
    ]
    isempty(tables) && return table(v.parts[1]; kwargs...)
    first_table = tables[1][2]
    cols = keys(first_table)
    merged = NamedTuple{cols}(map(k -> reduce(vcat, (t[k] for (_, t) in tables)), cols))
    names = reduce(vcat, [fill(n, length(t[first(cols)])) for (n, t) in tables])
    return merge(merged, (; database = names))
end

# What works with one database as before, for a `Database` and a `DatabaseView` that have one part.
for f in (
    :sample_table,
    :purity_step_table,
    :set_uncertainty!,
    :link_compounds,
    :prefetch_compounds!,
    :bibtex,
    :find_outliers,
)
    @eval $f(db::Database, args...; kwargs...) = $f(sole_dataset(db), args...; kwargs...)
end

for f in (
    :bibtex,
    :reference_summary,
    :find_outliers,
    :expanded_uncertainty,
    :convert_composition,
)
    @eval $f(v::DatabaseView, args...; kwargs...) = $f(sole_part(v), args...; kwargs...)
end

for f in (:export_points, :write_bibtex, :write_references)
    @eval $f(path::AbstractString, v::DatabaseView, args...; kwargs...) =
        $f(path, sole_part(v), args...; kwargs...)
end

# The tables of conditions and uncertainty terms can be limited to a selection.
for f in (:condition_table, :uncertainty_table)
    @eval begin
        function $f(v::DatabaseView)
            part = sole_part(v)
            return $f(part.dataset; view = part)
        end

        function $f(db::Database; view = nothing)
            return $f(
                sole_dataset(db);
                view = view isa DatabaseView ? sole_part(view) : view,
            )
        end
    end
end

find_compounds(v::DatabaseView, text::AbstractString; kwargs...) =
    find_compounds(v.database, text; kwargs...)
validate(db::Database) = all(m -> validate(member_dataset(m)), db.members)

Tables.istable(::Type{DatabaseView}) = true
Tables.columnaccess(::Type{DatabaseView}) = true
Tables.columns(view::DatabaseView) = table(view)

# A selection of one database is read like a `DataView`: its `rows` and its `dataset`.
function Base.getproperty(v::DatabaseView, name::Symbol)
    if name === :rows || name === :dataset
        return getproperty(sole_part(v), name)
    end
    return getfield(v, name)
end
