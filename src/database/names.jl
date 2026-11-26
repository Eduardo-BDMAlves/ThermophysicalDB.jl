# Names of experiments.
#
# An experiment can have a name, to select it ("the viscosities of the paper") and to find it again
# after it has moved to another database. In a database of yours the name is a note of the
# experiment, so it is part of the data and travels with it. The ThermoML archive is read only: its
# names are kept in a file beside it, by (DOI, number of the experiment), and survive an update.
# An experiment can have several names (they are tags): `add_name!` adds one and keeps the others,
# `modify_name!` changes one and `remove_name!` takes some away. A name given to several
# experiments is the name of a group.

const NAME_KEY = "experiment_name"

names_file(m::Member) =
    isempty(m.path) ? "" :
    joinpath(dirname(m.path), string(m.name, "-experiment-names.toml"))

# The names of the experiments of a read-only archive, read from their file the first time.
function archive_names(m::Member)
    t = m.archive_names
    t === nothing || return t
    return lock(m.lock) do
        if m.archive_names === nothing
            names = Dict{Tuple{String,Int32},Vector{String}}()
            file = names_file(m)
            if !isempty(file) && isfile(file)
                for (doi, group) in TOML.parsefile(file), (number, tags) in group
                    names[(doi, parse(Int32, number))] =
                        tags isa AbstractString ? [String(tags)] : String.(tags)
                end
            end
            m.archive_names = names
        end
        return m.archive_names::Dict{Tuple{String,Int32},Vector{String}}
    end
end

function write_archive_names(m::Member)
    file = names_file(m)
    isempty(file) && return nothing
    grouped = Dict{String,Dict{String,Vector{String}}}()
    for ((doi, number), tags) in archive_names(m)
        isempty(tags) ||
            (get!(grouped, doi, Dict{String,Vector{String}}())[string(number)] = tags)
    end
    if isempty(grouped)
        rm(file; force = true)
    else
        open(io -> TOML.print(io, grouped), file, "w")
    end
    return nothing
end

experiment_scope() = UInt8(findfirst(==(:experiment), EXTRA_SCOPES)::Int)

"""
    experiment_tags(m::Member, ds::Dataset) -> Vector{Vector{String}}

The names of each experiment of `ds`, in the order they were given (empty when it has none).
"""
function experiment_tags(m::Member, ds::Dataset)::Vector{Vector{String}}
    out = [String[] for _ = 1:length(ds.experiments)]
    if m.kind === :thermoml
        names = archive_names(m)
        isempty(names) && return out
        ex = ds.experiments
        for e in eachindex(out)
            tags = get(names, (ds.references.doi[ex.reference[e]], ex.number[e]), nothing)
            tags === nothing || append!(out[e], tags)
        end
        return out
    end
    code = findfirst(==(NAME_KEY), ds.extra_keys.strings)
    code === nothing && return out
    scope = experiment_scope()
    x = ds.extras
    for i in eachindex(x.row)
        x.scope[i] == scope &&
            x.key[i] == code &&
            push!(out[x.row[i]], ds.extra_texts.strings[x.text[i]])
    end
    return out
end

# Give `name` to the experiment `e` of the dataset `ds`, that is open for changes.
function push_name!(ds::Dataset, e::Integer, name::AbstractString)
    key = narrow(UInt8, intern!(ds.extra_keys, NAME_KEY), "extra field")
    x = ds.extras
    push!(x.scope, experiment_scope())
    push!(x.row, Int32(e))
    push!(x.key, key)
    push!(x.number, NaN)
    push!(x.text, intern!(ds.extra_texts, String(name)))
    return nothing
end

# Take the names of the experiments `ids` out of a dataset that is open for changes.
function drop_names!(ds::Dataset, ids)
    code = findfirst(==(NAME_KEY), ds.extra_keys.strings)
    code === nothing && return nothing
    scope, x, wanted = experiment_scope(), ds.extras, Set(Int32.(ids))
    keep = BitVector([
        !(x.scope[i] == scope && x.key[i] == code && x.row[i] in wanted) for
        i in eachindex(x.row)
    ])
    all(keep) && return nothing
    for field in (:scope, :row, :key, :number, :text)
        keepat!(getfield(x, field), keep)
    end
    return nothing
