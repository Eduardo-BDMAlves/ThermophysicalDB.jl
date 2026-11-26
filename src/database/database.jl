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

A `Database` can have the compound database attached ([`link_compounds!`](@ref); [`database`](@ref)
does it by default). Then a compound can be named by anything the compound database knows (a
synonym, a CAS number, a PubChem CID, an InChI, a SMILES) in [`points`](@ref),
[`mixture`](@ref) and [`find_compounds`](@ref), and the other functions that take the compound
database find it without being given.
"""
mutable struct Database
    members::Vector{Member}
    registry::Registry
    compounds::Union{Nothing,CompoundDB}
    compound_loader::Union{Nothing,Function}
    by_name::Bool
    links::Union{Nothing,Vector{CompoundLinks}}
    choices::Dict{String,CompoundMatches}
end

# A database with no compound database attached (see `link_compounds!` and `database`).
Database(members::Vector{Member}, registry::Registry) = Database(
    members,
    registry,
    nothing,
    nothing,
    true,
    nothing,
    Dict{String,CompoundMatches}(),
)

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
    forget_links!(db)
    return db
end

"""
    remove_member!(db, name) -> Database

Take a database out of `db` (its file is not touched).
"""
function remove_member!(db::Database, name::AbstractString)
    deleteat!(db.members, member_index(db, name))
    db.registry = build_registry(db.members)
    forget_links!(db)
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
    println(io, "  ", compounds_state(db))
    n == 0 && return nothing
    headers = [
        "database",
        "kind",
        "priority",
        "points",
        "references",
        "compounds",
        "properties",
        "created",
        "modified",
        "state",
    ]
    rows = map(db.members) do m
        cat = member_catalog(m)
        created, modified = member_stamps(m)
        [
            m.name,
            String(m.kind),
            string(m.priority),
            group_digits(member_points(m)),
            group_digits(length(cat.doi)),
            group_digits(length(cat.compound_key)),
            group_digits(length(cat.property_label)),
            first(stamp_text(created), 10),
            first(stamp_text(modified), 10),
            is_open(m) ? "read" : "not read",
        ]
    end
    left = Set([1, 2, 9])
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

# The global compounds that each text, or each result of `find_compounds(db, ...)`, of a component
# stands for; `nothing` for a component that cannot be told from the catalogs (a pattern, a number).
function component_groups(reg::Registry, component, multi::Bool)
    items = component isa AbstractVector ? component : [component]
    groups = Vector{Int32}[]
    for item in items
        if item isa AbstractString
            push!(groups, registered_compounds(reg, item))
        elseif item isa CompoundMatches && multi    # with one database the numbers are its own
            push!(groups, collect(Int32, item.id))
        else
            return nothing
        end
    end
    return groups
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
    groups = component_groups(reg, component, length(db.members) > 1)
    if groups !== nothing && !isempty(groups) && all(!isempty, groups)
        for m in eachindex(keep)
            has = [any(g -> reg.has_compound[m][g], group) for group in groups]
            keep[m] &= (exact || match === :all) ? all(has) : any(has)
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
            "a component of a selection over several databases is a name, an InChIKey, a formula, " *
            "the result of `find_compounds(db, ...)` or (with a compound database attached) of " *
            "`lookup_compounds(db, ...)`, not $(typeof(component))",
        ),
    )
end

# The same for the compounds of a `fraction`: `(false, nothing)` when the member lacks one of them,
# because every criterion of a fraction must hold.
function member_fraction(reg::Registry, m::Integer, fraction)
    fraction === nothing && return (true, nothing)
    translated = Pair[]
    for (compound, range) in fraction_items(fraction)
        local_compound = member_component(reg, m, compound)
        local_compound === nothing && return (false, nothing)
        push!(translated, local_compound => range)
    end
    return (true, translated)
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

const NO_MATCH_MESSAGES = (
    "no compound matches",
    "no property matches",
    "unknown source",
    "no phase matches",
    "no method matches",
    "no xkind matches",
    "no property has the dimension",
)
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
    repeats::Union{Nothing,DuplicateReport}
end

DatabaseView(db::Database, index::Vector{Int}, parts::Vector{DataView}) =
    DatabaseView(db, index, parts, nothing)

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

# The points a selection left out because another database holds them too, or they were entered
# twice (each counted once).
function omitted_points(v::DatabaseView)
    r = v.repeats
    r === nothing && return 0
    gone = r.kind .== :duplicate
    return length(unique(zip(r.other_database[gone], r.other_row[gone])))
end

# The first `maxrows` points, taking each database in order, as a table.
function Base.show(io::IO, ::MIME"text/plain", v::DatabaseView; maxrows::Int = 12)
    println(io, "DatabaseView: ", length(v), " points")
    for (i, part) in zip(v.index, v.parts)
        println(io, "  ", rpad(v.database.members[i].name, 20), length(part))
    end
    if v.repeats !== nothing
        n = pair_counts(v.repeats)
        n.conflicts > 0 &&
            println(io, "  ", n.conflicts, " conflicts, both points kept (conflicts(view))")
    end
    isempty(v) && (print_omitted(io, omitted_points(v)); return nothing)
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
    shown = DatabaseView(v.database, index, trimmed, nothing)
    print_points(io, table(shown), length(shown), length(v) - length(shown))
    print_omitted(io, omitted_points(v))
    return nothing
end

function select_parts(db::Database, candidates, sources, component, kwargs)
    reg = db.registry
    experiment = get(kwargs, :experiment, nothing)
    kwargs = (; (k => v for (k, v) in pairs(kwargs) if k !== :experiment)...)
    named = nothing
    if experiment !== nothing
        named = Dict{Int,Vector{Int32}}()
        for (m, source) in zip(candidates, sources)
            ds = source isa DataView ? source.dataset : source
            ids = named_experiments(db.members[m], ds, experiment)
            isempty(ids) || (named[m] = ids)
        end
        isempty(named) && throw(ArgumentError("no experiment is named $(repr(experiment))"))
    end
    match = get(kwargs, :match, :any)
    exact = get(kwargs, :exact, false)
    index, found = Int[], DataView[]
    failure = nothing
    for (m, source) in zip(candidates, sources)
        ok, comp = member_components(reg, m, component, match, exact)
        ok || continue
        fraction_ok, amounts = member_fraction(reg, m, get(kwargs, :fraction, nothing))
        fraction_ok || continue
        named !== nothing && !haskey(named, m) && continue
        own = amounts === nothing ? kwargs : (; kwargs..., fraction = amounts)
        named === nothing || (own = (; own..., experiments = named[m]))
        try
            view =
                comp === nothing ? points(source; own...) :
                points(source; component = comp, own...)
            push!(index, m)
            push!(found, view)
        catch err
            no_match(err) || rethrow()
            failure === nothing && (failure = err)
        end
    end
    if isempty(found)
        # The source exists in a database that the selection leaves out (for example because it
        # lacks the compound): say that, instead of "unknown source" from a database that never
        # had it.
        wanted = get(kwargs, :source, nothing)
        if wanted !== nothing
            holders = [
                db.members[m].name for m in eachindex(db.members) if
                haskey(member_dataset(db.members[m]).sources.index, wanted)
            ]
            isempty(holders) || throw(
                ArgumentError(
                    "source \"$wanted\" exists but none of its points matches the selection " *
                    "(the compound, property or limits are not in it)",
                ),
            )
        end
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
[`points`](@ref) over a dataset, `experiment` (the name of an experiment, a `Regex` or a vector
of them, see [`add_name!`](@ref); an `ArgumentError` when none is called that) and `duplicate`: `false` (the default) leaves out the points
that another database with a higher priority holds too, and the points that were entered twice in a
database of yours (the later copy is left out; it stays in the database); `true` keeps every point,
and a [`DuplicateRules`](@ref) leaves them out with the tolerances you choose (see [`duplicates`](@ref) for
what a repeated point is, and [`conflicts`](@ref) for the points that disagree, which are never
left out). A component or property that no database knows is an
`ArgumentError`; one that some databases lack is not. A component given as the result of
`find_compounds(db, text)` is translated to the identifiers of each database.
"""
function points(
    db::Database;
    component = nothing,
    fraction = nothing,
    duplicate = false,
    choose = :ask,
    online::Bool = false,
    input::IO = stdin,
    output::IO = stdout,
    kwargs...,
)
    isempty(db.members) && throw(ArgumentError("the database has no members"))
    component, fraction =
        resolve_inputs(db, component, fraction, choose, input, output, online)
    kwargs = fraction === nothing ? kwargs : (; kwargs..., fraction)
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
    if length(db.members) == 1 && !haskey(kwargs, :experiment)
        duplicate_rules(duplicate)    # a wrong value is an error whatever the number of databases
        return apply_duplicate(
            DatabaseView(db, [1], [points(sources[1]; component, kwargs...)]),
            duplicate,
        )
    end
    return apply_duplicate(
        select_parts(db, candidates, sources, component, kwargs),
        duplicate,
    )
