# Reading the seed files, and the on-disk caches of the compound database.
#
#   <root>/compounds/seed/*.tsv      the downloaded lists, verified against their digests
#   <root>/compounds/seed.jld2       the parsed seed (written to a .part file, then moved)
#   <root>/compounds/seed.toml       written LAST: marks a complete cache and records the commit
#   <root>/compounds/custom.jld2     the rows added or changed by the user or fetched later
#
# The seed can always be rebuilt from the lists; the custom rows never are, so an update of
# the seed leaves them alone and they are laid over the new seed when the database loads.

compounds_dir(; create::Bool = false) = subdir("compounds", create)

seed_cache_path(dir::AbstractString) = joinpath(dir, "seed.jld2")
seed_meta_path(dir::AbstractString) = joinpath(dir, "seed.toml")
custom_cache_path(dir::AbstractString) = joinpath(dir, "custom.jld2")

# ----------------------------------------------------------------------------------
# Reading a seed file
# ----------------------------------------------------------------------------------

# Columns of the lists: CID, CAS, formula, molar mass, SMILES, InChI (no prefix), InChIKey,
# IUPAC name, common name, then any number of synonyms.
const SEED_MIN_FIELDS = 9

function read_seed_file!(db::CompoundDB, path::AbstractString, file::SeedFile)
    added = 0
    skipped = 0
    for line in eachline(path)
        isempty(line) && continue
        fields = split(line, '\t')
        if length(fields) < SEED_MIN_FIELDS
            skipped += 1
            continue
        end
        names = String[]
        push!(names, strip(fields[9]))
        push!(names, strip(fields[8]))
        for i = 10:length(fields)
            push!(names, strip(fields[i]))
        end
        inchikey = strip(fields[7])
        if isempty(inchikey) && all(isempty, names)
            skipped += 1
            continue
        end
        cid = tryparse(Int64, strip(fields[1]))
        mass = tryparse(Float64, strip(fields[4]))
        insert_record!(
            db;
            inchikey,
            inchi = fields[6],
            cas = fields[2],
            cid = cid === nothing ? -1 : cid,
            formula = strip(fields[3]),
            molar_mass = mass === nothing ? NaN : mass,
            smiles = strip(fields[5]),
            iupac = strip(fields[8]),
            names,
            source = file.source,
            # a later file replaces the values of an earlier one, as the lists intend
            override = true,
        )
        added += 1
    end
    return added, skipped
end

function build_seed(paths::AbstractVector{<:AbstractString}, seed::CompoundSeed)
    db = CompoundDB()
    skipped = 0
    for (path, file) in zip(paths, seed.files)
        _, bad = read_seed_file!(db, path, file)
        skipped += bad
    end
    db.meta["skipped_lines"] = skipped
    return db
end

# ----------------------------------------------------------------------------------
# Rows <-> flat columns
# ----------------------------------------------------------------------------------

# Text columns are stored as one block of bytes with a newline between the values, which
# is both much smaller and much faster to read back than tens of thousands of separate
# strings (the lists have about a million names). A newline inside a value is replaced by a
# space; the lists contain none. The names of all rows are one column, with a count per row.
pack_strings(values) =
    Vector{UInt8}(codeunits(join((replace(v, '\n' => ' ') for v in values), '\n')))

function unpack_strings(bytes::AbstractVector{UInt8}, n::Integer)
    out = Vector{String}(undef, n)
    n == 0 && return out
    start = 1
    k = 0
    for i in eachindex(bytes)
        if bytes[i] == 0x0a
            k < n ||
                throw(ArgumentError("the stored text has more than the $n values expected"))
            out[k+=1] = String(bytes[start:(i-1)])
            start = i + 1
        end
    end
    k < n || throw(ArgumentError("the stored text has more than the $n values expected"))
    out[k+=1] = String(bytes[start:end])
    k == n || throw(ArgumentError("the stored text has $k values, expected $n"))
    return out
end

const TEXT_COLUMNS =
    (:inchikey, :inchi, :cas, :formula, :smiles, :iupac, :source, :retrieved)

function store_rows!(sink, db::CompoundDB, rows::AbstractVector{<:Integer})
    sink("nrows", length(rows))
    for column in TEXT_COLUMNS
        sink(string(column), pack_strings(getfield(db, column)[rows]))
    end
    sink("cid", db.cid[rows])
    sink("molar_mass", db.molar_mass[rows])
    counts = Int32[length(db.names[r]) for r in rows]
    sink("name_count", counts)
    sink("names", pack_strings(String[n for r in rows for n in db.names[r]]))
    return nothing
end

function load_rows!(db::CompoundDB, source; custom::Bool)
    n = Int(source("nrows"))
    text = Dict(c => unpack_strings(source(string(c)), n) for c in TEXT_COLUMNS)
    cid = source("cid")
    molar_mass = source("molar_mass")
    counts = source("name_count")
    flat = unpack_strings(source("names"), Int(sum(counts)))
    first_name = 1
    for r = 1:n
        last_name = first_name + counts[r] - 1
        insert_record!(
            db;
            inchikey = text[:inchikey][r],
            inchi = text[:inchi][r],
            cas = text[:cas][r],
            cid = cid[r],
            formula = text[:formula][r],
            molar_mass = molar_mass[r],
            smiles = text[:smiles][r],
            iupac = text[:iupac][r],
            names = view(flat, first_name:last_name),
            source = text[:source][r],
            retrieved = text[:retrieved][r],
            custom,
            override = true,
        )
        first_name = last_name + 1
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Caches
# ----------------------------------------------------------------------------------

