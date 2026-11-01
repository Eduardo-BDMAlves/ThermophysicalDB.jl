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
    NameIndex

Normalised-name lookup of a [`CompoundTable`](@ref), built lazily on first use and rebuilt
when compounds or names have been added since. It is derived data: never stored in the
cache, and not a column of the table. `ids` maps a normalised name to the compounds that
carry it and `keys` lists the distinct normalised names (for approximate matching).
"""
struct NameIndex
    ncompounds::Int
    nnames::Int
    ids::Dict{String,Vector{Int32}}
    keys::Vector{String}
end

# Fields that are derived from the columns and therefore neither stored nor described.
const DERIVED_FIELDS = (:index, :lookup)

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
    lookup::Base.RefValue{Union{Nothing,NameIndex}}
end

function CompoundTable()
    return CompoundTable(
        String[],
        String[],
        String[],
        String[],
        Vector{String}[],
        Dict{String,Int32}(),
        Ref{Union{Nothing,NameIndex}}(nothing),
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
# Samples
# ----------------------------------------------------------------------------------

"Code of an absent digit count (`UInt8`); counts of significant digits are small."
const NO_DIGITS = 0xff

"Amount basis of a purity; `purity_kind` columns hold the position, `0` meaning no purity."
const PURITY_KINDS = (:mass, :mole, :volume, :unspecified)

"Origin of a purity value; `purity_basis` holds the position, `0` meaning unknown."
const PURITY_BASES = (:supplier, :measured, :estimated)

"""
    SampleTable()

One row per sample described in a publication (a ThermoML `Sample` of a `Compound`),
identified by (reference, compound, sample number). Every experiment points at the samples
of its components (see [`ExperimentTable`](@ref)); an experiment whose sample is not
described points at [`NO_ID`](@ref).

The purity is kept twice: step by step in the [`PurityStepTable`](@ref) and as a summary
in this table, so the common questions need no join.

- `origin` (pool `origins`): `"Commercial source"`, `"Synthesized by the authors"`, ...
  `status` (pool `statuses`): why a sample may be undescribed (`"notDescribed"`, ...).
- `supplier` (pool `suppliers`): the name of the supplier when the source states one. The
  ThermoML archive has no such field, so it is `NO_ID` for every archive sample; samples
  declared by the user can fill it.
- `purity`: final purity, the last purification step that states a number, as a fraction
  (`NaN` when there is none) and `purity_kind` its basis (index in [`PURITY_KINDS`](@ref)).
  `purity_initial` and `purity_initial_kind` are the first stated purity, only when the
  sample has at least two steps with a purity.
- `water`: water content of the final step as a mass fraction, `NaN` when not stated.
- `purity_basis`: where the final purity comes from (index in [`PURITY_BASES`](@ref)):
  stated by the supplier, measured by the authors, or estimated by the compiler.
- `nsteps`: number of purity steps.
- `analysis`, `purification` (pools `analyses`, `purifications`): every method of any step.
"""
struct SampleTable
    reference::Vector{Int32}
    compound::Vector{Int32}
    number::Vector{Int32}
    origin::Vector{Int32}
    status::Vector{Int32}
    supplier::Vector{Int32}
    nsteps::Vector{UInt8}
    purity::Vector{Float64}
    purity_kind::Vector{UInt8}
    purity_initial::Vector{Float64}
    purity_initial_kind::Vector{UInt8}
    water::Vector{Float64}
    purity_basis::Vector{UInt8}
    analysis::Vector{Vector{Int32}}
    purification::Vector{Vector{Int32}}
    index::Dict{Tuple{Int32,Int32,Int32},Int32}
end

function SampleTable()
    return SampleTable(
        Int32[],
        Int32[],
        Int32[],
        Int32[],
        Int32[],
        Int32[],
        UInt8[],
        Float64[],
        UInt8[],
        Float64[],
        UInt8[],
        Float64[],
        UInt8[],
        Vector{Int32}[],
        Vector{Int32}[],
        Dict{Tuple{Int32,Int32,Int32},Int32}(),
    )
end

Base.length(t::SampleTable) = length(t.reference)

"""
    add_sample!(t::SampleTable; reference, compound, number = 1, origin = NO_ID,
                status = NO_ID, supplier = NO_ID) -> Int32

