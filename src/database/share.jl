# Sharing the databases of the user between computers and people. An export is one file, `.tdb`,
# that is a gzip-compressed tar with, for each database, its data (`dataset.jld2`), its description
# (`member.toml`) and its audit log (`audit.log`, `audit.toml`), and a `manifest.toml` with the
# SHA-256 of every file and the state of every log.
#
# The log travels with the data so that a merge is auditable. Importing checks the digests and the
# chain of hashes of the log before anything is written. Each computer keeps a log of its own
# (a copy of a log that is edited on two computers would fork), so the destination records the event
# `database_imported` with the identifier of the log of the source, how many lines it had, its last
# hash and the digest of the file, and keeps the log of the source whole in `imports/`.

const SHARE_FORMAT = "thermophysicaldb-share"
const SHARE_VERSION = 1
const SHARE_MANIFEST = "manifest.toml"
const SHARE_IMPORTS = "imports"
const SHARE_CONFLICTS = (:error, :rename, :replace)

# What a file of this kind may contain; anything else is refused before it is unpacked.
const SHARE_FILE_REGEX =
    r"^(manifest\.toml|[A-Za-z0-9][A-Za-z0-9_. -]*/(dataset\.jld2|member\.toml|audit\.log|audit\.toml))$"
const SHARE_DIR_REGEX = r"^[A-Za-z0-9][A-Za-z0-9_. -]*$"

# ----------------------------------------------------------------------------------
# Unsaved changes
# ----------------------------------------------------------------------------------

# The description file of a saved database, or `nothing`.
function member_meta(m::Member)
    path = joinpath(dirname(m.path), MEMBER_META)
    isfile(path) || return nothing
    try
        return TOML.parsefile(path)
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
end

# Whether the database in memory has points or edits that its file does not have. A database that
# is not open has not been touched in this session.
function unsaved_changes(m::Member, meta)
    is_open(m) || return false
    ds = m.dataset::Dataset
    length(ds.measurements) != get(meta, "measurements", -1) && return true
    saved = stamp_seconds(get(meta, "modified_at", stamp_text(0.0)))
    return ds.stamps.modified > saved + 1.0
end

# ----------------------------------------------------------------------------------
# Export
# ----------------------------------------------------------------------------------

# The databases to export: the ones called, or every database of the user.
function share_members(db::Database, names)
    if names === nothing
        own = [m for m in db.members if m.kind !== :thermoml]
        isempty(own) && throw(ArgumentError("there is no database of your own to export"))
        return own
    end
    list = names isa AbstractString ? [names] : collect(names)
    isempty(list) && throw(ArgumentError("say which databases to export"))
    members = Member[writable_member(db, String(n)) for n in list]
    length(unique(m.name for m in members)) == length(members) ||
        throw(ArgumentError("a database is named twice"))
    return members
end

# A database can be exported only from a file that exists. Changes that are only in memory are not
# part of the export; the person is told, and saves first if they are to be included.
function check_exportable(m::Member)
    occursin(SHARE_DIR_REGEX, m.name) || throw(
        ArgumentError("the name \"$(m.name)\" cannot be used as a folder of an export"),
    )
    meta = member_meta(m)
    (meta === nothing || !isfile(m.path)) && throw(
        ArgumentError(
            "the database \"$(m.name)\" has not been saved; save it first with save_database(db, \"$(m.name)\")",
        ),
    )
    if unsaved_changes(m, meta)
        @warn "The database \"$(m.name)\" has changes that were not saved; the export has the saved version ($(meta["measurements"]) points, not the $(length(m.dataset.measurements)) in memory). Save it first to include them." database =
            m.name
    end
    return meta
end

# Records the export in the log of the database, then copies the files, the log included, to the
# folder of the export, and describes them for the manifest.
function stage_database!(staging::AbstractString, m::Member, file::AbstractString)
    dir = dirname(m.path)
    audited(dir, "database_export", m.name) do
        audit_record!(
            dir,
            "database_exported",
            m.name;
            sha256 = logged_sha256(m.path),
            detail = "file=$file",
        )
    end
    isfile(audit_log_path(dir)) || throw(
        ArgumentError(
            "the audit log of \"$(m.name)\" could not be written, and an export needs it",
        ),
    )
    target = joinpath(staging, m.name)
    mkpath(target)
    for source in
        (m.path, joinpath(dir, MEMBER_META), audit_log_path(dir), audit_id_path(dir))
        isfile(source) && cp(source, joinpath(target, basename(source)))
    end
    return share_entry(m, target)