function write_jld2(path::AbstractString, fill!::Function)
    part = path * ".part"
    try
        JLD2.jldopen(part, "w") do file
            fill!((key, value) -> (file[key] = value; nothing))
        end
        mv(part, path; force = true)
    finally
        rm(part; force = true)
    end
    return path
end

function write_seed_cache(dir::AbstractString, db::CompoundDB, seed::CompoundSeed)
    mkpath(dir)
    rm(seed_meta_path(dir); force = true)
    rows = findall(!, db.custom)
    write_jld2(seed_cache_path(dir), sink -> store_rows!(sink, db, rows))
    meta = Dict{String,Any}(
        "format" => COMPOUNDS_FORMAT,
        "schema_version" => COMPOUNDS_SCHEMA_VERSION,
        "repository" => seed.repository,
        "commit" => seed.commit,
        "files" => Dict(f.name => f.sha256 for f in seed.files),
        "built_at" => utc_timestamp(),
        "compounds" => length(rows),
        "skipped_lines" => get(db.meta, "skipped_lines", 0),
        "size_bytes" => Int(filesize(seed_cache_path(dir))),
    )
    tmp = seed_meta_path(dir) * ".tmp"
    open(io -> TOML.print(io, meta), tmp, "w")
    mv(tmp, seed_meta_path(dir); force = true)
    return meta
end

"The seed cache when it was built from `seed` with the current schema, else `nothing`."
function read_seed_cache(dir::AbstractString, seed::CompoundSeed)
    data, meta_path = seed_cache_path(dir), seed_meta_path(dir)
    (isfile(data) && isfile(meta_path)) || return nothing
    meta = try
        TOML.parsefile(meta_path)
    catch
        return nothing
    end
    (
        get(meta, "format", "") == COMPOUNDS_FORMAT &&
        get(meta, "schema_version", -1) == COMPOUNDS_SCHEMA_VERSION &&
        get(meta, "commit", "") == seed.commit &&
        get(meta, "files", Dict()) == Dict(f.name => f.sha256 for f in seed.files)
    ) || return nothing
    db = CompoundDB()
    try
        JLD2.jldopen(data, "r") do file
            load_rows!(db, key -> file[key]; custom = false)
        end
    catch err
        err isa InterruptException && rethrow()
        @warn "The cached list of compounds could not be read and will be rebuilt" reason =
            sprint(showerror, err)
        return nothing
    end
    db.meta["seed"] = meta
    return db
end

"""
    save_compounds(db; dir = compounds_dir()) -> String

Store the compounds that you added or changed (see [`register_compound!`](@ref)) next to the
list they were laid over. They are loaded again by [`compound_database`](@ref). Returns
the path of the file.
"""
function save_compounds(db::CompoundDB; dir::AbstractString = compounds_dir())
    mkpath(dir)
    rows = findall(db.custom)
    return write_jld2(custom_cache_path(dir), sink -> store_rows!(sink, db, rows))
end

function load_custom!(db::CompoundDB, dir::AbstractString)
    path = custom_cache_path(dir)
    isfile(path) || return db
    try
        JLD2.jldopen(path, "r") do file
            load_rows!(db, key -> file[key]; custom = true)
        end
    catch err
        err isa InterruptException && rethrow()
        @warn "The file with your own compounds could not be read and was ignored" path reason =
            sprint(showerror, err)
    end
    return db
end

# ----------------------------------------------------------------------------------
# The entry point
# ----------------------------------------------------------------------------------

const COMPOUND_MEMO = Ref{Union{Nothing,Tuple{String,CompoundDB}}}(nothing)

"Drop the in-session copy of the compound database."
function forget_compounds!()
    COMPOUND_MEMO[] = nothing
    return nothing
end

"""
    compound_database(; dir = compounds_dir(), rebuild = false, reload = false,
                      progress = true) -> CompoundDB

The database of compound identifiers: names, CAS number, PubChem CID, formula, molar mass,
SMILES, InChI and InChIKey of about 75 000 compounds, including salts, hydrates and the ions
of brines, ready for [`lookup_compounds`](@ref) and [`link_compounds`](@ref).

The first call downloads the lists (about 45 MB, once) from a fixed commit of the
[chemicals](https://github.com/CalebBell/chemicals) repository (MIT licence; the lists
are derived from PubChem), checks their SHA-256 digests, parses them and saves a binary cache.
Later calls only read the cache and never touch the network. Compounds that you added with
[`register_compound!`](@ref) and stored with [`save_compounds`](@ref) are laid over the list.

The database is kept apart from the ThermoML data: nothing here changes what the archive says.

`rebuild = true` ignores the cache and parses the downloaded lists again; `reload = true`
reads the cache again instead of reusing the copy of this session.
"""
function compound_database(;
    dir::AbstractString = compounds_dir(),
    rebuild::Bool = false,
    reload::Bool = false,
    progress::Bool = true,
    seed::CompoundSeed = CHEMICALS_SEED,
    download = download_file,
)
    memo = COMPOUND_MEMO[]
    if memo !== nothing && !reload && !rebuild && memo[1] == dir
        return memo[2]
    end
    db = rebuild ? nothing : read_seed_cache(dir, seed)
    if db === nothing
        paths = ensure_seed_files(seed, dir; progress, download)
        @info "Building the list of compounds (needed once per version of the list)"
        db = build_seed(paths, seed)
        try
            db.meta["seed"] = write_seed_cache(dir, db, seed)
        catch err
            err isa InterruptException && rethrow()
            @warn "The list was built but could not be cached; it will be rebuilt next time" reason =
                sprint(showerror, err)
        end
    end
    load_custom!(db, dir)
    db.meta["dir"] = String(dir)
    COMPOUND_MEMO[] = (String(dir), db)
    return db
end
