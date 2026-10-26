# The public entry point of the outlier detection and the objects it returns.

# ----------------------------------------------------------------------------------
# Results
# ----------------------------------------------------------------------------------

"""
    ReasonRow

One reason why one point was not kept: see [`reasons`](@ref).
"""
struct ReasonRow
    pos::Int
    code::Symbol
    axis::Symbol
    statistic::Float64
    critical::Float64
    rank::Int
    z::Float64
    reference_value::Float64
    deviation::Float64
    certainty::Float64
    detail::String
end

"""
    DiagnosticRow

The trend diagnostics of one point along one axis: see [`diagnostics`](@ref).
"""
struct DiagnosticRow
    pos::Int
    stage::Symbol
    axis::Symbol
    z::Float64
    window::Int
    consensus::Int
    phi::Float64
    slope::Float64
    slope_sd::Float64
    curvature::Float64
    curvature_sd::Float64
    influence::Float64
    sign_test::Symbol
    cross::Float64
    cross_sd::Float64
    flagged::Bool
    transform::String
end

const KEPT = UInt8(0)
const OUTLIER = UInt8(1)
const DISPUTED = UInt8(2)
const CATEGORY_NAMES = (:kept, :outlier, :disputed)

"""
    OutlierResult

What [`find_outliers`](@ref) returns. It holds three [`DataView`](@ref)s that partition the
input, in input order:

- `kept`: points with no sign of being wrong;
- `outliers`: points declared outliers;
- `disputed`: points that one analysis questions and the others do not support, so that
  they are neither confirmed nor cleared.

It can be unpacked, `kept, outliers, disputed = find_outliers(view)`. Why a point was
excluded is in [`reasons`](@ref); the numbers behind the trend tests are in
[`diagnostics`](@ref); `result.counts` and `result.parameters` summarize the run and
`result.notes` holds the longer remarks (subgroups skipped, points without neighbours).
"""
struct OutlierResult
    kept::DataView
    outliers::DataView
    disputed::DataView
    input::DataView
    category::Vector{UInt8}
    reason_rows::Vector{ReasonRow}
    diagnostic_rows::Vector{DiagnosticRow}
    counts::NamedTuple
    parameters::NamedTuple
    notes::Vector{String}
end

Base.iterate(r::OutlierResult, state::Int = 1) =
    state > 3 ? nothing : ((r.kept, r.outliers, r.disputed)[state], state + 1)
Base.length(::OutlierResult) = 3
Base.eltype(::Type{OutlierResult}) = DataView

function Base.show(io::IO, r::OutlierResult)
    return print(
        io,
        "OutlierResult(",
        length(r.kept),
        " kept, ",
        length(r.outliers),
        " outliers, ",
        length(r.disputed),
        " disputed)",
    )
end

function Base.show(io::IO, ::MIME"text/plain", r::OutlierResult)
    c = r.counts
    n = max(c.input, 1)
    percent(x) = string(round(100x; digits = 2), " %")
    row(label, count) =
        println(io, "  ", rpad(label, 24), lpad(count, 9), lpad(percent(count / n), 11))
    println(io, "OutlierResult for ", c.input, " points")
    row("kept", length(r.kept))
    row("outliers", length(r.outliers))
    row("disputed", length(r.disputed))
    by_code = Dict{Symbol,Set{Int}}()
    for rr in r.reason_rows
        push!(get!(by_code, rr.code, Set{Int}()), rr.pos)
    end
    if !isempty(by_code)
        println(io, "points flagged by")
        for code in sort!(collect(keys(by_code)))
            row(string(code), length(by_code[code]))
        end
        if haskey(by_code, :trend_1d) && haskey(by_code, :joint_surface)
            row("trend_1d and joint", length(by_code[:trend_1d] ∩ by_code[:joint_surface]))
        end
    end
    println(io, "coverage")
    row("tested", c.tested)
    row("not tested", c.untested)
    row("single publication", c.single_source)
    if isfinite(c.certainty)
        println(io, "certainty of the flags")
        println(io, "  ", rpad("separation from noise", 24), lpad(percent(c.certainty), 9))
        isfinite(c.certainty_outliers) && println(
            io,
            "    ",
            rpad("outliers", 22),
            lpad(percent(c.certainty_outliers), 9),
        )
        isfinite(c.certainty_disputed) && println(
            io,
            "    ",
            rpad("disputed", 22),
            lpad(percent(c.certainty_disputed), 9),
        )
        isfinite(c.corroboration) && println(
            io,
            "  ",
            rpad("flagged by both analyses", 24),
            lpad(percent(c.corroboration), 9),
        )
    end
    return nothing
