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
    method_texts::StringPool
    references::ReferenceTable
    compounds::CompoundTable
    samples::SampleTable
    purity_steps::PurityStepTable
    properties::PropertyTable
    experiments::ExperimentTable
    measurements::MeasurementTable
    extras::ExtraTable
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
        ReferenceTable(),
        CompoundTable(),
        SampleTable(),
        PurityStepTable(),
        PropertyTable(),
        ExperimentTable(),
        MeasurementTable(),
        ExtraTable(),
    )
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
                t.digits,
                t.temperature_digits,
                t.pressure_digits,
            ),
        )...,
        map(length, t.composition)...,
        map(length, t.composition_digits)...,
    )
end

function column_lengths(t::ExtraTable)
    return map(length, (t.scope, t.row, t.key, t.number, t.text))
end

# True when every identifier in `ids` is `NO_ID` or a valid position in `1:n`.
in_range(ids::AbstractVector{Int32}, n::Integer) = all(id -> 0 <= id <= n, ids)
in_range(lists::AbstractVector{Vector{Int32}}, n::Integer) =
    all(ids -> in_range(ids, n), lists)

"""
    validate(ds::Dataset) -> true

Check the structural invariants of a dataset: equal column lengths inside every table and
identifiers that point at existing rows. Throws an `ArgumentError` naming the first
violation. Run after loading a cache or importing user data.
"""
function validate(ds::Dataset)
    tables = (
        :references => ds.references,
        :compounds => ds.compounds,
        :samples => ds.samples,
        :purity_steps => ds.purity_steps,
        :properties => ds.properties,
        :experiments => ds.experiments,
        :measurements => ds.measurements,
        :extras => ds.extras,
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
        "sample of an experiment" =>
            all(c -> in_range(c, length(ds.samples)), ex.samples),
        "purpose of an experiment" => in_range(ex.purpose, length(ds.purposes)),
        "uncertainty method of a measurement" =>
            in_range(me.unc_method, length(ds.unc_methods)),
        "experiment of a measurement" => in_range(me.experiment, length(ex)),
        "property of a measurement" => in_range(me.property, length(ds.properties)),
        "method of a measurement" => in_range(me.method, length(ds.methods)),
        "phase of a measurement" => in_range(me.phase, length(ds.phases)),
        "group of a property" => in_range(ds.properties.group, length(ds.groups)),
        "source of a reference" => in_range(ds.references.source, length(ds.sources)),
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
    return true
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

# ----------------------------------------------------------------------------------
# Extras API
# ----------------------------------------------------------------------------------

function scope_length(ds::Dataset, code::Integer)
    code == 1 && return length(ds.references)
    code == 2 && return length(ds.compounds)
    code == 3 && return length(ds.experiments)
    return length(ds.measurements)
end

"""
    add_extra!(ds, scope, row, key, value)

Attach the field `key` with a number or a string `value` to row `row` of the table named
by `scope` (`:reference`, `:compound`, `:experiment` or `:measurement`). Adding the same
key to the same row twice keeps both entries; readers use the last one.
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
    push!(ex.key, intern!(ds.extra_keys, key))
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
    ids = unique(ex.key[i] for i in eachindex(ex.key) if ex.scope[i] == code)
    return sort!([pool_string(ds.extra_keys, id) for id in ids])
end

"""
    extra_numbers(ds, scope, key) -> Vector{Float64}

Dense column with one entry per row of the `scope` table: the numeric extra `key`, or
`NaN` where the row has none.
"""
function extra_numbers(ds::Dataset, scope::Symbol, key::AbstractString)
    code = scope_code(scope)
    column = fill(NaN, scope_length(ds, code))
    key_id = get(ds.extra_keys.index, key, NO_ID)
    key_id == NO_ID && return column
    ex = ds.extras
    for i in eachindex(ex.row)
        if ex.scope[i] == code && ex.key[i] == key_id && ex.text[i] == NO_ID
            column[ex.row[i]] = ex.number[i]
        end
    end
    return column
end

"""
    extra_texts(ds, scope, key) -> Vector{String}

Dense column with one entry per row of the `scope` table: the text extra `key`, or `""`
where the row has none.
"""
function extra_texts(ds::Dataset, scope::Symbol, key::AbstractString)
    code = scope_code(scope)
    column = fill("", scope_length(ds, code))
    key_id = get(ds.extra_keys.index, key, NO_ID)
    key_id == NO_ID && return column
    ex = ds.extras
    for i in eachindex(ex.row)
        if ex.scope[i] == code && ex.key[i] == key_id && ex.text[i] != NO_ID
            column[ex.row[i]] = pool_string(ds.extra_texts, ex.text[i])
        end
    end
    return column
end