Add a sample, or return the existing one with the same (reference, compound, number). The
summary columns start empty; the ingest of an article fills them from the steps.
"""
function add_sample!(
    t::SampleTable;
    reference::Integer,
    compound::Integer,
    number::Integer = 1,
    origin::Integer = NO_ID,
    status::Integer = NO_ID,
    supplier::Integer = NO_ID,
)
    key = (Int32(reference), Int32(compound), Int32(number))
    existing = get(t.index, key, NO_ID)
    existing != NO_ID && return existing
    push!(t.reference, key[1])
    push!(t.compound, key[2])
    push!(t.number, key[3])
    push!(t.origin, Int32(origin))
    push!(t.status, Int32(status))
    push!(t.supplier, Int32(supplier))
    push!(t.nsteps, 0x00)
    push!(t.purity, NaN)
    push!(t.purity_kind, 0x00)
    push!(t.purity_initial, NaN)
    push!(t.purity_initial_kind, 0x00)
    push!(t.water, NaN)
    push!(t.purity_basis, 0x00)
    push!(t.analysis, Int32[])
    push!(t.purification, Int32[])
    id = Int32(length(t.reference))
    t.index[key] = id
    return id
end

"""
    PurityStepTable()

One row per purification step of a sample (`purity` element of a ThermoML `Sample`).
Amounts are fractions (the archive gives per cent): `mass`, `mole`, `volume` and `unknown`
are the purity on that basis (`NaN` when the step does not state it; `unknown` is a purity
with no stated basis), `water_mass`/`water_mole` and `halide_mass`/`halide_mole` the water
and halide contents. `digits` is the number of significant digits of the stated purity
([`NO_DIGITS`](@ref) when not given). `analysis` and `purification` list the methods
(pools `analyses` and `purifications`); `analysis_text` and `purification_text` are the
free-text descriptions (pool `extra_texts`).
"""
struct PurityStepTable
    sample::Vector{Int32}
    step::Vector{Int32}
    mass::Vector{Float64}
    mole::Vector{Float64}
    volume::Vector{Float64}
    unknown::Vector{Float64}
    digits::Vector{UInt8}
    water_mass::Vector{Float64}
    water_mole::Vector{Float64}
    halide_mass::Vector{Float64}
    halide_mole::Vector{Float64}
    analysis::Vector{Vector{Int32}}
    analysis_text::Vector{Int32}
    purification::Vector{Vector{Int32}}
    purification_text::Vector{Int32}
end

function PurityStepTable()
    return PurityStepTable(
        Int32[],
        Int32[],
        Float64[],
        Float64[],
        Float64[],
        Float64[],
        UInt8[],
        Float64[],
        Float64[],
        Float64[],
        Float64[],
        Vector{Int32}[],
        Int32[],
        Vector{Int32}[],
        Int32[],
    )
end

Base.length(t::PurityStepTable) = length(t.sample)

function add_purity_step!(
    t::PurityStepTable;
    sample::Integer,
    step::Integer = 1,
    mass::Real = NaN,
    mole::Real = NaN,
    volume::Real = NaN,
    unknown::Real = NaN,
    digits::Integer = NO_DIGITS,
    water_mass::Real = NaN,
    water_mole::Real = NaN,
    halide_mass::Real = NaN,
    halide_mole::Real = NaN,
    analysis::AbstractVector{<:Integer} = Int32[],
    analysis_text::Integer = NO_ID,
    purification::AbstractVector{<:Integer} = Int32[],
    purification_text::Integer = NO_ID,
)
    push!(t.sample, Int32(sample))
    push!(t.step, Int32(step))
    push!(t.mass, Float64(mass))
    push!(t.mole, Float64(mole))
    push!(t.volume, Float64(volume))
    push!(t.unknown, Float64(unknown))
    push!(t.digits, UInt8(digits))
    push!(t.water_mass, Float64(water_mass))
    push!(t.water_mole, Float64(water_mole))
    push!(t.halide_mass, Float64(halide_mass))
    push!(t.halide_mole, Float64(halide_mole))
    push!(t.analysis, Int32.(analysis))
    push!(t.analysis_text, Int32(analysis_text))
    push!(t.purification, Int32.(purification))
    push!(t.purification_text, Int32(purification_text))
    return Int32(length(t.sample))
end

# ----------------------------------------------------------------------------------
# Experiments
# ----------------------------------------------------------------------------------

"""
    ExperimentTable()