end

function points(
    v::DatabaseView;
    component = nothing,
    fraction = nothing,
    duplicate = false,
    choose = :ask,
    online::Bool = false,
    input::IO = stdin,
    output::IO = stdout,
    kwargs...,
)
    db = v.database
    component, fraction =
        resolve_inputs(db, component, fraction, choose, input, output, online)
    kwargs = fraction === nothing ? kwargs : (; kwargs..., fraction)
    return apply_duplicate(select_parts(db, v.index, v.parts, component, kwargs), duplicate)
end

# Counts of the points of every compound that matches, joined over the databases.
"""
    find_compounds(db::Database, text; limit = 10) -> CompoundMatches

The compounds of all the databases that `text` names, one row for each compound (the same compound in
several databases is one), with the points that all the databases have of it. The identifiers of
the result are global: use it as `component` of [`points`](@ref). With a compound database attached
([`link_compounds!`](@ref), the default of [`database`](@ref)), `text` can also be a CAS number, a
synonym, a PubChem CID, an InChI or a SMILES, like in [`find_compounds`](@ref)`(db, compounds, text)`.
"""
function find_compounds(db::Database, text::AbstractString; limit::Int = 10)
    cdb = compounds_of(db)
    cdb === nothing || return find_compounds(db, cdb, text; limit)
    return joined_matches(ds -> find_compounds(ds, text; limit), db, text, limit)