end

"""
    reasons(result) -> NamedTuple

Why every point that was not kept was excluded, as a Tables.jl table with one row per
point and reason (a point can have several). Columns:

- `index`: position of the point in the input view; `measurement`: its row in the dataset.
- `category`: `:outlier` or `:disputed`, the classification of the point as a whole.
- `code`: the analysis that raised this reason: `:physical_rule`, `:trend_1d`,
  `:joint_surface` or `:source_offset`.
- `axis`: the coordinate along which the trend was followed (`:T`, `:P`, `:x1`, `:x2`),
  `:joint` for the surface in all coordinates, or `:none`.
- `statistic`, `critical`, `rank`: the ESD statistic `Rᵢ`, its critical value `λᵢ` and the
  step `i` at which the point was removed; `NaN` and `0` where no ESD test was involved.
- `z`: standardized deleted residual of the point.
- `reference_value`, `deviation`: what the local fit predicts for the point, in the
  units of the property, and `value - reference_value`.
- `detail`: the reason in words.
- the context of the point: `source`, `doi`, `components`, `property`, `phase`, `method`,
  `temperature`, `pressure`, `x1`, `x2`, `x3`, `value`, `unit`.
"""
function reasons(r::OutlierResult)
    rows = r.reason_rows
    n = length(rows)
    ds = r.input.dataset
    measurement = Int[r.input.rows[row.pos] for row in rows]
    context = table(DataView(ds, Int32.(measurement)))
    positions = Int[row.pos for row in rows]
    # `table` was built from the measurements of the reasons, one row per reason.
    return (;
        index = positions,
        measurement,
        category = Symbol[CATEGORY_NAMES[r.category[row.pos]+1] for row in rows],
        code = Symbol[row.code for row in rows],
        axis = Symbol[row.axis for row in rows],
        statistic = Float64[row.statistic for row in rows],
        critical = Float64[row.critical for row in rows],
        rank = Int[row.rank for row in rows],
        z = Float64[row.z for row in rows],
        reference_value = Float64[row.reference_value for row in rows],
        deviation = Float64[row.deviation for row in rows],
        certainty = Float64[row.certainty for row in rows],
        detail = String[row.detail for row in rows],
        source = context.source,
        doi = context.doi,
        components = context.components,
        property = context.property,
        phase = context.phase,
        method = context.method,
        temperature = context.temperature,
        pressure = context.pressure,
        x1 = context.x1,
        x2 = context.x2,
        x3 = context.x3,
        value = context.value,
        unit = context.unit,
    )
end

