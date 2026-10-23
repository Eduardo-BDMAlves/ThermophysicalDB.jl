# Materialising a DataView as columns, the Tables.jl interface and REPL display.

const TABLE_UNITS = (:native, :si)

compound_label(t::CompoundTable, c::Integer) =
    isempty(t.names[c]) ? t.key[c] : t.names[c][1]

function system_label(ds::Dataset, e::Integer)
    ex = ds.experiments
    n = Int(ex.ncomp[e])
    return join((compound_label(ds.compounds, ex.components[i][e]) for i = 1:n), " + ")
end

function kind_label(ds::Dataset, e::Integer)
    ex = ds.experiments
    n = Int(ex.ncomp[e])
    kinds = unique(pool_string(ds.kinds, ex.kinds[i][e]) for i = 1:n)
    return join(filter(!isempty, kinds), " / ")
end

# k = 2 uncertainty of one row: the source's own k when it gave one, otherwise its level
# of confidence. NaN when neither exists; `unsupported` counts levels we refuse to guess.
function k2_uncertainty(unc, k, level, policy)
    isnan(unc) && return (NaN, false)
    isnan(k) || return (unc * 2 / k, false)
    isnan(level) && return (NaN, false)
    try
        return (expanded_uncertainty_k2(unc, level; policy), false)
    catch err
        err isa ArgumentError || rethrow()
        return (NaN, true)
    end
end

"""
    table(view; units = :native, policy = :nominal, unitful = false) -> NamedTuple

Materialise a [`DataView`](@ref) as a `NamedTuple` of columns (a valid Tables.jl table,
so `DataFrame(table(v))` works). One row per point, with the columns

`source, doi, year, components, xkind, property, method, phase, temperature, pressure,
x1, x2, x3, value, unit, unc, unc_k, unc_level, unc_k2`.

`units = :native` keeps the unit of the source (kPa, kJ/mol, ...). `units = :si` converts
`value`, `unc`, `unc_k2` and `pressure` (to Pa) and reports the SI unit in `unit`.
`unc_k2` is the uncertainty at `k = 2` (see `coverage_factor` for `policy`); it is `NaN`
where it cannot be derived without inventing data, and a warning counts such rows.
Compositions `x1..x3` are never converted: `xkind` tells what they express.

With `unitful = true` the columns `temperature`, `pressure`, `value`, `unc` and `unc_k2`
hold `Unitful.Quantity` values (`temperature` in K, `pressure` in kPa or Pa for
`units = :si`). Every element of a `Vector{<:Quantity}` shares one concrete type, which
keeps broadcasting fast, so the selection must contain a single unit: narrow it with
`property` first, or an `ArgumentError` lists the units found. Dimensionless properties
stay plain numbers. The `unit` column is kept as text.
"""
function table(
    view::DataView;
    units::Symbol = :native,
    policy::Symbol = :nominal,
    unitful::Bool = false,
)
    units in TABLE_UNITS ||
        throw(ArgumentError("units must be one of $(TABLE_UNITS), got :$units"))
    ds = view.dataset
    m, ex, rf, pr = ds.measurements, ds.experiments, ds.references, ds.properties
    rows = view.rows
    n = length(rows)

    factor = ones(length(pr))
    unit_of = Vector{String}(undef, length(pr))
    for p = 1:length(pr)
        spec = unit_spec(pr.unit[p])
        if units === :si && spec !== nothing
            factor[p] = spec.to_si
            unit_of[p] = spec.si
        else
            unit_of[p] = pr.unit[p]
        end
    end
    pressure_factor = units === :si ? 1.0e3 : 1.0

    label = Vector{String}(undef, length(ex))
    kinds = Vector{String}(undef, length(ex))
    seen = falses(length(ex))

    source = Vector{String}(undef, n)
    doi = Vector{String}(undef, n)
    year = Vector{Int16}(undef, n)
    components = Vector{String}(undef, n)
    xkind = Vector{String}(undef, n)
    property = Vector{String}(undef, n)
    method = Vector{String}(undef, n)
    phase = Vector{String}(undef, n)
    temperature = Vector{Float64}(undef, n)
    pressure = Vector{Float64}(undef, n)
    x = ntuple(_ -> Vector{Float64}(undef, n), MAX_COMPONENTS)
    value = Vector{Float64}(undef, n)
    unit = Vector{String}(undef, n)
    unc = Vector{Float64}(undef, n)
    unc_k = Vector{Float64}(undef, n)
    unc_level = Vector{Float64}(undef, n)
    unc_k2 = Vector{Float64}(undef, n)

    unsupported = 0
    for (i, r) in enumerate(rows)
        e = m.experiment[r]
        if !seen[e]
            label[e] = system_label(ds, e)
            kinds[e] = kind_label(ds, e)
            seen[e] = true
        end
        ref = ex.reference[e]
        p = m.property[r]
        f = factor[p]
        source[i] = pool_string(ds.sources, rf.source[ref])
        doi[i] = rf.doi[ref]
        year[i] = rf.year[ref]
        components[i] = label[e]
        xkind[i] = kinds[e]
        property[i] = pr.label[p]
        method[i] = pool_string(ds.methods, m.method[r])
        phase[i] = pool_string(ds.phases, m.phase[r])
        temperature[i] = m.temperature[r]
        pressure[i] = m.pressure[r] * pressure_factor
        for j = 1:MAX_COMPONENTS
            x[j][i] = m.composition[j][r]
        end
        value[i] = m.value[r] * f
        unit[i] = unit_of[p]
        unc[i] = m.unc[r] * f
        unc_k[i] = m.unc_k[r]
        unc_level[i] = m.unc_level[r]
        u2, bad = k2_uncertainty(m.unc[r], m.unc_k[r], m.unc_level[r], policy)
        unc_k2[i] = u2 * f
        unsupported += bad
    end
    unsupported > 0 && @warn(
        "unc_k2 is NaN where the level of confidence is not one the package knows",
        rows = unsupported,
    )
    columns = (;
        source,
        doi,
        year,
        components,
        xkind,
        property,
        method,
        phase,
        temperature,
        pressure,
        x1 = x[1],
        x2 = x[2],
        x3 = x[3],
        value,
        unit,
        unc,
        unc_k,
        unc_level,
        unc_k2,
    )
    return unitful ? attach_units(columns, units) : columns