end

"""
    find_compounds(db::Database, compounds::CompoundDB, text; limit = 10) -> CompoundMatches

[`find_compounds`](@ref) over every database that also understands what the compound database
knows (a CAS number, a synonym, an InChI...): the result has global identifiers, to use as
`component` of [`points`](@ref).
"""
function find_compounds(
    db::Database,
    compounds::CompoundDB,
    text::AbstractString;
    limit::Int = 10,
)
    return joined_matches(ds -> find_compounds(ds, compounds, text; limit), db, text, limit)
end

# The matches of `finder` in every member, joined by the compounds the registry says are the same.
function joined_matches(finder, db::Database, text::AbstractString, limit::Int)
    reg = db.registry
    if length(db.members) == 1
        return finder(member_dataset(db.members[1]))
    end
    order = Int32[]
    name = Dict{Int32,String}()
    formula = Dict{Int32,String}()
    inchikey = Dict{Int32,String}()
    count = Dict{Int32,Int}()
    how = Dict{Int32,Symbol}()
    for (m, member) in enumerate(db.members)
        found = try
            finder(member_dataset(member))
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

# What the publication takes of a selection: the publication and, for each part, which of its
# points are the publication's.
struct Work
    publication::Publication
    masks::Vector{BitVector}
end

pub_selector(p::Publication) = (p, isempty(p.name) ? nothing : p.experiments)