end

# The facts of one database that the manifest keeps (and that an import checks).
function share_entry(m::Member, folder::AbstractString)
    meta = TOML.parsefile(joinpath(folder, MEMBER_META))
    ok, uuid, lines, head, line, problem, _ =
        walk_audit_log(audit_log_path(folder), _ -> nothing)
    ok || throw(
        ArgumentError(
            "the audit log of \"$(m.name)\" is damaged (line $line: $problem), so it cannot be exported",
        ),
    )
    return Dict{String,Any}(
        "name" => m.name,
        "kind" => String(m.kind),
        "priority" => m.priority,
        "schema_version" => get(meta, "schema_version", -1),
        "measurements" => get(meta, "measurements", -1),
        "dataset_sha256" => file_sha256(joinpath(folder, MEMBER_FILE)),
        "member_sha256" => file_sha256(joinpath(folder, MEMBER_META)),
        "audit_uuid" => uuid,
        "audit_lines" => lines,
        "audit_head" => head,
        "audit_sha256" => file_sha256(audit_log_path(folder)),
    )
end

function write_share_manifest(staging::AbstractString, entries)
    manifest = Dict{String,Any}(
        "format" => SHARE_FORMAT,
        "version" => SHARE_VERSION,
        "exported_at" => utc_timestamp(),
        "package_version" => string(pkgversion(@__MODULE__)),
        "databases" => entries,
    )
    open(io -> TOML.print(io, manifest), joinpath(staging, SHARE_MANIFEST), "w")
    return nothing
end

# Writes the folder as a gzip-compressed tar, to a temporary name first.
function pack_share(staging::AbstractString, target::AbstractString)
    part = target * ".part"
    try
        open(part, "w") do io
            gz = GzipCompressorStream(io)
            Tar.create(staging, gz)
            close(gz)
        end
        mv(part, target; force = true)
    finally
        rm(part; force = true)
    end
    return nothing
end

"""
    export_database(db, names, path; overwrite = false) -> NamedTuple

Write the databases `names` (a name, a vector of names, or `nothing` for every database of your
own) to the file `path`, a `.tdb`, to take them to another computer or to give them to someone, who
reads them with [`import_database!`](@ref). Only databases of your own can be exported (`:user` and
`:literature`); the ThermoML archive can be downloaded again.

What is exported is what was **saved**: a database that was never saved is refused, and one that
has changes only in memory is exported as it was saved, with a warning. Save first
([`save_database`](@ref)) to include the changes.

The `.tdb` is a gzip-compressed tar, so any tool that opens a `.tar.gz` opens it. It holds, for each
database, the data, the description and the audit log, and a `manifest.toml` with the SHA-256 of
every file. The log goes with the data so that what is done with them in another place can be
audited: the export is recorded in the log of the database (`database_exported`) before the log is
copied, so the copy has it. The answer has the `path`, the size (`bytes`), the `sha256` of the file
and what was exported (`databases`).

```julia
export_database(db, "my_lab", "hexane.tdb")
export_database(db, ["my_lab", "articles"], "lab.tdb")
```
"""
function export_database(db::Database, names, path::AbstractString; overwrite::Bool = false)
    members = share_members(db, names)
    target = String(path)
    (isfile(target) && !overwrite) && throw(
        ArgumentError(
            "$target already exists; choose another name or pass overwrite = true",
        ),
    )
    foreach(check_exportable, members)
    staging = mktempdir()
    entries = Dict{String,Any}[]
    try
        for m in members
            push!(entries, stage_database!(staging, m, basename(target)))
        end
        write_share_manifest(staging, entries)
        pack_share(staging, target)
    catch err
        for m in members
            audit_record!(
                dirname(m.path),
                "database_export_failed",
                m.name;
                detail = error_detail(err),
            )
        end
        rethrow()
    finally
        rm(staging; recursive = true, force = true)
    end
    summary = [
        (
            name = e["name"],
            kind = Symbol(e["kind"]),
            points = e["measurements"],
            audit_uuid = e["audit_uuid"],
            audit_lines = e["audit_lines"],
        ) for e in entries
    ]
    return (
        path = target,
        bytes = filesize(target),
        sha256 = file_sha256(target),
        databases = summary,
    )
