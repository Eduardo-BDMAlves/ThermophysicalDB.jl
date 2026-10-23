# Core schema: the ThermoML data model flattened into five relational tables, stored as
# structs of arrays (one concrete `Vector` per column) so scans are cache friendly and
# type stable. Anything a source cannot express in these columns goes to the extras
# mechanism, which is additive and lives outside this file.

"Maximum number of components of a system. The archive never exceeds three."
const MAX_COMPONENTS = 3

# ----------------------------------------------------------------------------------
# References
# ----------------------------------------------------------------------------------

"""
    ReferenceTable()

One row per publication. Rows are deduplicated by DOI when a DOI is known.
"""
struct ReferenceTable
    doi::Vector{String}
    title::Vector{String}
    journal::Vector{String}
    year::Vector{Int16}
    volume::Vector{String}
    pages::Vector{String}
    authors::Vector{Vector{String}}
    source::Vector{Int32}
    index::Dict{String,Int32}
end

function ReferenceTable()
    return ReferenceTable(
        String[],
        String[],
        String[],
        Int16[],
        String[],
        String[],
        Vector{String}[],
        Int32[],
        Dict{String,Int32}(),
    )
end

Base.length(t::ReferenceTable) = length(t.doi)

function add_reference!(
    t::ReferenceTable;
    doi::AbstractString = "",
    title::AbstractString = "",
    journal::AbstractString = "",
    year::Integer = 0,
    volume::AbstractString = "",
    pages::AbstractString = "",
    authors::AbstractVector{<:AbstractString} = String[],
    source::Integer = NO_ID,
)
    if !isempty(doi)
        existing = get(t.index, doi, NO_ID)
        existing != NO_ID && return existing
    end
    push!(t.doi, doi)
    push!(t.title, title)
    push!(t.journal, journal)
    push!(t.year, Int16(year))
    push!(t.volume, volume)
    push!(t.pages, pages)
    push!(t.authors, String.(authors))
    push!(t.source, Int32(source))
    id = Int32(length(t.doi))
    isempty(doi) || (t.index[String(doi)] = id)
    return id
end

# ----------------------------------------------------------------------------------
# Compounds
# ----------------------------------------------------------------------------------

"""
    CompoundTable()

One row per distinct chemical species, shared by every source. The identity key is the
standard InChIKey; when a record has none, the lower-cased first name is used instead
(prefixed with `"name:"` so the two kinds of key cannot collide).
"""
struct CompoundTable
    key::Vector{String}
    inchikey::Vector{String}
    inchi::Vector{String}
    formula::Vector{String}
    names::Vector{Vector{String}}
    index::Dict{String,Int32}
end

function CompoundTable()
    return CompoundTable(
        String[],
        String[],
        String[],
        String[],
        Vector{String}[],
        Dict{String,Int32}(),
    )
end

Base.length(t::CompoundTable) = length(t.key)

function compound_key(inchikey::AbstractString, names::AbstractVector{<:AbstractString})
    isempty(inchikey) || return String(inchikey)
    isempty(names) &&
        throw(ArgumentError("a compound needs an InChIKey or at least one name"))
    return "name:" * lowercase(strip(first(names)))
end

function add_compound!(
    t::CompoundTable;
    inchikey::AbstractString = "",
    inchi::AbstractString = "",
    formula::AbstractString = "",
    names::AbstractVector{<:AbstractString} = String[],
)
    key = compound_key(inchikey, names)
    id = get(t.index, key, NO_ID)
    if id != NO_ID
        # Keep the first record but enrich it with what the new one adds.
        isempty(t.inchi[id]) && (t.inchi[id] = inchi)
        isempty(t.formula[id]) && (t.formula[id] = formula)
        for name in names
            name in t.names[id] || push!(t.names[id], name)
        end
        return id
    end
    push!(t.key, key)
    push!(t.inchikey, inchikey)
    push!(t.inchi, inchi)
    push!(t.formula, formula)
    push!(t.names, String.(names))
    id = Int32(length(t.key))
    t.index[key] = id
    return id
end

# ----------------------------------------------------------------------------------
# Properties
# ----------------------------------------------------------------------------------

"""
    PropertyTable()

One row per distinct (label, native unit) pair, e.g. `("Mass density", "kg/m3")`.
`group` is an identifier into the dataset's group pool (`"VolumetricProp"`, ...).
A dimensionless property has `unit == ""`.
"""
struct PropertyTable
    label::Vector{String}
    unit::Vector{String}
    group::Vector{Int32}
    index::Dict{Tuple{String,String},Int32}
end

PropertyTable() =
    PropertyTable(String[], String[], Int32[], Dict{Tuple{String,String},Int32}())

Base.length(t::PropertyTable) = length(t.label)

function add_property!(
    t::PropertyTable,
    label::AbstractString,
    unit::AbstractString = "";
    group::Integer = NO_ID,
)
    key = (String(label), String(unit))
    id = get(t.index, key, NO_ID)
    id != NO_ID && return id
    push!(t.label, key[1])
    push!(t.unit, key[2])
    push!(t.group, Int32(group))
    id = Int32(length(t.label))
    t.index[key] = id
    return id
end

# ----------------------------------------------------------------------------------
# Experiments
# ----------------------------------------------------------------------------------

