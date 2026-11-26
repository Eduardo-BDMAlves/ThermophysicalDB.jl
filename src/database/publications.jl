# Several publications at once. The data that the user measures pile up in the database for
# months, and each article takes some of them: a named publication is a `Publication` with the
# names of its experiments (see `add_name!`).

# Every publication of the databases of the user, once each: the unnamed one (all the data) first,
# then the named ones in the order of their names.
"""
    publications(db) -> Vector{Publication}

The publications of the database: the one of all the data of the user, if there is one
([`set_publication!`](@ref)), and the named ones ([`add_publication!`](@ref)).
"""
function publications(db::Database)
    found = Dict{String,Publication}()
    for m in db.members, p in m.publications
        get!(found, p.name, p)
    end
    return Publication[found[k] for k in sort!(collect(keys(found)))]
end

# The member that holds the named publication `name`, with its position there.
function find_publication(db::Database, name::AbstractString)
    for m in db.members, (k, p) in enumerate(m.publications)
        p.name == name && return m, k
    end
    names = [p.name for p in publications(db) if !isempty(p.name)]
    throw(
        ArgumentError(
            "there is no publication called \"$name\"" *
            (isempty(names) ? "" : "; the publications are $(join(repr.(names), ", "))"),
        ),
    )
end

# The names of experiments that none of the databases has, in `wanted`.
function unknown_experiment_names(db::Database, wanted)
    missing_names = Set(String.(wanted))
    for m in db.members
        isempty(missing_names) && break
        setdiff!(missing_names, Iterators.flatten(experiment_tags(m, member_dataset(m))))
    end
    return sort!(collect(missing_names))
end

"""
    add_publication!(db, publication; database = nothing) -> Database

Add a publication that is prepared next to others: `publication` is a [`Publication`](@ref) with a
`name` (`"paper-A"`) and, in `experiments`, the names of the experiments that are its data (see
[`add_name!`](@ref)). Its points are the ones of those experiments, in any database, and no others:
the rest of your data stay what they are. It is kept in the database `database` of kind `:user`
(the first by default). Use it with `this_work = "paper-A"` in a table, a figure or an export, and
with [`publish!`](@ref) when the article is out. A name that no experiment has is an
`ArgumentError`, so a typo is not a publication with no data.

```julia
add_publication!(db, Publication(; name = "paper-A", title = "...", year = 2026,
                                 experiments = ["visc-run-1", "visc-run-2"]))
add_to_publication!(db, "paper-A", "visc-run-3")
```
"""
function add_publication!(
    db::Database,
    publication::Publication;
    database::Union{Nothing,AbstractString} = nothing,
)
    isempty(publication.name) && throw(
        ArgumentError(
            "a publication that is prepared next to others needs a name: Publication(; name = \"paper-A\", ...)",
        ),
    )
    any(m -> any(p -> p.name == publication.name, m.publications), db.members) && throw(
        ArgumentError("there is already a publication called \"$(publication.name)\""),
    )
    unknown = unknown_experiment_names(db, publication.experiments)
    isempty(unknown) || throw(
        ArgumentError(
            "no experiment is called $(join(repr.(unknown), ", ")); give it with add_name!",
        ),
    )
    m = if database === nothing
        i = findfirst(m -> m.kind === :user, db.members)
        i === nothing && throw(
            ArgumentError(
                "there is no database of kind :user to keep the publication; create one with add_database!(db, name)",
            ),
        )
        db.members[i]
    else
        x = db.members[member_index(db, database)]
        x.kind === :user || throw(
            ArgumentError("\"$(x.name)\" is :$(x.kind), not a database of kind :user"),
        )
        x
    end
    push!(m.publications, publication)
    persist_publications!(m, "added $(publication.name)")
    return db
end

function update_publication!(db::Database, name::AbstractString, change)
    m, k = find_publication(db, name)
    m.publications[k] = change(m.publications[k])
    persist_publications!(m, "changed $name")
    return db
end

with_experiments(p::Publication, experiments) = Publication(
    p.label,
    p.title,
    p.authors,
    p.year,
    p.journal,
    p.doi,
    p.note,
    p.cite,
    p.name,
    experiments,
)

"""
    add_to_publication!(db, name, experiments) -> Database

Add the experiments called `experiments` (a name or a vector of names) to the publication `name`.
"""
function add_to_publication!(
    db::Database,
    name::AbstractString,
    experiments::Union{AbstractString,AbstractVector{<:AbstractString}},
)
    list = experiments isa AbstractString ? [String(experiments)] : String.(experiments)
    unknown = unknown_experiment_names(db, list)
    isempty(unknown) || throw(
        ArgumentError(
            "no experiment is called $(join(repr.(unknown), ", ")); give it with add_name!",
        ),
    )
    return update_publication!(
        db,
        name,
        p -> with_experiments(p, vcat(p.experiments, list)),
    )
end

"""
    remove_from_publication!(db, name, experiments) -> Database

Take the experiments called `experiments` out of the publication `name`; they stay in the database.
"""
function remove_from_publication!(
    db::Database,
    name::AbstractString,
    experiments::Union{AbstractString,AbstractVector{<:AbstractString}},
)
    gone =
        Set(experiments isa AbstractString ? [String(experiments)] : String.(experiments))
    return update_publication!(
        db,
        name,
        p -> with_experiments(p, [e for e in p.experiments if !(e in gone)]),
    )
end

"""
    remove_publication!(db, name) -> Database

Remove the publication `name` (its experiments and their points stay). `""` is the publication of
all the data, see [`set_publication!`](@ref).
"""
function remove_publication!(db::Database, name::AbstractString)
    isempty(name) && return set_publication!(db, nothing)
    m, k = find_publication(db, name)
    deleteat!(m.publications, k)
    persist_publications!(m, "removed $name")
    return db
end
