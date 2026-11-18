# Removing a database, or emptying one. A database that was saved is a folder (`<databases_dir()>/name`);
# removing it moves the folder to the temporary directory, where it is deleted in due course by the
# system, so that nothing is lost at once and nothing is kept for ever.

const REMOVED_FOLDER = "ThermophysicalDB-removed"

# The folder, in the temporary directory, that receives the databases that are removed.
removed_root() = joinpath(tempdir(), REMOVED_FOLDER)

# A name for the removed folder that is not taken: `name-20261117T161700`, then `-2`, `-3`...
function removed_destination(root::String, name::String)
    stamp = Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSS")
    base = joinpath(root, string(name, "-", stamp))
    path = base
    k = 1
    while ispath(path)
        k += 1
        path = string(base, "-", k)
    end
    return path
end

# Whether the database has a folder on disk that `database()` would open.
has_folder(m::Member) = !isempty(m.path) && isfile(joinpath(dirname(m.path), MEMBER_META))

# Whether removing the database would lose points that exist only in memory.
function loses_points(m::Member)
    is_open(m) || return false
    meta = member_meta(m)
    if meta === nothing
        ds = m.dataset::Dataset
        return length(ds.measurements) > 0 || length(ds.references) > 0
    end
    return unsaved_changes(m, meta)
end

"""
    remove_database!(db, name; force = false, to = <temporary folder>) -> String
    remove_database!(db, names; force = false, to = <temporary folder>) -> Vector{String}

Take the database `name` (or every database in `names`) out of `db`. A database that was saved
is not deleted: its folder, with the audit log, is moved to a folder of the temporary directory
(`<tempdir()>/ThermophysicalDB-removed`), where the system deletes it in due course, and the
path it was moved to is returned (`""` for a database that only existed in memory). To keep a
database for good, copy that folder, or [`export_database`](@ref) it first. The event
`database_removed` is written in its log before it is moved.

A database with points that were not saved is not removed unless `force = true`, because those
points exist nowhere else; save them with [`save_database`](@ref) first, or say that they can go.
Nothing is removed if any of the names is not valid (the ThermoML archive is never removed).
`to` is the folder that receives what is removed, for when the temporary directory is not the
place.

```julia
backup = remove_database!(db, "my_lab")
```

To keep a database and empty it, use [`clear_database!`](@ref).
"""
function remove_database!(
    db::Database,
    names::AbstractVector{<:AbstractString};
    force::Bool = false,
    to::AbstractString = removed_root(),
)::Vector{String}
    isempty(names) && throw(ArgumentError("say which databases to remove"))
    members = Member[writable_member(db, String(n)) for n in names]
    length(unique(m.name for m in members)) == length(members) ||
        throw(ArgumentError("a database is named twice"))
    if !force
        for m in members
            loses_points(m) && throw(
                ArgumentError(
                    "\"$(m.name)\" has points that were not saved and would be lost; save it with save_database(db, \"$(m.name)\") or remove it with force = true",
                ),
            )
        end
    end
    moved = String[]
    for m in members
        push!(moved, remove_one!(db, m, String(to)))
    end
    return moved
end

function remove_database!(
    db::Database,
    name::AbstractString;
    force::Bool = false,
    to::AbstractString = removed_root(),
)::String
    return only(remove_database!(db, [name]; force, to))
end

function remove_one!(db::Database, m::Member, root::String)::String
    destination = ""
    if has_folder(m)
        folder = dirname(m.path)
        destination = removed_destination(root, m.name)
        meta = member_meta(m)
        points = meta === nothing ? -1 : get(meta, "measurements", -1)
        audited(folder, "database_remove", m.name) do
            audit_record!(
                folder,
                "database_removed",
                m.name;
                detail = string("moved_to=", destination, " measurements=", points),
            )
            mkpath(root)
            mv(folder, destination)
        end
    end
    remove_member!(db, m.name)
    return destination
end

"""
    clear_database!(db, name) -> Member

Empty the database `name`: it keeps its name, kind, priority and creation time, and loses all its
references, experiments and points. This happens in memory; the folder on disk is replaced by the
empty database the next time you call [`save_database`](@ref), so until then restarting Julia
brings the saved data back. To rebuild a database from a script, start with this call.
"""
function clear_database!(db::Database, name::AbstractString)
    m = writable_member(db, String(name))
    created = member_stamps(m)[1]
    ds = Dataset()
    ds.stamps.created = created
    lock(m.lock) do
        m.dataset = ds
    end
    touch!(ds)
    refresh!(db, m)
    return m
end