# The publication that `this_work` says and what selects its points (`nothing`: all the data of
# the databases of kind `:user`; names of experiments; or a selection of points). `:auto` is the
# only publication of the database; with several the answer is an error when `strict`, and none
# otherwise, so that a table is never refused for it.
function resolve_work(db::Database, this_work, strict::Bool)
    (this_work === false || this_work === nothing) && return nothing
    everything = publications(db)
    if this_work === :auto
        isempty(everything) && return nothing
        length(everything) == 1 && return pub_selector(everything[1])
        strict || return nothing
        throw(
            ArgumentError(
                "the database has several publications ($(join(repr.([p.name for p in everything]), ", "))): " *
                "say which one is this work with `this_work = \"name\"`, or `this_work = false`",
            ),
        )
    end
    this_work === true && return pub_selector(something(publication(db), Publication()))
    this_work isa Publication && return pub_selector(this_work)
    if this_work isa AbstractString
        m, k = find_publication(db, this_work)
        return pub_selector(m.publications[k])
    end
    if this_work isa DatabaseView || this_work isa DataView
        base =
            length(everything) == 1 ? everything[1] :
            something(publication(db), Publication())
        return (with_experiments(base, String[]), this_work)
    end
    throw(
        ArgumentError(
            "this_work is :auto, true, false, nothing, the name of a publication, a Publication " *
            "or a selection of points, got $(repr(this_work))",
        ),
    )
end

function work_scope(v::DatabaseView, this_work; strict::Bool = false)
    resolved = resolve_work(v.database, this_work, strict)
    resolved === nothing && return nothing
    pub, selector = resolved
    masks = BitVector[]
    for (i, p) in zip(v.index, v.parts)
        m = v.database.members[i]
        mask = if selector === nothing
            m.kind === :user ? trues(length(p)) : falses(length(p))
        elseif selector isa AbstractVector
            names = Set(selector)
            list = experiment_tags(m, p.dataset)
            BitVector([
                any(in(names), list[p.dataset.measurements.experiment[r]]) for r in p.rows
            ])
        else
            chosen = selection_rows(selector, i, p)
            BitVector([r in chosen for r in p.rows])
        end
        push!(masks, mask)
    end
    return Work(pub, masks)
end

# The rows that a selection `s` holds of the database `i`, whose points in the view are `p`.
function selection_rows(s::DatabaseView, i::Integer, p::DataView)
    for (j, q) in zip(s.index, s.parts)
        j == i && q.dataset === p.dataset && return Set(q.rows)
    end
    return Set{Int32}()
end
selection_rows(s::DataView, ::Integer, p::DataView) =
    s.dataset === p.dataset ? Set(s.rows) : Set{Int32}()

# The selection with each part cut in two when only some of its points are the publication's, and
# a flag for each part of the result that says whether it is the publication's.
function split_work(v::DatabaseView, work::Union{Nothing,Work})
    work === nothing && return v, fill(false, length(v.parts))
    index, parts, flags = Int[], DataView[], Bool[]
    for (k, p) in enumerate(v.parts)
        mask = work.masks[k]
        i = v.index[k]
        if isempty(p) || !any(mask)
            push!(index, i)
            push!(parts, p)
            push!(flags, false)
        elseif all(mask)
            push!(index, i)
            push!(parts, p)
            push!(flags, true)
        else
            push!(index, i)
            push!(parts, DataView(p.dataset, p.rows[mask]))
            push!(flags, true)
            push!(index, i)
            push!(parts, DataView(p.dataset, p.rows[.!mask]))
            push!(flags, false)
        end
    end
    return DatabaseView(v.database, index, parts, v.repeats), flags
end

# The column `work`: the label of the publication for its points, "$(OWN_LABEL)" for the other
# points of the databases of kind `:user` and "$(LITERATURE_LABEL)" for all the rest.
function work_column(db::Database, index, parts, work::Work)
    labels = String[]
    for (k, (i, p)) in enumerate(zip(index, parts))
        isempty(p) && continue
        other = db.members[i].kind === :user ? OWN_LABEL : LITERATURE_LABEL
        append!(labels, [x ? work.publication.label : other for x in work.masks[k]])
    end
    return labels
end

function with_work(t::PointTable, labels::Vector{String})
    length(labels) == nrows(t) || throw(
        ArgumentError("the table has $(nrows(t)) points and the labels $(length(labels))"),
    )
    return with_columns(t, merge(parent(t), (; work = labels)))
end