end

# The experiment name that a new experiment of `ref` gets when the user gives none:
# `<database>_yyyy_mm_dd_HH:MM`, with `_<name of the compound>` when the system is one pure
# substance (the IUPAC name when the compound database has it), and `_2`, `_3`... when the
# database already has an experiment of that name.
function automatic_name(db::Database, m::Member, ds::Dataset, components::Vector{Int32})
    stamp = string(m.name, "_", Dates.format(Dates.now(), "yyyy_mm_dd_HH:MM"))
    if length(components) == 1
        id = components[1]
        label = compound_label(db, ds, id)
        isempty(label) || (stamp = string(stamp, "_", replace(label, r"\s+" => "-")))
    end
    taken = Set(Iterators.flatten(experiment_tags(m, ds)))
    name, n = stamp, 1
    while name in taken
        n += 1
        name = string(stamp, "_", n)
    end
    return name
end

# The IUPAC name of a compound of a dataset, from the compound database when it knows it, and
# otherwise the name that the dataset has.
function compound_label(db::Database, ds::Dataset, id::Integer)
    cdb = compounds_of(db)
    key = ds.compounds.inchikey[id]
    if cdb !== nothing && !isempty(key)
        row = findfirst(==(key), cdb.inchikey)
        row !== nothing && !isempty(cdb.iupac[row]) && return String(cdb.iupac[row])
    end
    names = ds.compounds.names[id]
    return isempty(names) ? "" : String(first(names))
end

# Where the points `index` of the view are: for each part, the positions in its rows. `index` is
# the row of `table(view)`, whose order is the one of the parts.
function rows_of_index(v::DatabaseView, index)
    n = length(v)
    wanted = index === nothing ? (1:n) : (index isa Integer ? [index] : collect(index))
    for i in wanted
        1 <= i <= n || throw(
            ArgumentError(
                "the index $i is not in the selection, which has $n points (1:$n)",
            ),
        )
    end
    found = Vector{Vector{Int}}(undef, length(v.parts))
    start = 0
    for (k, p) in enumerate(v.parts)
        found[k] = [i - start for i in wanted if start < i <= start + length(p)]
        start += length(p)
    end
    return found
end

# The experiments (ids) that the points `index` of a view belong to, for each database:
# `(position of the database, ids)`.
function experiments_of_index(v::DatabaseView, index)
    found = rows_of_index(v, index)
    targets = Tuple{Int,Vector{Int32}}[]
    for (k, p) in enumerate(v.parts)
        isempty(found[k]) && continue
        i = v.index[k]
        ids = unique(Int32[p.dataset.measurements.experiment[p.rows[r]] for r in found[k]])
        j = findfirst(t -> t[1] == i, targets)
        j === nothing ? push!(targets, (i, ids)) : Base.union!(targets[j][2], ids)
    end
    return targets
end

# The publications that cite each name, by name.
function cited_names(db::Database)
    cited = Dict{String,Vector{String}}()
    for p in publications(db), tag in p.experiments
        push!(get!(cited, tag, String[]), isempty(p.name) ? "(all data)" : p.name)
    end
    return cited
end

# The names of an experiment after a change: `remove` is `nothing`, `:all` or a set of names;
# `rename` is a `old => new` pair; `add` is a name or `nothing`.
function changed_tags(tags::Vector{String}, add, remove, rename)
    out = copy(tags)
    if remove === :all
        empty!(out)
    elseif remove !== nothing
        filter!(!in(remove), out)
    end
    if rename !== nothing
        out = [t == rename.first ? rename.second : t for t in out]
    end
    add === nothing || add in out || push!(out, add)
    return unique!(out)
end

