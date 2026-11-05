# The tables and the pool that a dataset read from its cache file leaves on disk until they are
# used: together about a quarter of the memory of the archive, and only needed for the details
# of the points (samples, purity, conditions, extra fields). A bit of `LazyState.loaded` says
# that the field is in memory; a dataset that was built, not read, has every bit set.
"""
    LAZY_FIELDS

The fields of a `Dataset` that are read from the cache file on first use: `samples`,
`purity_steps`, `extras`, `conditions` and the pool `extra_texts`.
"""
const LAZY_FIELDS = (:samples, :purity_steps, :extras, :conditions, :extra_texts)

@inline function lazy_bit(name::Symbol)
    return name === :samples ? 0x00000001 :
           name === :purity_steps ? 0x00000002 :
           name === :extras ? 0x00000004 :
           name === :conditions ? 0x00000008 :
           name === :extra_texts ? 0x00000010 : 0x00000000
end

# Where the lazy fields come from and which of them are in memory. `size` and `mtime` describe
# the file when the dataset was read: a lazy read refuses a file that was replaced since.
mutable struct LazyState
    path::String
    size::Int64
    mtime::Float64
    loaded::Threads.Atomic{UInt32}
    lock::ReentrantLock
end

LazyState() =
    LazyState("", 0, 0.0, Threads.Atomic{UInt32}(typemax(UInt32)), ReentrantLock())

"""
    Dataset()

The complete in-memory database: the relational tables plus the string pools they
point into. A `Dataset` can hold several sources at once; `sources` names them and every
reference records the source it came from.
"""
struct Dataset
    sources::StringPool
    groups::StringPool
    methods::StringPool
    phases::StringPool
    kinds::StringPool
    extra_keys::StringPool
    extra_texts::StringPool
    origins::StringPool
    statuses::StringPool
    suppliers::StringPool
    analyses::StringPool
    purifications::StringPool
    purposes::StringPool
    unc_methods::StringPool
    evaluators::StringPool
    method_texts::StringPool
    condition_groups::StringPool
    condition_labels::StringPool
    references::ReferenceTable
    compounds::CompoundTable
    samples::SampleTable
    purity_steps::PurityStepTable
    properties::PropertyTable
    experiments::ExperimentTable
    measurements::MeasurementTable
    extras::ExtraTable
    conditions::ConditionTable
    uncertainties::UncertaintyTable
    lazy::LazyState
end

function Dataset()
    return Dataset(
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        StringPool(),
        ReferenceTable(),
        CompoundTable(),
        SampleTable(),
        PurityStepTable(),
        PropertyTable(),
        ExperimentTable(),
        MeasurementTable(),
        ExtraTable(),
        ConditionTable(),
        UncertaintyTable(),
        LazyState(),
    )
end

# Reading a dataset from its cache file loads the large tables only when something asks for
# them (see `load_lazy!`); this is how the field of a table is read, and for every other field
# it is the plain `getfield`, which the compiler resolves from the constant name.
@inline function Base.getproperty(ds::Dataset, name::Symbol)
    bit = lazy_bit(name)
    if bit != 0x00000000
        state = getfield(ds, :lazy)
        (state.loaded[] & bit) == 0x00000000 && load_lazy!(ds, name)
    end
    return getfield(ds, name)
end

"""
    loaded_tables(ds) -> Vector{Symbol}

The tables and pools of `ds` that are in memory. A dataset read from the cache holds the core
tables only; the tables of [`LAZY_FIELDS`](@ref) are read the first time something uses them.
"""
function loaded_tables(ds::Dataset)
    state = getfield(ds, :lazy)
    return Symbol[name for name in LAZY_FIELDS if (state.loaded[] & lazy_bit(name)) != 0]
end

Base.length(ds::Dataset) = length(ds.measurements)

function Base.show(io::IO, ds::Dataset)
    return print(
        io,
        "Dataset(",
        length(ds.measurements),
        " measurements, ",
        length(ds.references),
        " references, ",
        length(ds.compounds),
        " compounds, ",
        length(ds.properties),
        " properties)",
    )
end

# Every column of a struct-of-arrays table, flattened, to compare lengths.
function column_lengths(t::ReferenceTable)
    return map(
        length,
        (t.doi, t.title, t.journal, t.year, t.volume, t.pages, t.authors, t.source),
    )
end

function column_lengths(t::CompoundTable)
    return map(length, (t.key, t.inchikey, t.inchi, t.formula, t.names))
end

