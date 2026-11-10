# The databases behind one `Database`: each member is a `Dataset` of its own, read from its own
# cache file only when a query needs it, and described by a small catalog that is always at hand.

const MEMBER_KINDS = (:thermoml, :literature, :user)

# Order of the members when the user does not choose: a point that several members hold is taken
# from the first one in this order, so the archive comes before what the user added.
const DEFAULT_PRIORITY = (thermoml = 1, literature = 2, user = 3)

"""
    Catalog

What the registry needs to know about a database without reading its tables: the keys, formulas and
names of its compounds, the labels and units of its properties and the DOIs of its references.
"""
struct Catalog
    compound_key::Vector{String}
    compound_inchikey::Vector{String}
    compound_formula::Vector{String}
    compound_names::Vector{Vector{String}}
    property_label::Vector{String}
    property_unit::Vector{String}
    doi::Vector{String}
end

# The catalog of a dataset in memory shares its columns.
function catalog_of(ds::Dataset)
    return Catalog(
        ds.compounds.key,
        ds.compounds.inchikey,
        ds.compounds.formula,
        ds.compounds.names,
        ds.properties.label,
        ds.properties.unit,
        ds.references.doi,
    )
end

# The catalog of a cache file: seven small columns, read without the tables.
function read_catalog(path::AbstractString)
    return JLD2.jldopen(path, "r") do file
        Catalog(
            file["compounds/key"],
            file["compounds/inchikey"],
            file["compounds/formula"],
            file["compounds/names"],
            file["properties/label"],
            file["properties/unit"],
            file["references/doi"],
        )
    end
end

"""
    Member

One database of a [`Database`](@ref): its `name`, `kind` (`:thermoml`, `:literature` or `:user`),
the cache file it lives in (`path`, empty for one that only exists in memory), its `priority` (a
smaller number comes first) and whether it is `persistent` (written to its file when saved; the
databases of the user are not by default). The dataset is read from the file the first time
[`member_dataset`](@ref) is called.
"""
mutable struct Member
    name::String
    kind::Symbol
    path::String
    priority::Int
    persistent::Bool
    dataset::Union{Nothing,Dataset}
    catalog::Union{Nothing,Catalog}
    lock::ReentrantLock
end

function Member(
    name::AbstractString;
    kind::Symbol,
    path::AbstractString = "",
    dataset::Union{Nothing,Dataset} = nothing,
    priority::Integer = DEFAULT_PRIORITY[kind in MEMBER_KINDS ? kind : :user],
    persistent::Bool = kind !== :user,
)
    isempty(strip(name)) && throw(ArgumentError("a database needs a name"))
    kind in MEMBER_KINDS ||
        throw(ArgumentError("kind must be one of $(MEMBER_KINDS), got :$kind"))
    (isempty(path) && dataset === nothing) &&
        throw(ArgumentError("database \"$name\" needs a file or a dataset"))
    return Member(
        String(strip(name)),
        kind,
        String(path),
        Int(priority),
        persistent,
        dataset,
        nothing,
        ReentrantLock(),
    )
end

is_open(m::Member) = m.dataset !== nothing

# Read the dataset of a member from its file, with its large tables left on disk.
function open_member_file(path::AbstractString)
    isfile(path) || throw(ArgumentError("the file of the database does not exist: $path"))
    return JLD2.jldopen(path, "r") do file
        restore_dataset(key -> file[key]; lazy_path = path)
    end
end

"""
    member_dataset(member) -> Dataset
    member_dataset(db, name) -> Dataset

The dataset of a database, read from its file the first time it is asked for.
"""
function member_dataset(m::Member)::Dataset
    ds = m.dataset
    ds === nothing || return ds
    return lock(m.lock) do
        m.dataset === nothing && (m.dataset = open_member_file(m.path))
        return m.dataset::Dataset
    end
end

function member_catalog(m::Member)
    cat = m.catalog
    cat === nothing || return cat
    return lock(m.lock) do
        if m.catalog === nothing
            m.catalog = is_open(m) ? catalog_of(m.dataset::Dataset) : read_catalog(m.path)
        end
        return m.catalog
    end
end

function Base.show(io::IO, m::Member)
    state = is_open(m) ? "open, $(length(m.dataset.measurements)) measurements" : "not read"
    return print(
        io,
        "Member(\"",
        m.name,
        "\", :",
        m.kind,
        ", priority ",
        m.priority,
        ", ",
        state,
        ")",
    )
end