end

# Parses one unit string of the `unit` column. Native strings go through the catalog
# ("kg/m3" is not valid Unitful syntax); SI strings are already written for `uparse`.
function unitful_unit(text::AbstractString, units::Symbol)
    isempty(text) && return Unitful.NoUnits
    if units === :si
        return Unitful.uparse(text)
    end
    spec = unit_spec(text)
    spec === nothing &&
        throw(ArgumentError("the unit \"$text\" has no Unitful equivalent in the catalog"))
    return Unitful.uparse(spec.unitful)
end

# Function barrier: `unit` is only known at run time, so the broadcast is compiled
# per concrete unit type and stays type-stable inside.
attach(column::AbstractVector{Float64}, unit) = column .* unit
attach(column::AbstractVector{Float64}, ::typeof(Unitful.NoUnits)) = column

function attach_units(columns::NamedTuple, units::Symbol)
    present = unique(columns.unit)
    length(present) > 1 && throw(
        ArgumentError(
            "unitful = true needs a single unit, but the selection mixes " *
            join(map(repr, present), ", ") *
            "; narrow it with `property` first",
        ),
    )
    unit = unitful_unit(isempty(present) ? "" : only(present), units)
    pressure_unit = units === :si ? Unitful.Pa : KILOPASCAL
    return merge(
        columns,
        (;
            temperature = attach(columns.temperature, KELVIN),
            pressure = attach(columns.pressure, pressure_unit),
            value = attach(columns.value, unit),
            unc = attach(columns.unc, unit),
            unc_k2 = attach(columns.unc_k2, unit),
        ),
    )
end

# ----------------------------------------------------------------------------------
# Tables.jl
# ----------------------------------------------------------------------------------

Tables.istable(::Type{DataView}) = true
Tables.columnaccess(::Type{DataView}) = true
Tables.columns(view::DataView) = table(view)

# ----------------------------------------------------------------------------------
# Display
# ----------------------------------------------------------------------------------

const DISPLAY_COLUMNS = (
    :components => "components",
    :property => "property",
    :temperature => "T [K]",
    :pressure => "p [kPa]",
    :x1 => "x1",
    :x2 => "x2",
    :x3 => "x3",
    :value => "value",
    :unit => "unit",
    :unc_k2 => "U(k=2)",
)

function display_cell(x::AbstractString)
    return length(x) > 34 ? first(x, 33) * "…" : String(x)
end
display_cell(x::Real) = isnan(x) ? "" : string(round(x; sigdigits = 6))

function Base.show(io::IO, view::DataView)
    return print(io, "DataView(", length(view), " points)")
end

function Base.show(io::IO, ::MIME"text/plain", view::DataView; maxrows::Int = 12)
    total = length(view.dataset.measurements)
    println(io, "DataView: ", length(view), " of ", total, " points")
    isempty(view.rows) && return nothing
    shown = DataView(view.dataset, view.rows[1:min(end, maxrows)])
    cols = table(shown)
    names = first.(DISPLAY_COLUMNS)
    cells = [[display_cell(cols[name][i]) for i = 1:length(shown)] for name in names]
    # Columns that are entirely empty (e.g. x3 for binaries) are not worth the width.
    keep = [j for j in eachindex(names) if any(!isempty, cells[j])]
    headers = [last(DISPLAY_COLUMNS[j]) for j in keep]
    widths =
        [max(length(headers[k]), maximum(length, cells[keep[k]])) for k in eachindex(keep)]
    numeric = [cols[names[j]] isa Vector{Float64} for j in keep]
    pad(text, k) = numeric[k] ? lpad(text, widths[k]) : rpad(text, widths[k])
    println(io, join((pad(headers[k], k) for k in eachindex(keep)), "  "))
    println(io, join((repeat("─", widths[k]) for k in eachindex(keep)), "  "))
    for i = 1:length(shown)
        println(io, join((pad(cells[keep[k]][i], k) for k in eachindex(keep)), "  "))
    end
    hidden = length(view) - length(shown)
    hidden > 0 && println(io, "… and ", hidden, " more points")
    return nothing
end