function column_lengths(t::SampleTable)
    return map(
        length,
        (
            t.reference,
            t.compound,
            t.number,
            t.origin,
            t.status,
            t.supplier,
            t.nsteps,
            t.purity,
            t.purity_kind,
            t.purity_initial,
            t.purity_initial_kind,
            t.water,
            t.purity_basis,
            t.analysis,
            t.purification,
        ),
    )
end

function column_lengths(t::PurityStepTable)
    return map(
        length,
        (
            t.sample,
            t.step,
            t.mass,
            t.mole,
            t.volume,
            t.unknown,
            t.digits,
            t.water_mass,
            t.water_mole,
            t.halide_mass,
            t.halide_mole,
            t.analysis,
            t.analysis_text,
            t.purification,
            t.purification_text,
        ),
    )
end

column_lengths(t::PropertyTable) = map(length, (t.label, t.unit, t.group))

function column_lengths(t::ExperimentTable)
    return (
        map(length, (t.reference, t.source, t.number, t.ncomp))...,
        map(length, t.components)...,
        map(length, t.kinds)...,
        map(length, t.samples)...,
        length(t.purpose),
    )
end

function column_lengths(t::MeasurementTable)
    return (
        map(
            length,
            (
                t.experiment,
                t.property,
                t.method,
                t.phase,
                t.value,
                t.unc,
                t.unc_k,
                t.unc_level,
                t.temperature,
                t.pressure,
                t.unc_method,
                t.evaluator,
                t.assessment,
                t.block,
                t.digits,
                t.temperature_digits,
                t.pressure_digits,
            ),
        )...,
        map(length, t.composition)...,
        map(length, t.composition_digits)...,
    )
end

function column_lengths(t::ConditionTable)
    return map(
        length,
        (
            t.scope,
            t.row,
            t.role,
            t.group,
            t.label,
            t.value,
            t.digits,
            t.phase,
            t.component,
            t.phase_component,
        ),
    )
end

function column_lengths(t::UncertaintyTable)
    return map(
        length,
        (t.scope, t.row, t.quantity, t.kind, t.origin, t.value, t.k, t.level, t.method),
    )
end

function column_lengths(t::ExtraTable)
    return map(length, (t.scope, t.row, t.key, t.number, t.text))
end

# True when every identifier in `ids` is `NO_ID` or a valid position in `1:n`.
in_range(ids::AbstractVector{<:Integer}, n::Integer) = all(id -> 0 <= id <= n, ids)
in_range(lists::AbstractVector{Vector{Int32}}, n::Integer) =
    all(ids -> in_range(ids, n), lists)

"""
    validate(ds::Dataset) -> true

Check the structural invariants of a dataset: equal column lengths inside every table and
identifiers that point at existing rows. Throws an `ArgumentError` naming the first
violation. Run after loading a cache or importing user data.
"""
function validate(ds::Dataset)
    validate_core(ds)
    validate_lazy(ds)
    return true
end

# The checks that need only what a dataset read from its cache keeps in memory.
function validate_core(ds::Dataset)
    tables = (
        :references => ds.references,
        :compounds => ds.compounds,
        :properties => ds.properties,
        :experiments => ds.experiments,
        :measurements => ds.measurements,
        :uncertainties => ds.uncertainties,
    )
    for (name, table) in tables
        allequal(column_lengths(table)) ||
            throw(ArgumentError("columns of the $name table have different lengths"))
    end
    ex, me = ds.experiments, ds.measurements
    checks = (
        "reference of an experiment" => in_range(ex.reference, length(ds.references)),
        "component of an experiment" =>
            all(c -> in_range(c, length(ds.compounds)), ex.components),
        "composition kind" => all(k -> in_range(k, length(ds.kinds)), ex.kinds),
        "purpose of an experiment" => in_range(ex.purpose, length(ds.purposes)),
        "uncertainty method of a measurement" =>
            in_range(me.unc_method, length(ds.unc_methods)),
        "uncertainty evaluator of a measurement" =>
            in_range(me.evaluator, length(ds.evaluators)),
        "property block of a measurement" => in_range(me.block, length(me)),
        "experiment of a measurement" => in_range(me.experiment, length(ex)),
        "property of a measurement" => in_range(me.property, length(ds.properties)),
        "method of a measurement" => in_range(me.method, length(ds.methods)),
        "phase of a measurement" => in_range(me.phase, length(ds.phases)),
        "group of a property" => in_range(ds.properties.group, length(ds.groups)),
        "source of a reference" => in_range(ds.references.source, length(ds.sources)),
    )
    for (what, ok) in checks
        ok || throw(ArgumentError("invalid identifier: $what points outside its table"))
    end
    validate_uncertainties(ds)
    return nothing