end

# ----------------------------------------------------------------------------------
# Import
# ----------------------------------------------------------------------------------

function copy_stream(source::IO, target::IO)
    buffer = Vector{UInt8}(undef, 1 << 20)
    while !eof(source)
        n = readbytes!(source, buffer)
        write(target, view(buffer, 1:n))
    end
    return nothing
end

# Unpacks the file into `files`, after checking everything that it holds: only regular files and
# folders with the names of an export, so that nothing is written outside of `files`.
function unpack_share!(work::AbstractString, path::AbstractString)
    tarball = joinpath(work, "bundle.tar")
    files = joinpath(work, "files")
    try
        open(path, "r") do io
            open(tarball, "w") do out
                copy_stream(GzipDecompressorStream(io), out)
            end
        end
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("$path is not a .tdb file (it is not a gzip-compressed tar)"))
    end
    headers = try
        Tar.list(tarball)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("$path is not a .tdb file (the tar inside is damaged)"))
    end
    for h in headers
        ok =
            h.type === :file ? occursin(SHARE_FILE_REGEX, h.path) :
            h.type === :directory && occursin(SHARE_DIR_REGEX, rstrip(h.path, '/'))
        ok || throw(
            ArgumentError("$path is not a valid .tdb file: it has the entry \"$(h.path)\""),
        )
    end
    Tar.extract(tarball, files)
    return files
end

# Reads the manifest and checks every database of it against the files: the digests, the schema
# version and the chain of hashes of the log. Nothing is trusted that is not checked.
function read_share(files::AbstractString, path::AbstractString)
    manifest_path = joinpath(files, SHARE_MANIFEST)
    isfile(manifest_path) ||
        throw(ArgumentError("$path is not a .tdb file: it has no $SHARE_MANIFEST"))
    manifest = TOML.parsefile(manifest_path)
    get(manifest, "format", "") == SHARE_FORMAT ||
        throw(ArgumentError("$path is not a .tdb file of this package"))
    version = get(manifest, "version", -1)
    version == SHARE_VERSION || throw(
        ArgumentError(
            "$path has the format version $version; this version of the package reads $SHARE_VERSION (update the package, or export it again)",
        ),
    )
    entries = get(manifest, "databases", [])
    isempty(entries) && throw(ArgumentError("$path has no database"))
    return [check_share_entry(files, e, path) for e in entries]
end

function expect_digest(file::AbstractString, expected, what, name)
    isfile(file) || throw(ArgumentError("the file of the $what of \"$name\" is missing"))
    found = file_sha256(file)
    found == expected || throw(
        ArgumentError(
            "the $what of \"$name\" does not match the manifest (expected $expected, found $found): the file was changed or damaged",
        ),
    )
    return nothing
end

function check_share_entry(files::AbstractString, e, path::AbstractString)
    name = String(get(e, "name", ""))
    occursin(SHARE_DIR_REGEX, name) ||
        throw(ArgumentError("$path has a database with the invalid name \"$name\""))
    folder = joinpath(files, name)
    expect_digest(joinpath(folder, MEMBER_FILE), get(e, "dataset_sha256", ""), "data", name)
    expect_digest(
        joinpath(folder, MEMBER_META),
        get(e, "member_sha256", ""),
        "description",
        name,
    )
    expect_digest(audit_log_path(folder), get(e, "audit_sha256", ""), "audit log", name)
    meta = TOML.parsefile(joinpath(folder, MEMBER_META))
    get(meta, "format", "") == MEMBER_FORMAT ||
        throw(ArgumentError("\"$name\" is not a database of this package"))
    version = get(meta, "schema_version", -1)
    version == SCHEMA_VERSION || throw(
        ArgumentError(
            "\"$name\" was saved with schema version $version and this version of the package reads $SCHEMA_VERSION",
        ),
    )
    kind = Symbol(get(meta, "kind", "user"))
    kind in (:literature, :user) ||
        throw(ArgumentError("the kind :$kind of \"$name\" is not a database of your own"))
    ok, uuid, lines, head, line, problem, _ =
        walk_audit_log(audit_log_path(folder), _ -> nothing)
    ok || throw(
        ArgumentError(
            "the audit log of \"$name\" in $path is damaged (line $line: $problem)",
        ),
    )
    (
        uuid == get(e, "audit_uuid", "") &&
        lines == get(e, "audit_lines", -1) &&
        head == get(e, "audit_head", "")
    ) || throw(ArgumentError("the audit log of \"$name\" does not match the manifest"))
    return (;
        name,
        folder,
        meta,
        kind,
        priority = Int(get(meta, "priority", DEFAULT_PRIORITY[kind])),
        dataset_sha256 = String(e["dataset_sha256"]),
        audit_uuid = uuid,
        audit_lines = lines,
        audit_head = head,
        counts = audit_tail(audit_log_path(folder)).counts,
    )
