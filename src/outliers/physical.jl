# Stage 0 of the outlier detection: conditions that no physically meaningful measurement
# can violate. Only rules that follow from thermodynamic stability or from the definition
# of the quantity are used, so that a point rejected here is wrong, not just unusual.
#
#   - the temperature is positive and the pressure is not negative;
#   - a fraction lies in [0, 1] and the fractions of a system do not add up to more than 1;
#   - a property that is strictly positive for every stable fluid is greater than zero
#     (densities, volumes, heat capacities, compressibilities, transport coefficients,
#     the speed of sound, the surface tension, the vapor pressure);
#   - a property that cannot be negative is not (conductivities, ionic strength, enthalpy
#     and entropy of vaporization, absolute entropy);
#   - a property with a known floor respects it (cp/cv ≥ 1, relative permittivity ≥ 1,
#     refractive index ≥ 1).
#
# Saturation heat capacities, excess, partial and apparent properties are deliberately
# absent: they can legitimately be negative or zero.

"""
Property labels (lower case, without the unit) that are strictly positive for a stable
fluid. A heat capacity at constant pressure or volume is positive because the entropy is
concave in the energy; a compressibility is positive because the free energy is convex in
the volume (mechanical stability); a density, a volume, a transport coefficient, the speed
of sound, the surface tension and the vapor pressure are positive by definition.
"""
const STRICTLY_POSITIVE_PROPERTIES = Set([
    "mass density",
    "amount density",
    "specific volume",
    "molar volume",
    "molar heat capacity at constant pressure",
    "specific heat capacity at constant pressure",
    "heat capacity at constant pressure per volume",
    "molar heat capacity at constant volume",
    "specific heat capacity at constant volume",
    "heat capacity at constant volume per volume",
    "adiabatic compressibility",
    "isothermal compressibility",
    "compressibility factor",
    "viscosity",
    "thermal conductivity",
    "thermal diffusivity",
    "speed of sound",
    "surface tension liquid-gas",
    "vapor or sublimation pressure",
    # Transport coefficients and interfacial properties, positive by the second law
    # (entropy production cannot be negative) or by mechanical stability.
    "kinematic viscosity",
    "self diffusion coefficient",
    "binary diffusion coefficient",
    "interfacial tension",
    # Critical and triple points: absolute temperatures, pressures and densities.
    "critical temperature",
    "critical pressure",
    "critical density",
    "critical molar volume",
    "critical specific volume",
    "critical compressibility factor",
    "triple point temperature",
    "triple point pressure",
    "normal boiling temperature",
    "normal melting temperature",
    "boiling temperature at pressure p",
    "eutectic temperature",
    # Quantities defined through an exponential or a ratio of positive quantities:
    # K = exp(-ΔG/RT), γ = a/x, φ = f/(Py), the Henry constants and the fugacity.
    "activity coefficient",
    "fugacity",
    "fugacity coefficient",
    "henry's law constant (amount concentration scale)",
    "henry's law constant (molality scale)",
    "henry's law constant (mole fraction scale)",
    "equilibrium constant in terms of amount concentration (molarity)",
    "equilibrium constant in terms of molality",
    "equilibrium constant in terms of mole fraction",
    "equilibrium constant in terms of partial pressure",
])

"""
Properties that cannot be negative but may be zero: the conductivities (zero for an
insulator), the ionic strength (a sum of squares), the molality, and the enthalpy and
entropy of vaporization or sublimation (positive below the critical point, zero at it).
The third law gives a non-negative absolute entropy.
"""
const NONNEGATIVE_PROPERTIES = Set([
    "electrical conductivity",
    "molar conductivity",
    "ionic strength (amount concentration basis)",
    "ionic strength (molality basis)",
    "molality",
    "molar enthalpy of vaporization or sublimation",
    "molar entropy of vaporization or sublimation",
    "molar entropy",
])

"""
Properties with a lower bound other than zero: `cp/cv ≥ 1` (`cp - cv = TVα²/κ_T ≥ 0`), the
static permittivity `≥ 1` and the refractive index `≥ 1` (the vacuum values).
"""
const PROPERTY_FLOORS = Dict(
    "heat capacity ratio cp/cv" => 1.0,
    "relative permittivity at zero frequency" => 1.0,
    "refractive index (na d-line)" => 1.0,
    "refractive index (other wavelength)" => 1.0,
)

"Properties that are a fraction of the system and so lie in `[0, 1]`."
const FRACTION_PROPERTIES = Set([
    "mole fraction",
    "mass fraction",
    "volume fraction",
    "mole fraction in llg critical state",
    "mass fraction in llg critical state",
    "eutectic composition: mole fraction",
    "eutectic composition: mass fraction",
    "eutectic composition: volume fraction",
])

