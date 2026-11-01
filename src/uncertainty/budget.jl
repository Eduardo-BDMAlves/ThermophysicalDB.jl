# Uncertainty terms supplied by the user: storing them, deriving the combined and the
# expanded uncertainty, and reading them back.
#
# The combination follows the GUM (JCGM 100:2008, 5.1.2 for uncorrelated inputs with unit
# sensitivity coefficients and 6.2 for the expansion) and NIST Technical Note 1297: a
# combined standard uncertainty `u_c`, an expanded uncertainty `U = k u_c`, and the
# coverage factor `k` always stated with the result. Propagation through a model (with
# sensitivity coefficients) is not done here; only the data the user supplies are kept.

const DERIVED_COMBINED_TEXT = "root sum of squares of the statistical and device terms"
const DERIVED_FROM_EXPANDED_TEXT = "expanded uncertainty divided by its coverage factor"
const DERIVED_EXPANDED_TEXT = "combined standard uncertainty times the coverage factor"

"Level of confidence the package pairs with a conventional coverage factor, `NaN` if none."
function level_of_coverage(k::Real)
    for (p, _, k_nominal) in COVERAGE_TABLE
        abs(k - k_nominal) <= 1.0e-9 && return p
    end
    return NaN
end

"""
    UncertaintyTerm(value; k, level)

An uncertainty with its coverage: `value` is the uncertainty in the unit of the quantity,
stated with the coverage factor `k` (a standard uncertainty has `k = 1`) or with the level
of confidence `level` as a fraction (for example `0.95`), from which `k` follows as in
[`coverage_factor`](@ref). One of the two is required, so a term never lacks its coverage.
Where a term is expected, a plain number means a standard uncertainty (`k = 1`).
"""
struct UncertaintyTerm
    value::Float64
    k::Float64
    level::Float64
    function UncertaintyTerm(value::Real; k::Real = NaN, level::Real = NaN)
        isfinite(value) && value >= 0 || throw(
            ArgumentError("an uncertainty must be finite and not negative, got $value"),
        )
        isnan(k) &&
            isnan(level) &&
            throw(
                ArgumentError(
                    "state the coverage of an uncertainty term: `k` or `level` " *
                    "(a plain number is a standard uncertainty, k = 1)",
                ),
            )
        kk = isnan(k) ? coverage_factor(level) : Float64(k)
        isfinite(kk) && kk > 0 ||
            throw(ArgumentError("the coverage factor must be finite and positive, got $k"))
        lv = isnan(level) ? level_of_coverage(kk) : Float64(level)
        return new(Float64(value), kk, lv)
    end
end

as_term(::Nothing) = nothing
as_term(t::UncertaintyTerm) = t
as_term(x::Real) = UncertaintyTerm(x; k = 1.0)

standard_value(t::UncertaintyTerm) = t.value / t.k

function uncertainty_scope(scope::Symbol)
    symbol_code("scope", UNCERTAINTY_SCOPES, scope)
end