"""
    diagnostics(result) -> NamedTuple

The numbers behind the trend analysis, for every point that had one, in long format (one
row per point and axis), as a Tables.jl table. They are diagnostics: the classification
is decided by `z` and the ESD test alone.

- `index`, `measurement`, `stage` (`:trend_1d` or `:joint_surface`), `axis`.
- `z`, `window` (points in the window), `consensus` (points that agree with the curve),
  `phi` (scale factor: 1 when the scatter matches the declared uncertainties, larger when
  the data are noisier).
- `slope`, `slope_sd`: derivative of the property with respect to the axis, in physical
  units (property unit per K, per kPa, per unit of composition), and its standard error.
- `curvature`, `curvature_sd`: second derivative with respect to the transformed axis (see
  `transform`), and its standard error.
- `influence`: how many standard errors the point moves the slope by being in the fit
  (a DFBETAS-like measure; `NaN` for points outside the consensus).
- `sign_test`: whether the sign of the slope agrees with thermodynamic stability. Along
  pressure, `dρ/dP > 0` and `dv/dP < 0` (densities and volumes); along temperature,
  `dP_sat/dT > 0` (vapor pressure), `dH/dT > 0` and `dS/dT > 0` (molar enthalpy and entropy):
  `:consistent`,
  `:violation`, `:inconclusive` (the interval of `sign_sigma` standard errors includes zero)
  or `:not_applicable`.
- `cross`, `cross_sd`: on the `:joint` rows, the mixed second derivative of the first two
  varying axes (for example `∂²y/∂T∂P`) in transformed units, and its standard error.
- `flagged`: whether the ESD test flagged the point along this axis.
- `transform`: coordinates in which the fit was made.
"""
function diagnostics(r::OutlierResult)
    rows = r.diagnostic_rows
    return (;
        index = Int[row.pos for row in rows],
        measurement = Int[r.input.rows[row.pos] for row in rows],
        stage = Symbol[row.stage for row in rows],
        axis = Symbol[row.axis for row in rows],
        z = Float64[row.z for row in rows],
        window = Int[row.window for row in rows],
        consensus = Int[row.consensus for row in rows],
        phi = Float64[row.phi for row in rows],
        slope = Float64[row.slope for row in rows],
        slope_sd = Float64[row.slope_sd for row in rows],
        curvature = Float64[row.curvature for row in rows],
        curvature_sd = Float64[row.curvature_sd for row in rows],
        influence = Float64[row.influence for row in rows],
        sign_test = Symbol[row.sign_test for row in rows],
        cross = Float64[row.cross for row in rows],
        cross_sd = Float64[row.cross_sd for row in rows],
        flagged = Bool[row.flagged for row in rows],
        transform = String[row.transform for row in rows],
    )
end

# ----------------------------------------------------------------------------------
# Preparing the points
# ----------------------------------------------------------------------------------

# Canonical form of the system of an experiment: components sorted by (compound, kind),
# so that "water + ethanol" and "ethanol + water" are one system and the composition
# axes always refer to the same component.
struct CanonicalSystem
    key::NTuple{6,Int32}
    slots::NTuple{3,Int8}
    ncomp::Int8
end

function canonical_system(ex::ExperimentTable, e::Integer)
    n = Int(ex.ncomp[e])
    slots = sort(collect(1:n); by = i -> (ex.components[i][e], ex.kinds[i][e]))
    key = zeros(Int32, 6)
    for (c, i) in enumerate(slots)
        key[2c-1] = ex.components[i][e]
        key[2c] = ex.kinds[i][e]
    end
    padded = ntuple(c -> c <= n ? Int8(slots[c]) : Int8(0), 3)
    return CanonicalSystem(ntuple(c -> key[c], 6), padded, Int8(n))
end

"""
    Prepared

The columns the analyses work on, one entry per input point.
"""
struct Prepared
    rows::Vector{Int32}
    y::Vector{Float64}
    u::Vector{Float64}
    coord::Matrix{Float64}
    ref::Vector{Int32}
    prop::Vector{Int32}
    phase::Vector{Int32}
    mask::Vector{UInt8}
    system::Vector{NTuple{6,Int32}}
end

