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
    table(view; units = :native, policy = :nominal, quantities = nothing) -> NamedTuple

Materialise a [`DataView`](@ref) as a `NamedTuple` of columns (a valid Tables.jl table,
so `DataFrame(table(v))` works). One row per point, with the columns

`source, doi, year, components, xkind, property, method, phase, temperature, pressure,
x1, x2, x3, value, unit, unc, unc_k, unc_level, unc_k2`.

With `details = true` the table also has what the source says about the data: `purpose`
(purpose of the experiment), `unc_method` (how the uncertainty was evaluated), `digits`,
`temperature_digits` and `pressure_digits` (significant digits, `-1` when not given) and,
for each component `i`, `purityi`, `purity_kindi` and `purity_basisi` from its sample (see
[`sample_table`](@ref)); `NaN` or `""` where the source does not say.

`units = :native` keeps the unit of the source (kPa, kJ/mol, ...). `units = :si` converts
`value`, `unc`, `unc_k2` and `pressure` (to Pa) and reports the SI unit in `unit`.
`unc_k2` is the uncertainty at `k = 2` (see `coverage_factor` for `policy`); it is `NaN`
where it cannot be derived without inventing data, and a warning counts such rows.
Compositions `x1..x3` are as the source gave them: `xkind` tells what they express. With
`composition = :mass_fraction` (or any other of [`COMPOSITION_SCALES`](@ref)) they are
converted to that scale; `solvent`, `molar_mass`, `compounds`, `density`, `fetch_molar_mass` and `strict`
are those of [`convert_composition`](@ref), `NaN` marks a point that could not be converted
(`details = true` adds `composition_status` with the reason, and a warning counts them).

With `quantities = Unitful` (or the module of another units package that has an extension,
such as DynamicQuantities) the columns `temperature`, `pressure`, `value`, `unc` and
`unc_k2` hold quantities of that package (`temperature` in K, `pressure` in kPa or Pa for
`units = :si`). A column of quantities has one concrete type, which keeps broadcasting fast,
so the selection must contain a single unit: narrow it with `property` first, or an
`ArgumentError` lists the units found. Dimensionless properties stay plain numbers. The
`unit` column is kept as text.

`unit` asks for the columns `value`, `unc` and `unc_k2` in another unit of the same
quantity, for a selection with a single unit: as text (`unit = "mW/m/K"`,
`"Btu/hr/ft/degF"`, `"mbar"`), which the package reads with exact rational arithmetic
(SI prefixes, compound units and the customary units are understood), or as a unit object of
a loaded units package (`unit = u"mW/m/K"`), which also makes the columns quantities of that
package. The dimensions are checked, and `units = :si` cannot be given at the same time. A
degree of temperature is an interval inside a compound unit; a temperature scale with an
offset (`"degC"`) is refused as the unit of a property.