"""
    set_uncertainty!(ds; scope, row, quantity, statistical, device, combined, expanded,
                     k = 2.0, level = NaN, method = "", evaluation = "") -> NamedTuple

Store the uncertainty terms of one quantity of a point (`scope = :measurement`, `row` a
row of `ds.measurements`) or of an experiment (`scope = :experiment`, a term shared by all
its points, such as the specification of a thermometer). `quantity` is one of
`$(UNCERTAINTY_QUANTITIES)`. Each term is optional: a plain number (a standard
uncertainty) or an [`UncertaintyTerm`](@ref) (value with its `k` or `level`), in the unit
of the quantity: kelvin, the pressure unit of the archive (kPa), the composition as stored
and, for the property, its unit.

For a point, the combined and the expanded uncertainty are derived when not given, in this
order of precedence:

1. the `combined` term is used as given;
2. otherwise the `expanded` term gives it, ``u_c = U / k``;
3. otherwise ``u_c = \\sqrt{\\sum u_i^2}`` over the `statistical` and `device` terms of
   the point and of its experiment (uncorrelated terms, GUM 5.1.2).

The expanded uncertainty is the `expanded` term when given and otherwise ``U = k u_c``
with the coverage `k` (or the `level`) of the call, ``k = 2`` by default. Every term is
stored with its coverage, and the derived ones are marked `:derived` and say how they
were obtained. For the property the expanded uncertainty also fills the `unc`, `unc_k` and
`unc_level` columns, which every existing function and export reads; `evaluation` is the
method that evaluated it (ThermoML accepts only `"Propagation of evaluated standard
uncertainties"` and `"Comparison with reference property values"`). The values the user
gives are taken as they are, and so is their consistency.

The terms of the experiment must be stored before those of its points. A call looks the
shared terms up in the whole table, so it is meant for the amounts of data a person
supplies, not for bulk loading. Returns `(; combined, expanded, k, level)`, the combined
standard uncertainty, the expanded uncertainty and its coverage (`NaN` for what could not
be derived).
"""
function set_uncertainty!(
    ds::Dataset;
    scope::Symbol,
    row::Integer,
    quantity::Symbol,
    statistical = nothing,
    device = nothing,
    combined = nothing,
    expanded = nothing,
    k::Real = 2.0,
    level::Real = NaN,
    method::AbstractString = "",
    evaluation::AbstractString = "",
)
    scope_code = uncertainty_scope(scope)
    q = symbol_code("quantity", UNCERTAINTY_QUANTITIES, quantity)
    t = ds.uncertainties
    nrows = scope === :experiment ? length(ds.experiments) : length(ds.measurements)
    1 <= row <= nrows || throw(ArgumentError("row $row is not a row of the $(scope) table"))
    terms = (
        statistical = as_term(statistical),
        device = as_term(device),
        combined = as_term(combined),
        expanded = as_term(expanded),
    )
    isnan(level) ||
        0 < level < 1 ||
        throw(ArgumentError("the level of confidence is a fraction in (0, 1), got $level"))
    isempty(evaluation) ||
        quantity === :property ||
        throw(ArgumentError("`evaluation` is the method of the property's uncertainty"))

    # one pass: refuse a second call for the same quantity, collect the shared terms
    experiment = scope === :measurement ? ds.measurements.experiment[row] : Int32(row)
    shared = Float64[]
    for i in eachindex(t.row)
        (t.quantity[i] == q && t.origin[i] == 0x01) || continue
        if t.scope[i] == scope_code && t.row[i] == row
            throw(
                ArgumentError(
                    "the uncertainties of $quantity of $(scope) $row are already set",
                ),
            )
        end
        if scope === :measurement &&
           t.scope[i] == 0x01 &&
           t.row[i] == experiment &&
           t.kind[i] <= 0x02
            push!(shared, t.value[i] / t.k[i])
        end
    end

    method_id = isempty(method) ? NO_ID : intern!(ds.unc_methods, method)
    function store!(kind, term::UncertaintyTerm, origin, id)
        return add_uncertainty!(
            t;
            scope,
            row,
            quantity,
            kind,
            value = term.value,
            k = term.k,
            level = term.level,
            method = id,
            origin,
        )
    end
    for (kind, term) in pairs(terms)
        term === nothing || store!(kind, term, :given, method_id)
    end
    scope === :experiment && return (; combined = NaN, expanded = NaN, k = NaN, level = NaN)

    # the combined standard uncertainty
    uc = NaN
    if terms.combined !== nothing
        uc = standard_value(terms.combined)
    elseif terms.expanded !== nothing
        uc = standard_value(terms.expanded)
        store!(
            :combined,
            UncertaintyTerm(uc; k = 1.0),
            :derived,
            intern!(ds.unc_methods, DERIVED_FROM_EXPANDED_TEXT),
        )
    else
        for kind in (:statistical, :device)
            term = getfield(terms, kind)
            term === nothing || push!(shared, standard_value(term))
        end
        if !isempty(shared)
            uc = sqrt(sum(abs2, shared))
            store!(
                :combined,
                UncertaintyTerm(uc; k = 1.0),
                :derived,
                intern!(ds.unc_methods, DERIVED_COMBINED_TEXT),
            )
        end
    end
    isnan(uc) && return (; combined = NaN, expanded = NaN, k = NaN, level = NaN)

    # the expanded uncertainty
    if terms.expanded !== nothing
        U, kU, lU = terms.expanded.value, terms.expanded.k, terms.expanded.level
    else
        kU = isnan(level) ? Float64(k) : coverage_factor(level)
        lU = isnan(level) ? level_of_coverage(kU) : Float64(level)
        U = kU * uc
        store!(
            :expanded,
            UncertaintyTerm(U; k = kU, level = lU),
            :derived,
            intern!(ds.unc_methods, DERIVED_EXPANDED_TEXT),
        )
    end
    if quantity === :property
        m = ds.measurements
        m.unc[row] = U
        m.unc_k[row] = kU
        m.unc_level[row] = lU
        isempty(evaluation) || (m.unc_method[row] = intern!(ds.unc_methods, evaluation))
    end
    return (; combined = uc, expanded = U, k = kU, level = lU)
end

# ----------------------------------------------------------------------------------
# Reading
# ----------------------------------------------------------------------------------

const UNCERTAINTY_KIND_NAMES = String.(UNCERTAINTY_KINDS)
const UNCERTAINTY_QUANTITY_NAMES = String.(UNCERTAINTY_QUANTITIES)
const UNCERTAINTY_ORIGIN_NAMES = String.(UNCERTAINTY_ORIGINS)