# Label as the rules see it: lower case, trimmed, and cut at the first comma in case the
# unit was left in the label ("Mass density, kg/m3").
normalized_label(label::AbstractString) = lowercase(strip(first(split(label, ','))))

"""
Bounds of one property: a value `v` violates the rule when `v < lo` (or `v ≤ lo` when
`strict`) or `v > hi`.
"""
struct PropertyBounds
    lo::Float64
    hi::Float64
    strict::Bool
    origin::String
end

const NO_BOUNDS = PropertyBounds(-Inf, Inf, false, "")

function property_bounds(label::AbstractString, limits)
    key = normalized_label(label)
    bounds = NO_BOUNDS
    if key in STRICTLY_POSITIVE_PROPERTIES
        bounds = PropertyBounds(0.0, Inf, true, "strictly positive property")
    elseif key in NONNEGATIVE_PROPERTIES
        bounds = PropertyBounds(0.0, Inf, false, "non-negative property")
    elseif haskey(PROPERTY_FLOORS, key)
        floor = PROPERTY_FLOORS[key]
        bounds = PropertyBounds(floor, Inf, false, "property bounded below by $floor")
    elseif key in FRACTION_PROPERTIES
        bounds = PropertyBounds(0.0, 1.0, false, "fraction in [0, 1]")
    end
    if limits !== nothing && haskey(limits, key)
        lo, hi = limits[key]
        bounds = PropertyBounds(
            lo === nothing || isnan(lo) ? -Inf : Float64(lo),
            hi === nothing || isnan(hi) ? Inf : Float64(hi),
            false,
            "limit supplied by the user",
        )
    end
    return bounds
end

# `known_limits` keys are matched like property labels: any case, unit ignored.
function normalize_limits(limits)
    limits === nothing && return nothing
    out = Dict{String,Tuple{Any,Any}}()
    for (label, bounds) in limits
        bounds isa Tuple{Any,Any} ||
            bounds isa AbstractVector && length(bounds) == 2 ||
            throw(ArgumentError("known_limits[$(repr(label))] must be a (low, high) tuple"))
        out[normalized_label(label)] = (bounds[1], bounds[2])
    end
    return out
end

"""
Tolerance, in absolute terms, with which a fraction may exceed 1 (or a sum of fractions
may exceed 1) before it is called a violation; sources round their compositions.
"""
const FRACTION_SLACK = 1.0e-6

"""
    physical_violation(ds, row, bounds, fraction_kind) -> String

Why measurement `row` of `ds` breaks a physical rule, or `""` when it breaks none.
`bounds` are the [`PropertyBounds`](@ref) of its property and `fraction_kind[k]` tells
whether composition kind `k` is a fraction.
"""
function physical_violation(
    ds::Dataset,
    row::Integer,
    bounds::PropertyBounds,
    fraction_kind::AbstractVector{Bool},
)
    m = ds.measurements
    value = m.value[row]
    if !isfinite(value)
        return "the value is not a finite number"
    end
    if bounds !== NO_BOUNDS
        violated =
            value < bounds.lo || value > bounds.hi || (bounds.strict && value <= bounds.lo)
        if violated
            interval = bounds.strict ? "(0, ∞)" : "[$(bounds.lo), $(bounds.hi)]"
            return "value $(value) outside the allowed range $(interval) ($(bounds.origin))"
        end
    end
    t = m.temperature[row]
    if isfinite(t) && t <= 0
        return "temperature $(t) K is not positive"
    end
    p = m.pressure[row]
    if isfinite(p) && p < 0
        return "pressure $(p) kPa is negative"
    end
    e = m.experiment[row]
    ex = ds.experiments
    total = 0.0
    counted = 0
    for i = 1:Int(ex.ncomp[e])
        kind = ex.kinds[i][e]
        (kind != NO_ID && fraction_kind[kind]) || continue
        x = m.composition[i][row]
        isfinite(x) || continue
        if x < -FRACTION_SLACK || x > 1 + FRACTION_SLACK
            return "composition $(x) of component $(i) is outside [0, 1]"
        end
        total += x
        counted += 1
    end
    if counted > 1 && total > 1 + FRACTION_SLACK
        return "the fractions of the system add up to $(total), more than 1"
    end
    return ""
end

fraction_kinds(ds::Dataset) =
    Bool[occursin("fraction", lowercase(s)) for s in ds.kinds.strings]
