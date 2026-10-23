# Dataset <-> flat key/value pairs of plain arrays.
#
# The cache stores only primitive columns plus a schema version, never Julia structs, so
# renaming a field or changing a table later cannot make an old cache unreadable in a
# confusing way: a different `SCHEMA_VERSION` simply triggers a rebuild. Lookup
# dictionaries are not stored; they are rebuilt from the columns on load.

const SCHEMA_VERSION = 1
const POOL_NAMES = (:sources, :groups, :methods, :phases, :kinds, :extra_keys, :extra_texts)
const TABLE_NAMES =
    (:references, :compounds, :properties, :experiments, :measurements, :extras)

function store_columns!(sink, table, prefix::AbstractString)
    for name in fieldnames(typeof(table))
        name === :index && continue
        value = getfield(table, name)
        if value isa Tuple
            for (i, column) in enumerate(value)
                sink("$prefix/$name/$i", column)
            end
        else
            sink("$prefix/$name", value)
        end
    end
    return nothing
end

function fill_columns!(table, source, prefix::AbstractString)
    for name in fieldnames(typeof(table))
        name === :index && continue
        value = getfield(table, name)
        if value isa Tuple
            for (i, column) in enumerate(value)
                append!(column, source("$prefix/$name/$i"))
            end
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
    for name in POOL_NAMES
        sink("pool/$name", getfield(ds, name).strings)
    end
    for name in TABLE_NAMES
        store_columns!(sink, getfield(ds, name), String(name))
    end
    return nothing
end

function rebuild_indices!(ds::Dataset)
    for name in POOL_NAMES
        pool = getfield(ds, name)
        for (i, s) in enumerate(pool.strings)
            pool.index[s] = Int32(i)
        end
    end
    for (i, doi) in enumerate(ds.references.doi)
        isempty(doi) || (ds.references.index[doi] = Int32(i))
    end
    for (i, key) in enumerate(ds.compounds.key)
        ds.compounds.index[key] = Int32(i)
    end
    pt = ds.properties
    for i = 1:length(pt)
        pt.index[(pt.label[i], pt.unit[i])] = Int32(i)
    end
    return nothing
end

"""
    restore_dataset(source) -> Dataset

Inverse of [`write_dataset`](@ref); `source(key)` returns the array stored under `key`.
Throws an `ArgumentError` when the schema version differs and validates the result.
"""
function restore_dataset(source)
    version = source("schema_version")
    version == SCHEMA_VERSION ||
        throw(ArgumentError("cache has schema version $version, expected $SCHEMA_VERSION"))
    ds = Dataset()
    for name in POOL_NAMES
        append!(getfield(ds, name).strings, source("pool/$name"))
    end
    for name in TABLE_NAMES
        fill_columns!(getfield(ds, name), source, String(name))
    end
    rebuild_indices!(ds)
    validate(ds)
    return ds
end