end

# The checks of the tables that are read from the cache file on first use; they read them.
function validate_lazy(ds::Dataset)
    for (name, table) in (
        :samples => ds.samples,
        :purity_steps => ds.purity_steps,
        :extras => ds.extras,
        :conditions => ds.conditions,
    )
        allequal(column_lengths(table)) ||
            throw(ArgumentError("columns of the $name table have different lengths"))
    end
    ex = ds.experiments
    checks = (
        "sample of an experiment" =>
            all(c -> in_range(c, length(ds.samples)), ex.samples),
        "reference of a sample" =>
            in_range(ds.samples.reference, length(ds.references)),
        "compound of a sample" => in_range(ds.samples.compound, length(ds.compounds)),
        "origin of a sample" => in_range(ds.samples.origin, length(ds.origins)),
        "status of a sample" => in_range(ds.samples.status, length(ds.statuses)),
        "supplier of a sample" => in_range(ds.samples.supplier, length(ds.suppliers)),
        "analysis of a sample" => in_range(ds.samples.analysis, length(ds.analyses)),
        "purification of a sample" =>
            in_range(ds.samples.purification, length(ds.purifications)),
        "sample of a purity step" =>
            in_range(ds.purity_steps.sample, length(ds.samples)),
        "analysis of a purity step" =>
            in_range(ds.purity_steps.analysis, length(ds.analyses)),
        "purification of a purity step" =>
            in_range(ds.purity_steps.purification, length(ds.purifications)),
        "text of a purity step" =>
            in_range(ds.purity_steps.analysis_text, length(ds.extra_texts)) &&
            in_range(ds.purity_steps.purification_text, length(ds.extra_texts)),
    )
    for (what, ok) in checks
        ok || throw(ArgumentError("invalid identifier: $what points outside its table"))
    end
    validate_extras(ds)
    validate_conditions(ds)
    return nothing
end

function validate_extras(ds::Dataset)
    ex = ds.extras
    in_range(ex.key, length(ds.extra_keys)) && in_range(ex.text, length(ds.extra_texts)) ||
        throw(ArgumentError("invalid identifier: an extra points outside its pool"))
    for i in eachindex(ex.row)
        code = ex.scope[i]
        (1 <= code <= length(EXTRA_SCOPES) && 1 <= ex.row[i] <= scope_length(ds, code)) ||
            throw(ArgumentError("invalid identifier: extra $i points outside its table"))
    end
    return nothing
end

function validate_conditions(ds::Dataset)
    c = ds.conditions
    in_range(c.group, length(ds.condition_groups)) &&
    in_range(c.label, length(ds.condition_labels)) &&
    in_range(c.phase, length(ds.phases)) &&
    in_range(c.component, length(ds.compounds)) &&
    in_range(c.phase_component, length(ds.compounds)) ||
        throw(ArgumentError("invalid identifier: a condition points outside its pool"))
    for i in eachindex(c.row)
        code = c.scope[i]
        (
            1 <= code <= length(CONDITION_SCOPES) &&
            1 <= c.role[i] <= length(CONDITION_ROLES) &&
            1 <= c.row[i] <= (code == 1 ? length(ds.experiments) : length(ds.measurements))
        ) || throw(
            ArgumentError("invalid identifier: condition $i points outside its table"),
        )
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Extras API
# ----------------------------------------------------------------------------------

function scope_length(ds::Dataset, code::Integer)
    code == 1 && return length(ds.references)
    code == 2 && return length(ds.compounds)
    code == 3 && return length(ds.experiments)
    return length(ds.measurements)   # a measurement, or the first point of a block
end

# The identifier of an extra key, which must fit the one-byte column of the extras table.
extra_key_code(ds::Dataset, key::AbstractString) =
    narrow(UInt8, intern!(ds.extra_keys, key), "extra key")

"""
    add_extra!(ds, scope, row, key, value)

Attach the field `key` with a number or a string `value` to row `row` of the table named
by `scope` (`:reference`, `:compound`, `:experiment` or `:measurement`; `:block` is the
scope the parser uses for the fields that all the points of a measured property share, see
[`MeasurementTable`](@ref)). Adding the same key to the same row twice keeps both entries;
readers use the last one.
"""
function add_extra!(
    ds::Dataset,
    scope::Symbol,
    row::Integer,
    key::AbstractString,
    value::Union{Real,AbstractString},
)
    code = scope_code(scope)
    isempty(key) && throw(ArgumentError("an extra field needs a non-empty key"))
    1 <= row <= scope_length(ds, code) ||
        throw(ArgumentError("row $row does not exist in the $scope table"))
    ex = ds.extras
    push!(ex.scope, code)
    push!(ex.row, Int32(row))
    push!(ex.key, extra_key_code(ds, key))
    if value isa AbstractString
        push!(ex.number, NaN)
        push!(ex.text, intern!(ds.extra_texts, value))
    else
        push!(ex.number, Float64(value))
        push!(ex.text, NO_ID)
    end
    return length(ex)