"""
    table(view::DatabaseView; this_work = :auto, kwargs...)

The columns of [`table`](@ref) of every part, one after the other. When the selection has points
of several databases the column `database` says which one each point comes from. `sortby` and `rev`
sort the points of all the parts together (`database` and `work` are keys too), after they are
joined.

When the database has a [`Publication`](@ref) ([`set_publication!`](@ref)), the table has the
column `work`: the label of the publication (by default "This work") for the points of the
databases of kind `:user` and "$(LITERATURE_LABEL)" for the others; the figures and the tables that
are written use it. `this_work = false` leaves it out, `true` or a `Publication` asks for it
without setting it in the database.
"""
function table(v::DatabaseView; kwargs...)
    return with_omitted(database_table(v; kwargs...), omitted_points(v))
end

function database_table(
    v::DatabaseView;
    sortby = nothing,
    rev::Bool = false,
    this_work = :auto,
    kwargs...,
)
    work = work_scope(v, this_work)
    work === nothing && return joined_table(v; sortby, rev, kwargs...)
    t = joined_table(v; kwargs...)
    t = with_work(t, work_column(v.database, v.index, v.parts, work))
    return finish_sort(t, sortby, rev, false)
end

function joined_table(v::DatabaseView; sortby = nothing, rev::Bool = false, kwargs...)
    length(v.parts) == 1 && return table(v.parts[1]; sortby, rev, kwargs...)
    tables = [
        (v.database.members[i].name, table(p; kwargs...)) for
        (i, p) in zip(v.index, v.parts) if !isempty(p)
    ]
    isempty(tables) && return table(v.parts[1]; sortby, rev, kwargs...)
    first_table = tables[1][2]
    cols = keys(first_table)
    merged = NamedTuple{cols}(map(k -> reduce(vcat, (t[k] for (_, t) in tables)), cols))
    names = reduce(vcat, [fill(n, length(t[first(cols)])) for (n, t) in tables])
    result = PointTable(
        merge(merged, (; database = names)),
        getfield(first_table, :temperature_unit),
        getfield(first_table, :pressure_unit),
    )
    return finish_sort(result, sortby, rev, false)
end

# What works with one database as before, for a `Database` and a `DatabaseView` that have one part.
for f in (
    :sample_table,
    :purity_step_table,
    :set_uncertainty!,
    :prefetch_compounds!,
    :bibtex,
    :find_outliers,
)
    @eval $f(db::Database, args...; kwargs...) = $f(sole_dataset(db), args...; kwargs...)
end

for f in (:find_outliers, :expanded_uncertainty)
    @eval $f(v::DatabaseView, args...; kwargs...) = $f(sole_part(v), args...; kwargs...)
end

# The molar masses come from the compound database of the selection, unless another is given.
function convert_composition(
    v::DatabaseView,
    args...;
    compounds = compounds_of(v.database),
    kwargs...,
)
    return convert_composition(sole_part(v), args...; compounds, kwargs...)
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
Tables.columns(view::DatabaseView) = parent(table(view))

# A selection of one database is read like a `DataView`: its `rows` and its `dataset`.
function Base.getproperty(v::DatabaseView, name::Symbol)
    if name === :rows || name === :dataset
        return getproperty(sole_part(v), name)
    end
    return getfield(v, name)
end

# ----------------------------------------------------------------------------------
# Which phases and methods there are (see `query/filters.jl`)
# ----------------------------------------------------------------------------------

measured_properties(v::DatabaseView; search = nothing) =
    joined_count_table(:property, [measured_properties(p; search) for p in parts(v)])
measured_properties(db::Database; search = nothing) = joined_count_table(
    :property,
    [measured_properties(member_dataset(m); search) for m in db.members],
)
phases(v::DatabaseView) = joined_count_table(:phase, phases.(parts(v)))
measurement_methods(v::DatabaseView) =
    joined_count_table(:method, measurement_methods.(parts(v)))
phases(db::Database) =
    joined_count_table(:phase, [phases(member_dataset(m)) for m in db.members])
measurement_methods(db::Database) = joined_count_table(
    :method,
    [measurement_methods(member_dataset(m)) for m in db.members],
)