# Apply a change of names to the experiments `targets` (`(position of a database, ids)`). Nothing
# is changed unless `confirm`; the result says what would change. A name that a publication cites
# cannot vanish from the databases, unless `renamed` says that the publications follow it.
function edit_names!(
    db::Database,
    targets;
    add = nothing,
    remove = nothing,
    rename = nothing,
    confirm::Bool,
    event::String,
    renamed = nothing,
)
    changes = Dict{Int,Dict{Int32,Vector{String}}}()
    experiments = 0
    for (i, ids) in targets
        m = db.members[i]
        old = experiment_tags(m, member_dataset(m))
        new = Dict{Int32,Vector{String}}()
        for e in ids
            tags = changed_tags(old[e], add, remove, rename)
            if tags != old[e]
                new[e] = tags
                experiments += 1
            end
        end
        isempty(new) || (changes[i] = new)
    end
    before, after = Set{String}(), Set{String}()
    for (i, m) in enumerate(db.members)
        lists = experiment_tags(m, member_dataset(m))
        for tags in lists
            Base.union!(before, tags)
        end
        for (e, tags) in enumerate(lists)
            Base.union!(
                after,
                get(get(changes, i, Dict{Int32,Vector{String}}()), Int32(e), tags),
            )
        end
    end
    vanished = sort!(collect(setdiff(before, after)))
    cited = cited_names(db)
    following = renamed === nothing ? String[] : String[renamed.first]
    blocked = [t for t in vanished if haskey(cited, t) && !(t in following)]
    isempty(blocked) || throw(
        ArgumentError(
            "the name $(join(repr.(blocked), ", ")) is used by the publication $(join(repr.(unique(vcat((cited[t] for t in blocked)...))), ", ")) " *
            "and no experiment would keep it: change the publication first " *
            "(`remove_from_publication!`), or use `modify_name!(db, old, new)`, which changes it in the publications too",
        ),
    )
    plan = (;
        changed = false,
        experiments,
        databases = [db.members[i].name for i in sort!(collect(keys(changes)))],
        publications = sort!(unique(vcat([get(cited, t, String[]) for t in vanished]...))),
    )
    (confirm && experiments > 0) || return plan
    for (i, new) in changes
        m = db.members[i]
        if m.kind === :thermoml
            ds = member_dataset(m)
            names = archive_names(m)
            for (e, tags) in new
                key = (
                    ds.references.doi[ds.experiments.reference[e]],
                    ds.experiments.number[e],
                )
                isempty(tags) ? delete!(names, key) : (names[key] = tags)
            end
            write_archive_names(m)
        else
            writable_member(db, m.name)
            grown = copy_dataset(member_dataset(m))
            drop_names!(grown, collect(keys(new)))
            for (e, tags) in new, tag in tags
                push_name!(grown, e, tag)
            end
            touch!(grown)
            replace_dataset!(db, m, grown, event, string("experiments=", length(new)))
        end
    end
    if renamed !== nothing
        for p in publications(db)
            renamed.first in p.experiments || continue
            fresh =
                unique!([t == renamed.first ? renamed.second : t for t in p.experiments])
            update_publication!(db, p.name, q -> with_experiments(q, fresh))
        end
    end
    return (; plan..., changed = true)
end

"""
    add_name!(view, name, index = nothing) -> NamedTuple

Add the name `name` to the experiments of the points of a selection, whatever the database they
are in (the ThermoML archive too: its names are kept in a file beside it, not in the archive). The
names that an experiment already has stay: an experiment can have several, so a name can mark a
group ("the toluene comparison") without losing the name of the article. `index` are positions in
the selection, the rows of [`table`](@ref)`(view)` (a number, a range or a vector); without it
every experiment of the selection gets the name. The whole experiment is named even if the points
chosen are some of its points.

```julia
v = points(db; source = "my_lab", property = "Viscosity")
add_name!(v, "paper-viscosity")          # all the experiments of the selection
add_name!(v, "bench-A-run-3", 5:8)       # those of the points 5 to 8 of the table
points(db; experiment = "paper-viscosity")
```

An experiment added to a database of yours already has a name, `<database>_yyyy_mm_dd_HH:MM` (and
`_<compound>` for one pure substance). In memory until [`save_database`](@ref); a selection made
before is out of date afterwards, select the points again. See [`modify_name!`](@ref) and
[`remove_name!`](@ref).
"""
function add_name!(v::DatabaseView, name::AbstractString, index = nothing)
    text = String(strip(name))
    isempty(text) && throw(ArgumentError("a name cannot be empty"))
    return edit_names!(
        v.database,
        experiments_of_index(v, index);
        add = text,
        confirm = true,
        event = "experiments_named",
    )
