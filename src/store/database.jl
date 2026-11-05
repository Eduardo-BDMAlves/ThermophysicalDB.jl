# What users call: one function that gets them the data.

# (directory, dataset) of the last `database()` call, so asking again in the same session
# is instant and does not touch the network.
const DATABASE_MEMO = Ref{Union{Nothing,Tuple{String,Any}}}(nothing)

"Drop the in-session copy of the database (done after the archive is updated)."
function forget_database!()
    DATABASE_MEMO[] = nothing
    return nothing
end

"""
    database(; update = :notify, reload = false, rebuild = false, dir = thermoml_dir())
        -> Database

The ThermoML database, ready to query with [`points`](@ref).

The first call ever downloads the archive from NIST, parses it and saves a binary cache
next to it, which takes a few minutes. Later sessions only check whether NIST has a newer
archive (`update` as in [`ensure_archive`](@ref): `:notify` warns, `:install` upgrades,
`:never` stays offline) and then load the cache, which is much faster than parsing. A
changed archive or schema version rebuilds the cache automatically.

`prefetch_compounds = n` also asks PubChem, once the database is ready, for the `n` most
measured compounds that the compound database lacks (see [`prefetch_compounds!`](@ref); it
needs the network and downloads the compound database if it is not there yet). It is off by
default, and a failure only warns.

Calling `database()` again in the same session returns the same object immediately;
`reload = true` repeats the update check and the load, `rebuild = true` also ignores the
cache and parses the archive again.

```julia
db = database()
points(db; component = "hexane", property = "Thermal conductivity")
```
"""
function database(;
    update::Symbol = :notify,
    reload::Bool = false,
    rebuild::Bool = false,
    dir::AbstractString = thermoml_dir(),
    progress::Bool = true,
    prefetch_compounds::Integer = 0,
    fetch = fetch_latest_release,
    download = download_file,
)
    memo = DATABASE_MEMO[]
    if memo !== nothing && !reload && !rebuild && memo[1] == dir
        return memo[2]
    end
    manifest = ensure_archive(; update, dir, fetch, download)
    member = if !rebuild && cache_usable(dir, manifest)
        # The dataset is read from the cache file the first time a query needs it.
        Member("thermoml"; kind = :thermoml, path = cache_data_path(dir))
    else
        @info "Building the local database from the ThermoML archive (needed once per archive version)"
        ds, _ = build_dataset(archive_path(manifest; dir); progress)
        try
            write_cache(dir, ds, manifest)
        catch err
            err isa InterruptException && rethrow()
            @warn "The database was built but could not be cached; it will be rebuilt next time" reason =
                sprint(showerror, err)
        end
        Member("thermoml"; kind = :thermoml, path = cache_data_path(dir), dataset = ds)
    end
    db = Database([member])
    prefetch_compounds > 0 &&
        prefetch_missing_compounds(member_dataset(member), prefetch_compounds, progress)
    DATABASE_MEMO[] = (String(dir), db)
    return db
end

# `database(; prefetch_compounds = n)`: ask PubChem for the n most measured compounds that the
# compound database lacks. A failure here must not make the database unusable.
function prefetch_missing_compounds(
    ds::Dataset,
    top::Integer,
    progress::Bool,
    load = () -> compound_database(; progress),
)
    try
        prefetch_compounds!(ds, load(); top = Int(top), progress)
    catch err
        err isa InterruptException && rethrow()
        @warn "The compounds could not be fetched from PubChem; the database is usable without them" reason =
            sprint(showerror, err)
    end
    return nothing
end