function prepare_points(view::DataView, policy::Symbol, fraction_kind::Vector{Bool})
    ds = view.dataset
    m, ex = ds.measurements, ds.experiments
    n = length(view)
    y = Vector{Float64}(undef, n)
    u = Vector{Float64}(undef, n)
    coord = fill(NaN, n, 4)
    ref = Vector{Int32}(undef, n)
    prop = Vector{Int32}(undef, n)
    phase = Vector{Int32}(undef, n)
    mask = zeros(UInt8, n)
    system = Vector{NTuple{6,Int32}}(undef, n)
    cache = Dict{Int32,CanonicalSystem}()
    for pos = 1:n
        r = view.rows[pos]
        e = m.experiment[r]
        sys = get!(() -> canonical_system(ex, e), cache, e)
        y[pos] = m.value[r]
        u2, _ = k2_uncertainty(m.unc[r], m.unc_k[r], m.unc_level[r], policy)
        u[pos] = u2 / 2
        coord[pos, 1] = m.temperature[r]
        coord[pos, 2] = m.pressure[r]
        n_comp = Int(sys.ncomp)
        if n_comp >= 2
            first_slot = Int(sys.slots[1])
            second_slot = Int(sys.slots[2])
            xa = m.composition[first_slot][r]
            if !isfinite(xa) && n_comp == 2
                kind = ex.kinds[second_slot][e]
                other = m.composition[second_slot][r]
                if kind != NO_ID && fraction_kind[kind] && isfinite(other)
                    xa = 1 - other
                end
            end
            coord[pos, 3] = xa
            n_comp == 3 && (coord[pos, 4] = m.composition[second_slot][r])
        end
        bits = UInt8(0)
        for a = 1:4
            isfinite(coord[pos, a]) && (bits |= UInt8(1) << (a - 1))
        end
        mask[pos] = bits
        ref[pos] = ex.reference[e]
        prop[pos] = m.property[r]
        phase[pos] = m.phase[r]
        system[pos] = sys.key
    end
    return Prepared(Int32.(view.rows), y, u, coord, ref, prop, phase, mask, system)
end

# ----------------------------------------------------------------------------------
# Units of mistake
# ----------------------------------------------------------------------------------

# A flagged value that is a clean power of ten (or an offset of 273.15) away from what the
# trend predicts is probably a unit or conversion slip rather than a measurement error.
function unit_hint(value::Float64, reference::Float64)
    if value > 0 && reference > 0
        lr = log10(value / reference)
        n = round(lr)
        if n != 0 && abs(n) <= 6 && abs(lr - n) < 0.005
            return " The value is a factor 10^$(Int(n)) from the trend: a unit or decimal slip is possible."
        end
    end
    if abs(abs(value - reference) - 273.15) < 0.6
        return " The value is 273.15 away from the trend: a °C/K mix-up is possible."
    end
    return ""
end

# ----------------------------------------------------------------------------------
# Sign tests
# ----------------------------------------------------------------------------------

# Mechanical stability makes the density rise and the volume fall with pressure along an
# isotherm. Nothing is assumed about the temperature dependence: water below 4 °C has a
# density that rises with temperature, and that is physical.
# Sign of the derivative of a property along an axis that every stable single-phase fluid
# obeys (+1: increases, -1: decreases, 0: no rule). Along pressure: (∂ρ/∂P)_T = ρκ_T > 0.
# Along temperature: Clausius–Clapeyron dP_sat/dT = ΔH/(TΔV) > 0, (∂H/∂T)_P = cp > 0 and
# (∂S/∂T)_P = cp/T > 0 (the last two hold inside one phase, so they are only diagnostics).
function sign_rule(label::AbstractString, axis::Integer = 2)
    key = normalized_label(label)
    if axis == 2
        key in ("mass density", "amount density") && return 1
        key in ("specific volume", "molar volume") && return -1
    elseif axis == 1
        key in ("vapor or sublimation pressure", "molar enthalpy", "molar entropy") &&
            return 1
    end
    return 0
end

function sign_verdict(rule::Int, slope::Float64, sd::Float64, nsigma::Float64)
    (rule == 0 || !isfinite(slope) || !isfinite(sd)) && return :not_applicable
    signed = rule * slope
    signed - nsigma * sd > 0 && return :consistent
    signed + nsigma * sd < 0 && return :violation
    return :inconclusive
