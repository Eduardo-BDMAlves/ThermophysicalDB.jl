"""
Coverage factors for converting expanded uncertainties to a common `k = 2` basis.

An expanded uncertainty is `U = k * u`, where `u` is the standard uncertainty and `k`
the coverage factor. A source that reports `U` together with a level of confidence `p`
(the probability that the true value lies in `y ± U`) does not state `k`; it follows
only if a distribution is assumed. For a normal distribution `k` is the two-sided
quantile `z`, e.g. `z = 1.96` for `p = 0.95`. By convention (GUM) `k = 2` is used as the
round number for about 95 %. The two readings differ by about 2 %, so both are kept:

- `:nominal`: the conventional round `k` (0.95 -> 2). No distribution is assumed.
- `:normal`: the exact normal quantile (0.95 -> 1.95996...).
"""
const K2_POLICIES = (:nominal, :normal)

# (level, exact normal quantile, conventional k). Where no round convention exists
# the conventional k equals the quantile.
const COVERAGE_TABLE = (
    (0.6827, 1.0, 1.0),
    (0.90, 1.6448536269514722, 1.6448536269514722),
    (0.95, 1.959963984540054, 2.0),
    (0.9545, 2.0, 2.0),
    (0.99, 2.5758293035489004, 2.5758293035489004),
    (0.9973, 3.0, 3.0),
)

const LEVEL_TOLERANCE = 5.0e-4

"""
    coverage_factor(level; policy = :nominal) -> Float64

Coverage factor `k` for a two-sided `level` of confidence given as a fraction in `(0, 1)`
(for example `0.95`, not `95`). Supported levels are 0.6827, 0.90, 0.95, 0.9545, 0.99 and
0.9973; any other level throws an `ArgumentError`, because guessing would invent data.
"""
function coverage_factor(level::Real; policy::Symbol = :nominal)
    policy in K2_POLICIES ||
        throw(ArgumentError("policy must be one of $(K2_POLICIES), got :$policy"))
    0 < level < 1 || throw(ArgumentError("level must be a fraction in (0, 1), got $level"))
    for (p, z, k_nominal) in COVERAGE_TABLE
        abs(level - p) <= LEVEL_TOLERANCE && return policy === :normal ? z : k_nominal
    end
    supported = join((row[1] for row in COVERAGE_TABLE), ", ")
    throw(ArgumentError("unsupported level of confidence $level; supported: $supported"))
end

"""
    expanded_uncertainty_k2(U, level; policy = :nominal) -> Float64

Rescale an expanded uncertainty `U` reported at `level` of confidence to `k = 2`:
`U * 2 / k`. `NaN` (the package's marker for a missing uncertainty) is propagated.
"""
function expanded_uncertainty_k2(U::Real, level::Real; policy::Symbol = :nominal)
    k = coverage_factor(level; policy)
    return Float64(U) * (2.0 / k)
end