end

"""
    extra_keys(ds, scope) -> Vector{String}

Sorted names of the extra fields present for `scope`.
"""
function extra_keys(ds::Dataset, scope::Symbol)
    code = scope_code(scope)
    ex = ds.extras
    block = scope_code(:block)
    ids = unique(
        ex.key[i] for i in eachindex(ex.key) if
        ex.scope[i] == code || (scope == :measurement && ex.scope[i] == block)
    )
    return sort!([pool_string(ds.extra_keys, id) for id in ids])
end

"""
    extra_numbers(ds, scope, key) -> Vector{Float64}

Dense column with one entry per row of the `scope` table: the numeric extra `key`, or
`NaN` where the row has none.
"""
function extra_numbers(ds::Dataset, scope::Symbol, key::AbstractString)
    return extra_column(ds, scope, key, false)
end

"""
    extra_texts(ds, scope, key) -> Vector{String}

Dense column with one entry per row of the `scope` table: the text extra `key`, or `""`
where the row has none.
"""
function extra_texts(ds::Dataset, scope::Symbol, key::AbstractString)
    return extra_column(ds, scope, key, true)
end

# The extras that are the same for every point of a block are stored once, on the first
# point of the block (`:block`); for `:measurement` they are spread over the points of the
# block, and an extra attached to a single point wins over the one of its block.
function extra_column(ds::Dataset, scope::Symbol, key::AbstractString, text::Bool)
    code = scope_code(scope)
    n = scope_length(ds, code)
    column = text ? fill("", n) : fill(NaN, n)
    key_id = get(ds.extra_keys.index, key, NO_ID)
    key_id == NO_ID && return column
    ex = ds.extras
    wanted(i) = ex.key[i] == key_id && (ex.text[i] != NO_ID) == text
    value(i) = text ? pool_string(ds.extra_texts, ex.text[i]) : ex.number[i]
    if scope != :measurement
        for i in eachindex(ex.row)
            ex.scope[i] == code && wanted(i) && (column[ex.row[i]] = value(i))
        end
        return column
    end
    block_code = scope_code(:block)
    at_block = Dict{Int32,eltype(column)}()
    explicit = falses(n)
    for i in eachindex(ex.row)
        wanted(i) || continue
        if ex.scope[i] == code
            column[ex.row[i]] = value(i)
            explicit[ex.row[i]] = true
        elseif ex.scope[i] == block_code
            at_block[ex.row[i]] = value(i)
        end
    end
    isempty(at_block) && return column
    blocks = ds.measurements.block
    for r = 1:n
        (explicit[r] || blocks[r] == NO_ID) && continue
        found = get(at_block, blocks[r], nothing)
        found === nothing || (column[r] = found)
    end
    return column
end

function validate_uncertainties(ds::Dataset)
    u = ds.uncertainties
    in_range(u.method, length(ds.unc_methods)) ||
        throw(ArgumentError("invalid identifier: an uncertainty points outside its pool"))
    seen = Set{NTuple{5,Int}}()
    for i in eachindex(u.row)
        code = u.scope[i]
        (
            1 <= code <= length(UNCERTAINTY_SCOPES) &&
            1 <= u.quantity[i] <= length(UNCERTAINTY_QUANTITIES) &&
            1 <= u.kind[i] <= length(UNCERTAINTY_KINDS) &&
            1 <= u.origin[i] <= length(UNCERTAINTY_ORIGINS) &&
            1 <= u.row[i] <= (code == 1 ? length(ds.experiments) : length(ds.measurements))
        ) || throw(
            ArgumentError("invalid identifier: uncertainty $i points outside its table"),
        )
        (isfinite(u.value[i]) && u.value[i] >= 0 && isfinite(u.k[i]) && u.k[i] > 0) ||
            throw(ArgumentError("uncertainty $i has no valid value and coverage factor"))
        key =
            (Int(code), Int(u.row[i]), Int(u.quantity[i]), Int(u.kind[i]), Int(u.origin[i]))
        key in seen && throw(
            ArgumentError(
                "uncertainty $i repeats a term of the same row, quantity, kind and origin",
            ),
        )
        push!(seen, key)
    end
    return nothing
end