end

"""
    modify_name!(db, old, new; confirm = false) -> NamedTuple
    modify_name!(view, old, new, index = nothing; confirm = false) -> NamedTuple

Change the name `old` to `new`. With the database, in every experiment that has it, in all the
databases, and the publications that cite `old` follow it. With a selection, only in the
experiments of its points (or of the points `index` of its table); a publication cannot be left
with a name that no experiment has, so this form is refused when that would happen.

Like [`move_reference!`](@ref), nothing changes unless `confirm = true`; the result says what would
change, `(changed, experiments, databases, publications)`.
"""
function modify_name!(
    db::Database,
    old::AbstractString,
    new::AbstractString;
    confirm::Bool = false,
)
    to = String(strip(new))
    isempty(to) && throw(ArgumentError("a name cannot be empty"))
    targets = Tuple{Int,Vector{Int32}}[]
    for (i, m) in enumerate(db.members)
        tags = experiment_tags(m, member_dataset(m))
        ids = Int32[e for e in eachindex(tags) if old in tags[e]]
        isempty(ids) || push!(targets, (i, ids))
    end
    isempty(targets) && throw(ArgumentError("no experiment is called \"$old\""))
    return edit_names!(
        db,
        targets;
        rename = String(old) => to,
        renamed = String(old) => to,
        confirm,
        event = "experiments_renamed",
    )
end

function modify_name!(
    v::DatabaseView,
    old::AbstractString,
    new::AbstractString,
    index = nothing;
    confirm::Bool = false,
)
    to = String(strip(new))
    isempty(to) && throw(ArgumentError("a name cannot be empty"))
    targets = experiments_of_index(v, index)
    held = [
        (
            i,
            Int32[
                e for e in ids if old in experiment_tags(
                    v.database.members[i],
                    member_dataset(v.database.members[i]),
                )[e]
            ],
        ) for (i, ids) in targets
    ]
    filter!(t -> !isempty(t[2]), held)
    isempty(held) &&
        throw(ArgumentError("no experiment of the selection is called \"$old\""))
    return edit_names!(
        v.database,
        held;
        rename = String(old) => to,
        confirm,
        event = "experiments_renamed",
    )
end

"""
    remove_name!(view, names, index = nothing; confirm = false) -> NamedTuple

Take the name `names` (a string, or a vector of strings) away from the experiments of the points
of a selection, and keep the others; with `true` instead of the names, take all of them away (an
experiment can be left with no name). A name that a publication cites cannot disappear from all
the experiments: take it out of the publication first ([`remove_from_publication!`](@ref)).

Nothing changes unless `confirm = true`; the result says what would change,
`(changed, experiments, databases, publications)`. See [`add_name!`](@ref).
"""
function remove_name!(
    v::DatabaseView,
    names::Union{Bool,AbstractString,AbstractVector{<:AbstractString}},
    index = nothing;
    confirm::Bool = false,
)
    names === false && throw(
        ArgumentError(
            "say which names to take away (a string or a vector of strings), or `true` for all",
        ),
    )
    which = if names === true
        :all
    else
        Set(String.(names isa AbstractString ? [names] : names))
    end
    which isa Set &&
        isempty(which) &&
        throw(ArgumentError("no name was given to take away"))
    return edit_names!(
        v.database,
        experiments_of_index(v, index);
        remove = which,
        confirm,
        event = "experiments_unnamed",
    )
end

"""
    experiment_names(view) -> Vector{Vector{String}}

The names of the experiment of each point of a selection, in the order of its table (empty for an
experiment with no name).
"""
function experiment_names(v::DatabaseView)
    out = Vector{String}[]
    for (k, p) in enumerate(v.parts)
        tags = experiment_tags(v.database.members[v.index[k]], p.dataset)
        append!(out, tags[p.dataset.measurements.experiment[p.rows]])
    end
    return out
end

# The experiments of a member that have a name that the criterion matches (see `property_matcher`).
function named_experiments(m::Member, ds::Dataset, wanted)
    matcher = property_matcher(wanted)
    tags = experiment_tags(m, ds)
    return Int32[e for e in eachindex(tags) if any(matcher, tags[e])]
end