"""
    uncertainty_table(x) -> NamedTuple

The uncertainty terms of a [`Dataset`](@ref), or of the experiments and points behind a
[`DataView`](@ref), one row per term (see [`UncertaintyTable`](@ref)): a Tables.jl table
with the columns

`doi, experiment, measurement, quantity, kind, origin, value, k, level, standard, method`.

`measurement` is the row of the point, `-1` for a term shared by an experiment;
`quantity` is `"property"`, `"temperature"`, `"pressure"` or `"composition1"`...; `kind`
is `"statistical"`, `"device"`, `"combined"` or `"expanded"`; `origin` is `"given"` or
`"derived"`. `value` is the uncertainty as stated, `k` its coverage factor, `level` the
level of confidence (`NaN` if unknown), `standard = value / k` and `method` how it was
obtained. Units are those of the quantity, as stored. The ThermoML archive states only the
expanded uncertainty of the property, so a database built from it has no rows.
"""
function uncertainty_table(ds::Dataset; view::Union{Nothing,DataView} = nothing)
    u, ex, m = ds.uncertainties, ds.experiments, ds.measurements
    keep = trues(length(u))
    if view !== nothing
        used_experiment = falses(length(ex))
        used_row = falses(length(m))
        for r in view.rows
            used_row[r] = true
            used_experiment[m.experiment[r]] = true
        end
        for i in eachindex(u.row)
            keep[i] = u.scope[i] == 1 ? used_experiment[u.row[i]] : used_row[u.row[i]]
        end
    end
    ids = findall(keep)
    experiment_of(i) = u.scope[i] == 1 ? u.row[i] : m.experiment[u.row[i]]
    return (;
        doi = String[ds.references.doi[ex.reference[experiment_of(i)]] for i in ids],
        experiment = Int32[experiment_of(i) for i in ids],
        measurement = Int32[u.scope[i] == 2 ? u.row[i] : NO_ID for i in ids],
        quantity = String[UNCERTAINTY_QUANTITY_NAMES[u.quantity[i]] for i in ids],
        kind = String[UNCERTAINTY_KIND_NAMES[u.kind[i]] for i in ids],
        origin = String[UNCERTAINTY_ORIGIN_NAMES[u.origin[i]] for i in ids],
        value = u.value[ids],
        k = u.k[ids],
        level = u.level[ids],
        standard = u.value[ids] ./ u.k[ids],
        method = String[pool_string(ds.unc_methods, u.method[i]) for i in ids],
    )
end

uncertainty_table(view::DataView) = uncertainty_table(view.dataset; view)

"""
    expanded_uncertainty(view, quantity; k = 2.0, units = :native) -> Vector{Float64}

The expanded uncertainty ``U = k u_c`` of `quantity` (one of
`$(UNCERTAINTY_QUANTITIES)`) for each point of `view`, in the order of the view and
ready to be used as error bars. It is computed from the combined standard uncertainty
that was stored (or derived) for the point, so it can be given at any coverage `k`;
`NaN` where the point has none. For `:property` a point that has only the `unc` of the
archive is converted with its own coverage factor. `units = :si` converts the pressure
(kPa to Pa) and the property to the units of [`table`](@ref); temperature and
composition are not converted.
"""
function expanded_uncertainty(
    view::DataView,
    quantity::Symbol;
    k::Real = 2.0,
    units::Symbol = :native,
)
    units in TABLE_UNITS ||
        throw(ArgumentError("units must be one of $(TABLE_UNITS), got :$units"))
    isfinite(k) && k > 0 ||
        throw(ArgumentError("the coverage factor must be finite and positive, got $k"))
    q = symbol_code("quantity", UNCERTAINTY_QUANTITIES, quantity)
    ds = view.dataset
    m, u, pr = ds.measurements, ds.uncertainties, ds.properties
    combined = Dict{Int32,Float64}()
    for i in eachindex(u.row)
        (u.scope[i] == 2 && u.quantity[i] == q && u.kind[i] == 0x03) || continue
        combined[u.row[i]] = u.value[i] / u.k[i]
    end
    out = Vector{Float64}(undef, length(view.rows))
    for (j, r) in enumerate(view.rows)
        uc = get(combined, r, NaN)
        if isnan(uc) && q == 0x01 && !isnan(m.unc[r])
            kr = m.unc_k[r]
            if isnan(kr) && !isnan(m.unc_level[r])
                kr = try
                    coverage_factor(m.unc_level[r])
                catch
                    NaN
                end
            end
            isnan(kr) || (uc = m.unc[r] / kr)
        end
        factor = 1.0
        if units === :si
            if q == 0x03
                factor = 1.0e3
            elseif q == 0x01
                spec = unit_spec(pr.unit[m.property[r]])
                spec === nothing || (factor = spec.to_si)
            end
        end
        out[j] = k * uc * factor
    end
    return out
end