end

# The name that a database gets here, and what to do about a database that has it already. All the
# checks are made before the first file is written.
function plan_import(db::Database, entry, wanted, mode::Symbol, dir::AbstractString)
    base = String(strip(something(wanted, entry.name)))
    (occursin(MEMBER_NAME_REGEX, base) && length(base) <= 64) || throw(
        ArgumentError(
            "the name of a database is a folder name (letters, digits, _ - . and spaces, at most 64), got \"$base\"",
        ),
    )
    lowercase(base) == "thermoml" &&
        throw(ArgumentError("the name \"thermoml\" belongs to the archive"))
    taken(n) =
        any(m -> lowercase(m.name) == lowercase(n), db.members) ||
        isfile(joinpath(dir, n, MEMBER_META))
    target, replaced = base, false
    if taken(base)
        mode === :error && throw(
            ArgumentError(
                "there is already a database called \"$base\"; import it with name = \"another name\", with on_conflict = :rename to keep both, or with on_conflict = :replace to substitute it",
            ),
        )
        if mode === :rename
            k = 2
            while taken("$base-$k")
                k += 1
            end
            target = "$base-$k"
        else
            replaced = true
            check_replaceable(db, base)
        end
    end
    return (; entry, target, replaced, folder = joinpath(dir, target))
end

# A database is replaced only if what it has is saved: the data that are only in memory would be lost.
function check_replaceable(db::Database, name::AbstractString)
    i = findfirst(m -> lowercase(m.name) == lowercase(name), db.members)
    i === nothing && return nothing
    m = db.members[i]
    m.kind === :thermoml && throw(ArgumentError("the ThermoML archive is never replaced"))
    meta = member_meta(m)
    (meta === nothing || unsaved_changes(m, meta)) && throw(
        ArgumentError(
            "\"$name\" has data that were not saved and would be lost; save it with save_database(db, \"$name\") or import with on_conflict = :rename",
        ),
    )
    return nothing
end

# Puts the files of one database in its folder. The description is written last, because it is what
# makes the folder a database; an old one is removed first so that it never vouches for other data.
place_database!(p) = place_database!(p, String(p.folder), String(p.entry.folder))

function place_database!(p, folder::String, source::String)
    e = p.entry
    mkpath(folder)
    data = joinpath(folder, MEMBER_FILE)
    meta_path = joinpath(folder, MEMBER_META)
    rm(meta_path; force = true)
    cp(joinpath(source, MEMBER_FILE), data * ".part"; force = true)
    mv(data * ".part", data; force = true)
    kept = joinpath(
        folder,
        SHARE_IMPORTS,
        string(e.audit_uuid, "-", e.audit_lines, "-", first(e.audit_head, 12), ".log"),
    )
    mkpath(dirname(kept))
    cp(audit_log_path(source), kept; force = true)
    meta = copy(e.meta)
    meta["name"] = p.target
    meta["saved_at"] = utc_timestamp()
    open(io -> TOML.print(io, meta), meta_path * ".tmp", "w")
    mv(meta_path * ".tmp", meta_path; force = true)
    return data
end