"""
    ExperimentTable()

One row per studied system in a publication (a ThermoML `PureOrMixtureData` block): a
reference plus up to [`MAX_COMPONENTS`](@ref) compounds. `kinds[i]` is the identifier
(in the dataset's composition-kind pool) of the variable that expresses the amount of
component `i`, e.g. `"Mole fraction"` or `"Molality, mol/kg"`.
"""
struct ExperimentTable
    reference::Vector{Int32}
    source::Vector{Int32}
    number::Vector{Int32}
    ncomp::Vector{UInt8}
    components::NTuple{MAX_COMPONENTS,Vector{Int32}}
    kinds::NTuple{MAX_COMPONENTS,Vector{Int32}}
end

function ExperimentTable()
    return ExperimentTable(
        Int32[],
        Int32[],
        Int32[],
        UInt8[],
        ntuple(_ -> Int32[], MAX_COMPONENTS),
        ntuple(_ -> Int32[], MAX_COMPONENTS),
    )
end

Base.length(t::ExperimentTable) = length(t.reference)

function add_experiment!(
    t::ExperimentTable;
    reference::Integer,
    components::AbstractVector{<:Integer},
    kinds::AbstractVector{<:Integer} = Int32[],
    source::Integer = NO_ID,
    number::Integer = 0,
)
    n = length(components)
    n <= MAX_COMPONENTS || throw(
        ArgumentError("systems with more than $MAX_COMPONENTS components are unsupported"),
    )
    length(kinds) <= n || throw(ArgumentError("more composition kinds than components"))
    push!(t.reference, Int32(reference))
    push!(t.source, Int32(source))
    push!(t.number, Int32(number))
    push!(t.ncomp, UInt8(n))
    for i = 1:MAX_COMPONENTS
        push!(t.components[i], i <= n ? Int32(components[i]) : NO_ID)
        push!(t.kinds[i], i <= length(kinds) ? Int32(kinds[i]) : NO_ID)
    end
    return Int32(length(t.reference))
end

# ----------------------------------------------------------------------------------
# Measurements
# ----------------------------------------------------------------------------------

"""
    MeasurementTable()

One row per measured property value (the "long" format). Numbers are `Float64` in the
unit the source used (see [`PropertyTable`](@ref)); `NaN` marks an absent number.

- `unc`: uncertainty exactly as reported, with `unc_k` (coverage factor) and `unc_level`
  (level of confidence as a fraction) when the source gave them. The `k = 2` version is
  derived on demand, so changing the policy never leaves stale data on disk.
- `temperature` (K) and `pressure` (kPa) are the state conditions of the point.
- `composition[i]` is the amount of component `i`, expressed as `kinds[i]` of its
  experiment.
"""
struct MeasurementTable
    experiment::Vector{Int32}
    property::Vector{Int32}
    method::Vector{Int32}
    phase::Vector{Int32}
    value::Vector{Float64}
    unc::Vector{Float64}
    unc_k::Vector{Float64}
    unc_level::Vector{Float64}
    temperature::Vector{Float64}
    pressure::Vector{Float64}
    composition::NTuple{MAX_COMPONENTS,Vector{Float64}}
end

function MeasurementTable()
    return MeasurementTable(
        Int32[],
        Int32[],
        Int32[],
        Int32[],
        Float64[],
        Float64[],
        Float64[],
        Float64[],
        Float64[],
        Float64[],
        ntuple(_ -> Float64[], MAX_COMPONENTS),
    )
end

Base.length(t::MeasurementTable) = length(t.value)

function add_measurement!(
    t::MeasurementTable;
    experiment::Integer,
    property::Integer,
    value::Real,
    method::Integer = NO_ID,
    phase::Integer = NO_ID,
    unc::Real = NaN,
    unc_k::Real = NaN,
    unc_level::Real = NaN,
    temperature::Real = NaN,
    pressure::Real = NaN,
    composition::NTuple{MAX_COMPONENTS,<:Real} = (NaN, NaN, NaN),
)
    push!(t.experiment, Int32(experiment))
    push!(t.property, Int32(property))
    push!(t.method, Int32(method))
    push!(t.phase, Int32(phase))
    push!(t.value, Float64(value))
    push!(t.unc, Float64(unc))
    push!(t.unc_k, Float64(unc_k))
    push!(t.unc_level, Float64(unc_level))
    push!(t.temperature, Float64(temperature))
    push!(t.pressure, Float64(pressure))
    for i = 1:MAX_COMPONENTS
        push!(t.composition[i], Float64(composition[i]))
    end
    return length(t.value)
end

# ----------------------------------------------------------------------------------
# Extras
# ----------------------------------------------------------------------------------

"Tables an extra field can be attached to; the position is the code stored on disk."
const EXTRA_SCOPES = (:reference, :compound, :experiment, :measurement)

function scope_code(scope::Symbol)
    code = findfirst(==(scope), EXTRA_SCOPES)
    code === nothing &&
        throw(ArgumentError("scope must be one of $(EXTRA_SCOPES), got :$scope"))
    return UInt8(code)
end

"""
    ExtraTable()

Sparse key-value store (long format) for fields that have no column in the core schema.
Row `i` says: in the table given by `scope[i]`, row `row[i]` has the field `key[i]` with
the numeric value `number[i]` (`NaN` for text) or the text `text[i]` (`NO_ID` for a
number). Keys and texts are identifiers into the dataset's `extra_keys` and
`extra_texts` pools. Core queries never touch this table.
"""
struct ExtraTable
    scope::Vector{UInt8}
    row::Vector{Int32}
    key::Vector{Int32}
    number::Vector{Float64}
    text::Vector{Int32}
end

ExtraTable() = ExtraTable(UInt8[], Int32[], Int32[], Float64[], Int32[])

Base.length(t::ExtraTable) = length(t.row)
