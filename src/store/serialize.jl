# Dataset <-> flat key/value pairs of plain arrays.
#
# The cache stores only primitive columns plus a schema version, never Julia structs, so
# renaming a field or changing a table later cannot make an old cache unreadable in a
# confusing way: a different `SCHEMA_VERSION` simply triggers a rebuild. Lookup
# dictionaries are not stored; they are rebuilt from the columns on load.

const SCHEMA_VERSION = 8
const POOL_NAMES = (
    :sources,
    :groups,
    :methods,
    :phases,
    :kinds,
    :extra_keys,
    :extra_texts,
    :origins,
    :statuses,
    :suppliers,
    :analyses,
    :purifications,
    :purposes,
    :unc_methods,
    :evaluators,
    :method_texts,
    :condition_groups,
    :condition_labels,
)
const TABLE_NAMES = (
    :references,
    :compounds,
    :samples,
    :purity_steps,
    :properties,
    :experiments,
    :measurements,
    :extras,
    :conditions,
    :uncertainties,
)

function store_columns!(sink, table, prefix::AbstractString)
    for name in fieldnames(typeof(table))
        name in DERIVED_FIELDS && continue
        value = getfield(table, name)
        value isa Base.RefValue && continue
        if value isa Tuple
            for (i, column) in enumerate(value)
                sink("$prefix/$name/$i", column)
            end
        elseif value isa PooledFloats
            sink("$prefix/$name/codes", value.codes)
            sink("$prefix/$name/pool", value.pool)
        else
            sink("$prefix/$name", value)
        end
    end
    return nothing
end

function fill_columns!(table, source, prefix::AbstractString)
    for name in fieldnames(typeof(table))
        name in DERIVED_FIELDS && continue
        value = getfield(table, name)
        if value isa Tuple
            for (i, column) in enumerate(value)
                append!(column, source("$prefix/$name/$i"))
            end
        elseif value isa PooledFloats
            append!(value.codes, source("$prefix/$name/codes"))
            append!(value.pool, source("$prefix/$name/pool"))
            rebuild_lookup!(value)
        else
            append!(value, source("$prefix/$name"))
        end
    end
    return nothing
end

"""
    write_dataset(sink, ds)

Hand every column of `ds` to `sink(key, array)`. `sink` is a JLD2 file writer in the
cache, or a `Dict` setter in tests.
"""
function write_dataset(sink, ds::Dataset)
    sink("schema_version", SCHEMA_VERSION)
    stamps = getfield(ds, :stamps)
    sink("meta/created", stamps.created)
    sink("meta/modified", stamps.modified)
    for name in POOL_NAMES
        sink("pool/$name", getproperty(ds, name).strings)
    end
    for name in TABLE_NAMES
        store_columns!(sink, getproperty(ds, name), String(name))
    end
    return nothing
end

function rebuild_pool_index!(pool::StringPool)
    for (i, s) in enumerate(pool.strings)
        pool.index[s] = Int32(i)
    end
    return nothing
end

function rebuild_sample_index!(st::SampleTable)
    for i = 1:length(st)
        st.index[(st.reference[i], st.compound[i], st.number[i])] = Int32(i)
    end
    return nothing
end

# The lookup dictionaries of what is in memory; the fields that are still on disk are left out.
function rebuild_indices!(ds::Dataset; lazy::Bool = false)
    for name in POOL_NAMES
        lazy && lazy_bit(name) != 0 && continue
        rebuild_pool_index!(getfield(ds, name)::StringPool)
    end
    for (i, doi) in enumerate(ds.references.doi)
        isempty(doi) || (ds.references.index[doi] = Int32(i))
    end
    for (i, key) in enumerate(ds.compounds.key)
        ds.compounds.index[key] = Int32(i)
    end
    lazy || rebuild_sample_index!(ds.samples)
    pt = ds.properties
    for i = 1:length(pt)
        pt.index[(pt.label[i], pt.unit[i])] = Int32(i)
    end
    return nothing
end

