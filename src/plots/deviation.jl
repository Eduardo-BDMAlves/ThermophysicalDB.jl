# Deviations between the experimental values and the calculated ones, as the figures show them.

const DEVIATION_KINDS = (:relative, :log, :smape, :smae, :srl, :absolute)

# What a dimensionless deviation is multiplied by, and how its unit is written.
const DEVIATION_UNITS = (
    percent = (100.0, raw"\%"),
    fraction = (1.0, "-"),
    permille = (1.0e3, raw"\mathrm{‰}"),
    ppm = (1.0e6, raw"\mathrm{ppm}"),
    ppb = (1.0e9, raw"\mathrm{ppb}"),
)

"""
    DeviationSpec(kind = :relative; unit = :percent, absolute_value = false,
                  alpha = 0.01, epsilon = 1e-4)

What a figure plots as the deviation of a calculated value `c` from an experimental one `e`
(the experimental value is the reference):

| `kind` | deviation |
| :-- | :-- |
| `:relative` | `(e - c) / e` |
| `:log` | `log(e / c)` (positive values only) |
| `:smape` | `2 abs(e - c) / (abs(e) + abs(c))`, without sign, between 0 and 2 |
| `:smae` | `sign(r) abs(r) tanh(abs(r) / alpha)` with `r = (e - c) / e` |
| `:srl` | `sign(r) (sqrt(r^2 + epsilon) - sqrt(epsilon))` with `r = (e - c) / e` |
| `:absolute` | `e - c`, in the unit of the property |

Every kind but `:absolute` is dimensionless and is shown in `unit`: `:percent` (default),
`:fraction` (`[-]`), `:permille`, `:ppm` or `:ppb`. `absolute_value = true` plots the absolute
value of any of them (`:smape` is never negative). `:smae` and `:srl` are the smooth
approximations of the absolute error of Noel et al. (arXiv 2303.09935, 2606.22068) with the sign
of the error added: they are losses, so they flatten the small deviations (for `abs(r)` much
smaller than `alpha`, or than the square root of `epsilon`) and follow `r` for the large ones;
`alpha` and `epsilon` are in units of the relative error.
"""
struct DeviationSpec
    kind::Symbol
    unit::Symbol
    absolute_value::Bool
    alpha::Float64
    epsilon::Float64
    function DeviationSpec(
        kind::Symbol = :relative;
        unit::Symbol = :percent,
        absolute_value::Bool = false,
        alpha::Real = 0.01,
        epsilon::Real = 1.0e-4,
    )
        kind in DEVIATION_KINDS || throw(
            ArgumentError("deviation must be one of $(DEVIATION_KINDS), got $(repr(kind))"),
        )
        haskey(DEVIATION_UNITS, unit) || throw(
            ArgumentError(
                "deviation_unit must be one of $(keys(DEVIATION_UNITS)), got $(repr(unit))",
            ),
        )
        alpha > 0 || throw(ArgumentError("alpha must be positive, got $alpha"))
        epsilon > 0 || throw(ArgumentError("epsilon must be positive, got $epsilon"))
        return new(kind, unit, absolute_value, Float64(alpha), Float64(epsilon))
    end
end

# The factor of the unit of a deviation; the absolute deviation has the unit of the property.
unit_factor(s::DeviationSpec) = s.kind === :absolute ? 1.0 : DEVIATION_UNITS[s.unit][1]

# The value of the deviation of one point; NaN when it is not defined (log of a ratio that is
# not positive, a relative error without an experimental value).
@inline function deviation_value(kind::Symbol, e::Float64, c::Float64, alpha, epsilon)
    kind === :absolute && return e - c
    if kind === :smape
        d = abs(e) + abs(c)
        return d == 0 ? 0.0 : 2 * abs(e - c) / d
    end
    if kind === :log
        r = e / c
        return r > 0 ? log(r) : NaN
    end
    e == 0 && return NaN
    r = (e - c) / e
    kind === :relative && return r
    kind === :smae && return sign(r) * abs(r) * tanh(abs(r) / alpha)
    return sign(r) * (sqrt(r * r + epsilon) - sqrt(epsilon))     # :srl
end

"""
    deviation!(out, experimental, calculated, spec::DeviationSpec) -> out

Fill `out` with the deviation of each calculated value from the experimental one (see
[`DeviationSpec`](@ref)); `NaN` where it is not defined or one of the values is `NaN`.
"""
function deviation!(
    out::AbstractVector{Float64},
    experimental::AbstractVector{<:Real},
    calculated::AbstractVector{<:Real},
    spec::DeviationSpec,
)
    n = length(out)
    (length(experimental) == n && length(calculated) == n) || throw(
        DimensionMismatch("the experimental and calculated values must have $n elements"),
    )
    factor = unit_factor(spec)
    kind, alpha, epsilon, absval = spec.kind, spec.alpha, spec.epsilon, spec.absolute_value
    @inbounds for i = 1:n
        d =
            factor * deviation_value(
                kind,
                Float64(experimental[i]),
                Float64(calculated[i]),
                alpha,
                epsilon,
            )
        out[i] = absval ? abs(d) : d
    end
    return out
end

"""
    deviation(experimental, calculated; kind = :relative, unit = :percent,
              absolute_value = false, alpha = 0.01, epsilon = 1e-4) -> Vector{Float64}

The deviations that the figures plot; see [`DeviationSpec`](@ref) for the kinds and the units.
"""
function deviation(
    experimental::AbstractVector{<:Real},
    calculated::AbstractVector{<:Real};
    kind::Symbol = :relative,
    kwargs...,
)
    spec = DeviationSpec(kind; kwargs...)
    return deviation!(
        Vector{Float64}(undef, length(experimental)),
        experimental,
        calculated,
        spec,
    )
end

const DEVIATION_SYMBOLS = (
    relative = raw"\delta",
    log = raw"\delta_{\ln}",
    smape = raw"\mathrm{SMAPE}",
    smae = raw"\delta_{\mathrm{SMAE}}",
    srl = raw"\delta_{\mathrm{SRL}}",
    absolute = raw"\Delta",
)

# The symbol of a deviation in an axis label, with the symbol of the property as a subscript.
function deviation_symbol(spec::DeviationSpec, symbol::AbstractString)
    sub = isempty(symbol) ? "" : string("_{", symbol, "}")
    full = string(DEVIATION_SYMBOLS[spec.kind], sub)
    return spec.absolute_value ? string(raw"\left|", full, raw"\right|") : full
end

"""
    deviation_label(spec, symbol, property_unit; format = :square) -> String

The LaTeX label of the axis of a deviation: its symbol with the symbol of the property as a
subscript (`\\delta_{\\rho}\\;[\\%]`), in the unit of `spec` or, for the absolute deviation, in the
unit of the property.
"""
function deviation_label(
    spec::DeviationSpec,
    symbol::AbstractString,
    property_unit::AbstractString;
    format = :square,
)
    sym = deviation_symbol(spec, symbol)
    spec.kind === :absolute && return axis_label(sym, property_unit; format)
    return join_label(sym, DEVIATION_UNITS[spec.unit][2], format)
end