end

# ----------------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------------

"""
    find_outliers(view_or_dataset; kwargs...) -> OutlierResult

Look for wrong points in a selection of the database. It works like [`points`](@ref): hand
it a [`DataView`](@ref) (or a whole `Dataset`) and it returns, in an [`OutlierResult`](@ref),
three views that partition the input: `kept`, `outliers` and `disputed`.

```julia
v = points(db; component = "water", property = "Mass density")
kept, outliers, disputed = find_outliers(v)
reasons(result)        # why each excluded point was excluded
```

Three analyses run in order. Each needs enough neighbouring points to say something; a
point without them is reported as not tested, never as validated.

1. **Physical rules** (`physical = true`): conditions no real measurement can break
   (negative temperature, a fraction above 1, a non-positive density, `cp/cv < 1`, ...), plus
   the limits in `known_limits`. A point that fails is an outlier and is left out of the next
   analyses.
2. **Trend along one axis** (`trend = true`): points of the same system, property and phase
   that share the other conditions are put in order along T, P or composition, and a window
   of `window` neighbours is fitted with a robust parabola. Points of different sources and
   methods are compared with each other. The distance of each point to the curve fitted
   without it, in units of the expected scatter, is its `z`.
3. **Joint surface** (`joint = true`): when two or more axes vary, a quadratic surface with
   cross terms is fitted to the `neighbors` nearest points in all axes at once, which finds
   points that are consistent along each axis but not together.

The `z` values of each analysis are pooled and tested with Rosner's generalized extreme
studentized deviate test ([Rosner1983](@cite)), which finds several outliers without one
hiding another. A point flagged by the surface analysis alone is `disputed`; one flagged
along an axis is an `outlier`. Several points of the same publication that all lie on one
side of the others are `disputed` as a systematic offset of the source (`source_offset =
:outlier` makes them outliers).

# Keywords

- `physical`, `trend`, `joint`: switch each analysis on or off.
- `window = 9`: points per local parabola (at least 5). `min_points = 7`: shortest line that
  is analysed. `neighbors = nothing`: points per surface window, `4p` with `p = 6` (two
  varying axes) or `10` (three) coefficients.
- `consensus_fraction = 0.6`: fraction of a window that must agree with the curve.
  `inlier_threshold = 2.5`: distance, in units of scatter, beyond which a point is not
  part of the curve; a point is also never flagged with `|z|` below it.
- `level = 0.05`: probability of flagging anything in a set of points that has no outlier,
  shared among the tests that run on a subgroup. `max_outliers = nothing`: most outliers
  looked for per test, a count or a fraction (default `0.1` of the points). `critical =
  :auto`: critical values from Rosner's formula with a correction for small samples with
  several steps; `:rosner` is the plain formula. Both are closed formulas, nothing is
  simulated (see [`esd_critical_values`](@ref)).
- `transform = :auto`: coordinates of the fit; `:none`, or a `NamedTuple` with `response`
  (`:auto`, `:log`, `:identity`), `T` (`:auto`, `:inverse`, `:identity`) and `P` (`:auto`,
  `:log`, `:identity`).
- `tolerance = (T = 0.1, P = 0.01, x = 1e-3)`: differences below which two states are the
  same (K, fraction of the pressure, composition).
- `policy = :nominal`: how declared uncertainties are brought to a common basis, as in
  [`table`](@ref).
- `known_limits = nothing`: a `Dict` from property label to `(low, high)`; either side may be
  `nothing`. Example: `Dict("Mass density" => (0, 2500))`.
- `source_offset = :disputed`, `sign_sigma = 2.0`.
- `tile = 3`: largest number of neighbouring points that share one surface fit in the joint
  analysis (`1`: every point is fitted on its own). `screening = 0.7`: in the joint
  analysis every tile is first fitted with a cheap robust fit; the tiles where a point
  lies beyond `screening * inlier_threshold` (and the ones around a point beyond
  `inlier_threshold`) are fitted again with the more expensive and more robust consensus
  fit. `0` repeats every tile, which is the slowest and most conservative setting.
- `seed = 1`: seed of the deterministic generator that draws the subsets of the consensus
  fit. The same seed always gives the same result, on any number of threads.
- `max_joint_points = 250_000`: largest subgroup given to the joint analysis.

Results do not depend on the number of threads. The estimates assume the points of one
subgroup are independent; they are not independent when one publication reports a whole
series, which is why a systematic offset gets its own category.
"""
function find_outliers(ds::Dataset; kwargs...)
    return find_outliers(DataView(ds); kwargs...)