function install_import!(db::Database, p, bundle_sha256::AbstractString, mode::Symbol)
    e = p.entry
    old = nothing
    if p.replaced
        i = findfirst(m -> lowercase(m.name) == lowercase(p.target), db.members)
        if i !== nothing
            old = db.members[i]
            remove_member!(db, old.name)
        end
    end
    member = try
        audited(p.folder, "database_import", p.target) do
            data = place_database!(p)
            detail = string(
                "source=",
                e.audit_uuid,
                " source_name=",
                e.name,
                " source_lines=",
                e.audit_lines,
                " source_head=",
                e.audit_head,
                " bundle_sha256=",
                bundle_sha256,
                " on_conflict=",
                mode,
                p.replaced ? " replaced=true" : "",
            )
            audit_record!(
                p.folder,
                "database_imported",
                p.target;
                detail,
                sha256 = e.dataset_sha256,
                counts = e.counts,
            )
            m = Member(
                p.target;
                kind = e.kind,
                path = data,
                priority = e.priority,
                persistent = true,
            )
            member_catalog(m)    # reads the file: a database that cannot be read fails here
            m
        end
    catch
        old === nothing || add_member!(db, old)
        rethrow()
    end
    add_member!(db, member)
    return member
end

"""
    import_database!(db, path; name = nothing, only = nothing, on_conflict = :error,
                     dir = databases_dir()) -> Vector{Member}

Read a `.tdb` made by [`export_database`](@ref) and add its databases to `db`, saved in `dir` so
that [`database`](@ref) opens them in every session. Nothing is written until the whole file has
been checked: the SHA-256 of every file against the manifest, the version of the schema, and the
chain of hashes of the audit log of every database, so a file that was changed or damaged is
refused with the reason.

`name` gives a different name to the database (when the file has one), `only` takes some of the
databases of the file by name. `on_conflict` says what to do when a database with that name
exists: `:error` (the default) refuses, `:rename` imports it as `name-2`, `name-3`... and keeps
both, and `:replace` substitutes it (refused if the one that is replaced has data that were not
saved).

The import is auditable. The log of the database here records `database_imported` with the
identifier (`source`) and the number of lines (`source_lines`) and last hash (`source_head`) of the
log that came in the file, and the SHA-256 of the file (`bundle_sha256`); the log that came is kept
whole in the folder `imports/` of the database. Read it with [`audit_log`](@ref); the logs of both
computers are checked with [`verify_audit_log`](@ref). Several databases, in one `Database`, are
combined by [`points`](@ref) as usual, with [`duplicates`](@ref) and [`conflicts`](@ref) to
compare what they repeat.

```julia
import_database!(db, "hexane.tdb")
import_database!(db, "lab.tdb"; only = "articles", name = "articles_home")
```
"""
function import_database!(
    db::Database,
    path::AbstractString;
    name::Union{Nothing,AbstractString} = nothing,
    only::Union{Nothing,AbstractString,AbstractVector} = nothing,
    on_conflict::Symbol = :error,
    dir::AbstractString = databases_dir(),
)
    on_conflict in SHARE_CONFLICTS || throw(
        ArgumentError(
            "on_conflict is one of $(join(repr.(SHARE_CONFLICTS), ", ")), got :$on_conflict",
        ),
    )
    isfile(path) || throw(ArgumentError("the file $path does not exist"))
    bundle_sha256 = file_sha256(path)
    work = mktempdir()
    try
        entries = read_share(unpack_share!(work, path), path)
        chosen = choose_entries(entries, only, path)
        (name === nothing || length(chosen) == 1) || throw(
            ArgumentError(
                "name gives a name to one database; the file has $(length(chosen)) (choose one with only = \"...\")",
            ),
        )
        plan = [plan_import(db, e, name, on_conflict, dir) for e in chosen]
        length(unique(lowercase(p.target) for p in plan)) == length(plan) ||
            throw(ArgumentError("two databases would get the same name"))
        return Member[install_import!(db, p, bundle_sha256, on_conflict) for p in plan]
    finally
        rm(work; recursive = true, force = true)
    end
end

function choose_entries(entries, only, path::AbstractString)
    only === nothing && return entries
    wanted = only isa AbstractString ? [String(only)] : String.(only)
    known = [e.name for e in entries]
    for w in wanted
        w in known || throw(
            ArgumentError(
                "$path has no database called \"$w\"; it has $(join(repr.(known), ", "))",
            ),
        )
    end
    return [e for e in entries if e.name in wanted]
end