# The stamps of the file; one written before they existed (no keys) takes the time of the file.
function restore_stamps!(ds::Dataset, source, path::AbstractString)
    stamps = getfield(ds, :stamps)
    fallback = isempty(path) || !isfile(path) ? time() : mtime(path)
    read_stamp(key) =
        try
            Float64(source(key))
        catch err
            err isa KeyError || err isa ArgumentError || rethrow()
            fallback
        end
    stamps.created = read_stamp("meta/created")
    stamps.modified = read_stamp("meta/modified")
    return nothing
end

"""
    restore_dataset(source) -> Dataset

Inverse of [`write_dataset`](@ref); `source(key)` returns the array stored under `key`.
Throws an `ArgumentError` when the schema version differs and validates the result.
"""
function restore_dataset(source; lazy_path::AbstractString = "")
    version = source("schema_version")
    version == SCHEMA_VERSION ||
        throw(ArgumentError("cache has schema version $version, expected $SCHEMA_VERSION"))
    ds = Dataset()
    lazy = !isempty(lazy_path)
    for name in POOL_NAMES
        lazy && lazy_bit(name) != 0 && continue
        append!(getfield(ds, name).strings, source("pool/$name"))
    end
    for name in TABLE_NAMES
        lazy && lazy_bit(name) != 0 && continue
        fill_columns!(getfield(ds, name), source, String(name))
    end
    rebuild_indices!(ds; lazy)
    restore_stamps!(ds, source, lazy_path)
    if lazy
        info = stat(lazy_path)
        state = getfield(ds, :lazy)
        state.path = String(lazy_path)
        state.size = info.size
        state.mtime = info.mtime
        state.loaded[] = 0x00000000
        validate_core(ds)
    else
        validate(ds)
    end
    return ds
end

# Empty the columns of a table that was only partly filled, so that a failed read can be repeated.
function clear_columns!(table)
    for name in fieldnames(typeof(table))
        name in DERIVED_FIELDS && continue
        value = getfield(table, name)
        if value isa Tuple
            foreach(empty!, value)
        elseif value isa Base.RefValue
            nothing
        elseif value isa PooledFloats
            empty!(value.codes)
            empty!(value.pool)
            empty!(value.lookup)
        elseif value isa Union{AbstractVector,AbstractDict,AbstractSet}
            empty!(value)
        end
    end
    return nothing
end

"""
    load_lazy!(ds, name)

Read the lazy field `name` (see [`LAZY_FIELDS`](@ref)) of a dataset from the cache file it was
read from. Safe to call from several tasks. A file that was replaced since the dataset was read
is refused, because its tables no longer belong to the rest of the dataset.
"""
function load_lazy!(ds::Dataset, name::Symbol)
    state = getfield(ds, :lazy)
    bit = lazy_bit(name)
    bit == 0x00000000 && throw(ArgumentError("$name is not a lazy field of a dataset"))
    lock(state.lock) do
        (state.loaded[] & bit) == 0x00000000 || return nothing
        info = stat(state.path)
        (isfile(state.path) && info.size == state.size && info.mtime == state.mtime) ||
            throw(
                ArgumentError(
                    "the cache file $(state.path) changed after the database was read, so " *
                    "$name cannot be read from it; load the database again with " *
                    "`database(reload = true)`",
                ),
            )
        target = getfield(ds, name)
        try
            JLD2.jldopen(state.path, "r") do file
                if name === :extra_texts
                    append!(target.strings, file["pool/extra_texts"])
                    rebuild_pool_index!(target::StringPool)
                else
                    fill_columns!(target, key -> file[key], String(name))
                    name === :samples && rebuild_sample_index!(target)
                    allequal(column_lengths(target)) || throw(
                        ArgumentError("columns of the $name table have different lengths"),
                    )
                end
            end
        catch
            name === :extra_texts ? empty!(target.strings) : clear_columns!(target)
            name === :extra_texts && empty!(target.index)
            rethrow()
        end
        Threads.atomic_or!(state.loaded, bit)
    end
    return nothing
end