When `unit` (or `temperature_unit`, `pressure_unit`) is an object of a units package, the
package is asked for the unit as text. If the exact parser of this package reads it, the
conversion is done here, exactly, and the package only receives the converted column; if it
does not (a symbol that is not known here), the units package converts. `temperature_unit`
and `pressure_unit` give the columns `temperature` and `pressure` in any unit of those
quantities, as text (`"degC"`, `"degF"`, `"mK"`, `"bar"`, `"mbar"`, `"psi"`, `"N/m2"`) or as
a unit object; `pressure_unit` cannot be combined with `units = :si`.
"""
function table(
    view::DataView;
    units::Symbol = :native,
    policy::Symbol = :nominal,
    quantities = nothing,
    unit = nothing,
    temperature_unit = nothing,
    pressure_unit = nothing,
    details::Bool = false,
    composition::Union{Nothing,Symbol} = nothing,
    solvent = nothing,
    molar_mass = nothing,
    compounds = nothing,
    density = nothing,
    fetch_molar_mass::Bool = false,
    strict::Bool = false,
)
    units in TABLE_UNITS ||
        throw(ArgumentError("units must be one of $(TABLE_UNITS), got :$units"))
    unit === nothing ||
        units === :native ||
        throw(ArgumentError("give `unit` or `units = :si`, not both"))
    pressure_unit === nothing ||
        units === :native ||
        throw(ArgumentError("give `pressure_unit` or `units = :si`, not both"))
    ds = view.dataset
    m, ex, rf, pr = ds.measurements, ds.experiments, ds.references, ds.properties
    rows = view.rows
    n = length(rows)

    backend = unit_backend(quantities)
    chosen = unit === nothing ? nothing : choose_unit(view, unit, backend)
    t_choice =
        temperature_unit === nothing ? nothing :
        choose_native_unit(NativeTemperature(), temperature_unit, backend)
    p_choice =
        pressure_unit === nothing ? nothing :
        choose_native_unit(NativePressure(), pressure_unit, backend)

    factor = ones(length(pr))
    offset = zeros(length(pr))
    unit_of = Vector{String}(undef, length(pr))
    for p = 1:length(pr)
        spec = unit_spec(pr.unit[p])
        if chosen !== nothing && spec !== nothing && spec.native == chosen.native
            factor[p] = chosen.factor
            offset[p] = chosen.offset
            unit_of[p] = chosen.text
        elseif units === :si && spec !== nothing
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
        o = offset[p]
        value[i] = iszero(o) ? m.value[r] * f : muladd(m.value[r], f, o)
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
    details && (columns = merge(columns, detail_columns(ds, rows)))
    if composition !== nothing
        converted = convert_composition(
            view,
            composition;
            solvent,
            molar_mass,
            compounds,
            density,
            fetch_molar_mass,
            strict,
        )
        warn_unconverted(converted)
        columns = merge(
            columns,
            (;
                xkind = converted.xkind,
                x1 = converted.x1,
                x2 = converted.x2,
                x3 = converted.x3,
            ),
        )
        details && (columns = merge(columns, (; composition_status = converted.status)))
    end
    if t_choice !== nothing
        columns = merge(
            columns,
            (; temperature = convert_choice(t_choice, NativeTemperature(), temperature)),
        )
    end
    if p_choice !== nothing
        columns = merge(
            columns,
            (; pressure = convert_choice(p_choice, NativePressure(), pressure)),
        )
    end
    for choice in (chosen, t_choice, p_choice)
        backend === nothing && choice !== nothing && (backend = choice.backend)
    end
    backend === nothing && return columns
    return attach_units(columns, units, backend, chosen, t_choice, p_choice)
end

# The unit asked for the temperature or the pressure: as text, converted by the exact
# arithmetic of the package (kelvin and kilopascal are the native units; degC and degF have an
# offset); as a unit object of a units package, the package gives its name as text and, when
# the exact parser reads it, the conversion is the same one; otherwise the package converts.
function choose_native_unit(kind, unit, backend)
    if unit isa Union{AbstractString,Symbol}
        text = String(unit)
        affine = FloatAffine(inv(named_unit(kind, text)))
        tag = backend === nothing ? nothing : parse_unit(backend, text)
        return (; affine, text, backend = nothing, tag)
    end
    owner = backend === nothing ? backend_of(unit) : backend
    text = unit_text(owner, unit)
    exact = text === nothing ? nothing : try_named_unit(kind, text)
    affine = exact === nothing ? nothing : FloatAffine(inv(exact))
    return (; affine, text = string(unit), backend = owner, tag = unit)
end

function convert_choice(choice, kind, column::Vector{Float64})
    choice.affine !== nothing && return apply(column, choice.affine)
    return Float64[convert_native(x, kind, choice.tag) for x in column]
end

# The unit asked for the columns `value`, `unc` and `unc_k2`. The selection must have one
# unit of the catalog; `unit` is text (understood by the exact parser, with SI prefixes and
# compound units) or a unit object of a units package, and then the package gives the factor.
function choose_unit(view::DataView, unit, backend)
    ds = view.dataset
    natives = unique(ds.properties.unit[ds.measurements.property[view.rows]])
    isempty(natives) && return nothing
    length(natives) > 1 && throw(
        ArgumentError(
            "`unit` needs a single unit, but the selection mixes " *
            join(map(repr, natives), ", ") *
            "; narrow it with `property` first",
        ),
    )
    spec = unit_spec(only(natives))
    spec === nothing && throw(
        ArgumentError(
            "the unit \"$(only(natives))\" of this selection is not in the catalog, " *
            "so it cannot be converted",
        ),
    )
    if unit isa Union{AbstractString,Symbol}
        text = String(unit)
        affine = quantity_affine(spec, text)
        affine === nothing && throw(
            ArgumentError(
                "cannot read \"$text\" as a unit; the manual lists the symbols the package knows",
            ),
        )
        tag = backend === nothing ? nothing : parse_unit(backend, text)
        return property_choice(spec, affine, text, nothing, tag)
    end
    owner = backend === nothing ? backend_of(unit) : backend
    # The package gives the unit as text; if the exact parser reads it, everything is done
    # here and the units package only receives the column. If it does not (a symbol it does
    # not know), the units package gives the factor.
    written = unit_text(owner, unit)
    affine = written === nothing ? nothing : quantity_affine(spec, written)
    if affine === nothing
        factor = Float64(backend_factor(owner, parse_unit(owner, spec.unitful), unit))
        return (;
            native = spec.native,
            factor,
            offset = 0.0,
            text = string(unit),
            backend = owner,
            tag = unit,
        )
    end
    return property_choice(spec, affine, string(unit), owner, unit)
end

# `affine` converts the unit asked for into the native unit of the property; the column is
# converted the other way. The uncertainty is an interval and takes the scale only.
function property_choice(spec, affine, text, backend, tag)
    forward = FloatAffine(inv(affine))
    return (;
        native = spec.native,
        factor = forward.scale,
        offset = forward.offset,
        text,
        backend,
        tag,
    )
end

# The text of a unit of the `unit` column in the syntax the units packages read: native
# strings go through the catalog ("kg/m3" is not valid Unitful syntax); SI strings are
# already written for `uparse`.
function backend_unit_text(text::AbstractString, units::Symbol)
    units === :si && return String(text)
    spec = unit_spec(text)
    spec === nothing &&
        throw(ArgumentError("the unit \"$text\" has no equivalent in the catalog"))
    return spec.unitful
end

attach_or_keep(backend, column, ::Nothing) = column
attach_or_keep(backend, column, unit) = attach_unit(backend, column, unit)

# The backend is chosen by the user once per call; the unit is only known at run time (it
# is the unit of the selected property), so every conversion is a call through a function
# barrier, compiled per concrete unit type, and the work is one broadcast per column.
function attach_units(
    columns::NamedTuple,
    units::Symbol,
    backend,
    chosen = nothing,
    t_choice = nothing,
    p_choice = nothing,
)
    present = unique(columns.unit)
    length(present) > 1 && throw(
        ArgumentError(
            "quantities need a single unit, but the selection mixes " *
            join(map(repr, present), ", ") *
            "; narrow it with `property` first",
        ),
    )
    text = isempty(present) ? "" : only(present)
    unit = if chosen !== nothing && text == chosen.text
        chosen.tag
    else
        isempty(text) ? nothing : parse_unit(backend, backend_unit_text(text, units))
    end
    return merge(
        columns,
        (;
            temperature = attach_unit(
                backend,
                columns.temperature,
                t_choice === nothing ? parse_unit(backend, "K") : t_choice.tag,
            ),
            pressure = attach_unit(
                backend,
                columns.pressure,
                if p_choice === nothing
                    parse_unit(backend, units === :si ? "Pa" : "kPa")
                else
                    p_choice.tag
                end,
            ),
            value = attach_or_keep(backend, columns.value, unit),
            unc = attach_or_keep(backend, columns.unc, unit),
            unc_k2 = attach_or_keep(backend, columns.unc_k2, unit),
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
    print_points(io, table(shown), length(shown), length(view) - length(shown))
    return nothing
end

# Prints `n` rows of a point table (the columns of `DISPLAY_COLUMNS`, plus `database` when the table
# has it) and the number of points left out.
function print_points(io::IO, cols, n::Integer, hidden::Integer)
    display =
        haskey(cols, :database) ? ((:database => "database"), DISPLAY_COLUMNS...) :
        DISPLAY_COLUMNS
    names = first.(display)
    cells = [[display_cell(cols[name][i]) for i = 1:n] for name in names]
    # Columns that are entirely empty (e.g. x3 for binaries) are not worth the width.
    keep = [j for j in eachindex(names) if any(!isempty, cells[j])]
    headers = [last(display[j]) for j in keep]
    widths =
        [max(length(headers[k]), maximum(length, cells[keep[k]])) for k in eachindex(keep)]
    numeric = [cols[names[j]] isa Vector{Float64} for j in keep]
    pad(text, k) = numeric[k] ? lpad(text, widths[k]) : rpad(text, widths[k])
    println(io, join((pad(headers[k], k) for k in eachindex(keep)), "  "))
    println(io, join((repeat("─", widths[k]) for k in eachindex(keep)), "  "))
    for i = 1:n
        println(io, join((pad(cells[keep[k]][i], k) for k in eachindex(keep)), "  "))
    end
    hidden > 0 && println(io, "… and ", hidden, " more points")
    return nothing
end