One row per studied system in a publication (a ThermoML `PureOrMixtureData` block): a
reference plus up to [`MAX_COMPONENTS`](@ref) compounds. `kinds[i]` is the identifier
(in the dataset's composition-kind pool) of the variable that expresses the amount of
component `i`, e.g. `"Mole fraction"` or `"Molality, mol/kg"`. `samples[i]` is the row of
the [`SampleTable`](@ref) that describes the sample of component `i` (`NO_ID` when the
source does not describe it) and `purpose` the purpose of the experiment (pool `purposes`,
e.g. `"Principal objective of the work"`).
"""
struct ExperimentTable
    reference::Vector{Int32}
    source::Vector{Int32}
    number::Vector{Int32}
    ncomp::Vector{UInt8}
    components::NTuple{MAX_COMPONENTS,Vector{Int32}}
    kinds::NTuple{MAX_COMPONENTS,Vector{Int32}}
    samples::NTuple{MAX_COMPONENTS,Vector{Int32}}
    purpose::Vector{Int32}
end

function ExperimentTable()
    return ExperimentTable(
        Int32[],
        Int32[],
        Int32[],
        UInt8[],
        ntuple(_ -> Int32[], MAX_COMPONENTS),
        ntuple(_ -> Int32[], MAX_COMPONENTS),
        ntuple(_ -> Int32[], MAX_COMPONENTS),
        Int32[],
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
    samples::AbstractVector{<:Integer} = Int32[],
    purpose::Integer = NO_ID,
)
    n = length(components)
    n <= MAX_COMPONENTS || throw(
        ArgumentError("systems with more than $MAX_COMPONENTS components are unsupported"),
    )
    length(kinds) <= n || throw(ArgumentError("more composition kinds than components"))
    length(samples) <= n || throw(ArgumentError("more samples than components"))
    push!(t.reference, Int32(reference))
    push!(t.source, Int32(source))
    push!(t.number, Int32(number))
    push!(t.ncomp, UInt8(n))
    for i = 1:MAX_COMPONENTS
        push!(t.components[i], i <= n ? Int32(components[i]) : NO_ID)
        push!(t.kinds[i], i <= length(kinds) ? Int32(kinds[i]) : NO_ID)
        push!(t.samples[i], i <= length(samples) ? Int32(samples[i]) : NO_ID)
    end
    push!(t.purpose, Int32(purpose))
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
  `unc_method` is how the uncertainty was evaluated (pool `unc_methods`), and `unc_k` the
  coverage factor when the source states it.
- `digits`, `temperature_digits`, `pressure_digits` and `composition_digits[i]` are the
  numbers of significant digits the source gave for the value, the temperature, the
  pressure and the amount of component `i` ([`NO_DIGITS`](@ref) when not given).
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
    unc_method::Vector{Int32}
    digits::Vector{UInt8}
    temperature_digits::Vector{UInt8}
    pressure_digits::Vector{UInt8}
    composition_digits::NTuple{MAX_COMPONENTS,Vector{UInt8}}
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
        Int32[],
        UInt8[],
        UInt8[],
        UInt8[],
        ntuple(_ -> UInt8[], MAX_COMPONENTS),
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
    unc_method::Integer = NO_ID,
    digits::Integer = NO_DIGITS,
    temperature_digits::Integer = NO_DIGITS,
    pressure_digits::Integer = NO_DIGITS,
    composition_digits::NTuple{MAX_COMPONENTS,<:Integer} = (
        NO_DIGITS,
        NO_DIGITS,
        NO_DIGITS,
    ),
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
    push!(t.unc_method, Int32(unc_method))
    push!(t.digits, UInt8(digits))
    push!(t.temperature_digits, UInt8(temperature_digits))
    push!(t.pressure_digits, UInt8(pressure_digits))
    for i = 1:MAX_COMPONENTS
        push!(t.composition_digits[i], UInt8(composition_digits[i]))
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