end

function find_outliers(
    view::DataView;
    physical::Bool = true,
    trend::Bool = true,
    joint::Bool = true,
    window::Integer = 9,
    min_points::Integer = 7,
    neighbors::Union{Nothing,Integer} = nothing,
    consensus_fraction::Real = 0.6,
    inlier_threshold::Real = 2.5,
    level::Real = 0.05,
    max_outliers = nothing,
    critical::Symbol = :auto,
    transform = :auto,
    tolerance = (;),
    policy::Symbol = :nominal,
    seed::Integer = 1,
    known_limits = nothing,
    source_offset::Symbol = :disputed,
    sign_sigma::Real = 2.0,
    max_joint_points::Integer = 250_000,
    screening::Real = 0.7,
    tile::Integer = 3,
)
    window >= 5 || throw(ArgumentError("window must be at least 5, got $window"))
    min_points >= 5 ||
        throw(ArgumentError("min_points must be at least 5, got $min_points"))
    0.5 <= consensus_fraction < 1 || throw(
        ArgumentError("consensus_fraction must be in [0.5, 1), got $consensus_fraction"),
    )
    inlier_threshold > 0 || throw(ArgumentError("inlier_threshold must be positive"))
    0 < level < 1 || throw(ArgumentError("level must be in (0, 1), got $level"))
    critical in CRITICAL_METHODS ||
        throw(ArgumentError("critical must be one of $(CRITICAL_METHODS), got :$critical"))
    source_offset in (:disputed, :outlier) || throw(
        ArgumentError("source_offset must be :disputed or :outlier, got :$source_offset"),
    )
    neighbors === nothing ||
        neighbors >= 8 ||
        throw(ArgumentError("neighbors must be at least 8, got $neighbors"))
    0 <= screening <= 1 ||
        throw(ArgumentError("screening must be in [0, 1], got $screening"))
    tile >= 1 || throw(ArgumentError("tile must be at least 1, got $tile"))
    limit = if max_outliers === nothing
        0.1
    elseif max_outliers isa Integer
        Int(max_outliers)
    elseif max_outliers isa Real
        Float64(max_outliers)
    else
        throw(ArgumentError("max_outliers must be an integer or a fraction"))
    end
    set = Settings(;
        window = Int(window),
        min_points = Int(min_points),
        neighbors = neighbors === nothing ? nothing : Int(neighbors),
        fraction = Float64(consensus_fraction),
        cutoff = Float64(inlier_threshold),
        level = Float64(level),
        max_outliers = limit,
        critical,
        seed = Int(seed),
        tolerance = Tolerance(
            tolerance isa NamedTuple ? tolerance :
            throw(ArgumentError("tolerance must be a NamedTuple")),
        ),
        sign_sigma = Float64(sign_sigma),
        max_joint_points = Int(max_joint_points),
        screening = Float64(screening),
        tile = Int(tile),
    )
    return run_detection(
        view,
        set,
        physical,
        trend,
        joint,
        transform,
        policy,
        normalize_limits(known_limits),
        source_offset,
    )
end
