# Generalized extreme studentized deviate (ESD) test of Rosner (1983) for up to r outliers
# in an approximately normal sample.
#
# The test removes, one at a time, the value farthest from the mean of what is left, and
# records the studentized distance
#
#     Rᵢ = max |x - x̄⁽ⁱ⁾| / s⁽ⁱ⁾          (mean and standard deviation of the n - i + 1 values left)
#
# It compares Rᵢ with a critical value λᵢ and declares as many outliers as the largest i
# with Rᵢ > λᵢ. Looking at the largest i first is what protects against masking: two
# outliers that hide each other in the first step are caught in the second.
#
# The critical values come from Rosner's closed formula; nothing is simulated, so the result
# is a pure function of (n, r, level). The formula is an approximation of the percentage
# points of Rᵢ. It is exact for the first step (Grubbs' test) and, in simulations of the whole
# procedure, keeps the probability of a false alarm within a few per cent of the nominal level
# for n ≥ 50. For small samples with several steps it is anticonservative (the false-alarm
# probability is up to twice the nominal one), and a correction that depends only on r and n
# is applied by default, see [`esd_critical_values`](@ref).

"""
    normal_cdf(x) -> Float64

Standard normal cumulative distribution function.
"""
normal_cdf(x::Real) = 0.5 * SpecialFunctions.erfc(-x / sqrt(2.0))

"""
    normal_quantile(p) -> Float64

Inverse of [`normal_cdf`](@ref) for `0 < p < 1`.
"""
function normal_quantile(p::Real)
    0 < p < 1 || throw(ArgumentError("p must be in (0, 1), got $p"))
    return sqrt(2.0) * SpecialFunctions.erfinv(2p - 1)
end

"""
    student_t_upper_quantile(tail, ν) -> Float64

The value `t` with `P(T > t) = tail` for Student's t distribution with `ν` degrees of
freedom, `0 < tail < 1/2`. The tail probability is taken directly, instead of `1 - tail`,
so that very small tails keep their precision.
"""
function student_t_upper_quantile(tail::Real, ν::Real)
    0 < tail < 0.5 || throw(ArgumentError("tail must be in (0, 1/2), got $tail"))
    ν > 0 || throw(ArgumentError("degrees of freedom must be positive, got $ν"))
    q = 2tail
    x, _ = SpecialFunctions.beta_inc_inv(ν / 2, 0.5, q, 1 - q)
    return sqrt(ν * (1 - x) / x)
end

"""
    rosner_lambda(n, i, level) -> Float64

Critical value `λᵢ` of Rosner's generalized ESD test for a sample of `n` values at
significance `level`, step `i = 1, 2, …, n - 2`:

```math
\\lambda_i=\\frac{(n-i)\\,t_{p,\\,n-i-1}}{\\sqrt{\\left(n-i-1+t_{p,\\,n-i-1}^{2}\\right)(n-i+1)}},
\\qquad p=1-\\frac{\\text{level}}{2\\,(n-i+1)}
```

where `t_{p,ν}` is the `p` quantile of Student's t distribution with `ν` degrees of
freedom. For `i = 1` it is exactly the critical value of Grubbs' test. The formula is an
approximation of the percentage points of `Rᵢ`; Rosner found it accurate for `n ≥ 25`. For
small samples and several steps see the correction of [`esd_critical_values`](@ref).
"""
function rosner_lambda(n::Integer, i::Integer, level::Real)
    0 < level < 1 || throw(ArgumentError("level must be in (0, 1), got $level"))
    1 <= i <= n - 2 ||
        throw(ArgumentError("step i must satisfy 1 ≤ i ≤ n - 2, got i = $i for n = $n"))
    t = student_t_upper_quantile(level / (2 * (n - i + 1)), n - i - 1)
    return (n - i) * t / sqrt((n - i - 1 + t^2) * (n - i + 1))
end

# ----------------------------------------------------------------------------------
# The removal sequence
# ----------------------------------------------------------------------------------

"""
    esd_removal_sequence(z, r) -> (order, statistic)

Run the first `r` steps of the ESD procedure on `z`. `order[i]` is the index in `z` of the
value removed at step `i` and `statistic[i]` is `Rᵢ`. The values are sorted once, so that
the most extreme one of what is left is always at one of the two ends and each step costs
`O(1)`; the running sums are centered on the median to keep them accurate.
"""
function esd_removal_sequence(z::AbstractVector{Float64}, r::Integer)
    n = length(z)
    1 <= r <= n - 2 ||
        throw(ArgumentError("max_outliers must satisfy 1 ≤ r ≤ n - 2, got $r for n = $n"))
    perm = sortperm(z)
    lo, hi = 1, n
    shift = z[perm[(n+1)>>>1]]
    s1 = 0.0
    s2 = 0.0
    for v in z
        d = v - shift
        s1 += d
        s2 += d * d
    end
    order = Vector{Int}(undef, r)
    statistic = Vector{Float64}(undef, r)
    for i = 1:r
        count = n - i + 1
        mean_shifted = s1 / count
        variance = (s2 - s1 * mean_shifted) / (count - 1)
        sd = sqrt(max(variance, 0.0))
        center = shift + mean_shifted
        below = center - z[perm[lo]]
        above = z[perm[hi]] - center
        if below > above
            index, deviation = perm[lo], below
            lo += 1
        else
            index, deviation = perm[hi], above
            hi -= 1
        end
        statistic[i] = sd > 0 ? deviation / sd : (deviation > 0 ? Inf : 0.0)
        order[i] = index
        d = z[index] - shift
        s1 -= d
        s2 -= d * d
    end
    return order, statistic
end

# ----------------------------------------------------------------------------------
# Critical values
# ----------------------------------------------------------------------------------

const CRITICAL_METHODS = (:auto, :rosner)

"""
Strength of the small-sample correction of [`esd_critical_values`](@ref): the significance
level of the formula is divided by `1 + STEP_CORRECTION * (r - 1) / n`. It was chosen by
simulating the whole procedure (40 000 normal samples for each of 20 combinations of `n ≤ 1000`
and `r ≤ n / 4`, at levels 0.05, 0.005 and 0.0005): with it the probability of declaring an
outlier in a sample that has none stays between 0.5 and 1.25 times the nominal level, where
the plain formula reaches 2.1 times at `n = 8`, `r = 3`.
"""
const STEP_CORRECTION = 3.0

"""
    esd_critical_values(n, r, level; method = :auto)

Critical values `λ₁, …, λᵣ` of the generalized ESD test for `n` values and at most `r`
outliers, as a vector. They are computed in closed form, so they are exactly reproducible
and cost `O(r)` evaluations of Student's t quantile.

- `method = :rosner`: Rosner's formula, [`rosner_lambda`](@ref), at the given level.
- `method = :auto` (default): the same formula at the level `level / (1 + 3 (r - 1) / n)`.
  The formula treats the steps as if each were a test of its own at `level`, while the
  procedure declares an outlier when ANY step exceeds its value; the correction pays for
  that. It does nothing for `r = 1` (Grubbs' test is exact) and little for `r ≪ n`.
"""
function esd_critical_values(n::Integer, r::Integer, level::Real; method::Symbol = :auto)
    method in CRITICAL_METHODS ||
        throw(ArgumentError("method must be one of $(CRITICAL_METHODS), got :$method"))
    0 < level < 1 || throw(ArgumentError("level must be in (0, 1), got $level"))
    1 <= r <= n - 2 ||
        throw(ArgumentError("max_outliers must satisfy 1 ≤ r ≤ n - 2, got $r for n = $n"))
    effective =
        method === :rosner ? Float64(level) :
        Float64(level) / (1 + STEP_CORRECTION * (r - 1) / n)
    return Float64[rosner_lambda(n, i, effective) for i = 1:r]
end

# ----------------------------------------------------------------------------------
# The test
# ----------------------------------------------------------------------------------

"""
    ESDResult

Outcome of [`esd`](@ref).

- `n`: number of values tested.
- `max_outliers`: the `r` of the procedure.
- `level`: significance level used.
- `order`: indices (into the tested vector) of the `r` most extreme values, in the order
  the procedure removed them.
- `statistic`, `critical`: `Rᵢ` and `λᵢ` for `i = 1, …, r`.
- `count`: number of outliers declared; they are the first `count` entries of `order`.
"""
struct ESDResult
    n::Int
    max_outliers::Int
    level::Float64
    order::Vector{Int}
    statistic::Vector{Float64}
    critical::Vector{Float64}
    count::Int
end

"""
    declared(result::ESDResult) -> Vector{Int}

Indices of the outliers declared by [`esd`](@ref), most extreme first.
"""
declared(result::ESDResult) = result.order[1:result.count]

# `max_outliers` may be a count or a fraction of the sample.
function resolve_max_outliers(max_outliers, n::Int)
    r = if max_outliers isa Integer
        max_outliers >= 1 || throw(ArgumentError("max_outliers must be at least 1"))
        Int(max_outliers)
    elseif max_outliers isa Real
        0 < max_outliers < 1 || throw(
            ArgumentError("a fractional max_outliers must be in (0, 1), got $max_outliers"),
        )
        max(1, ceil(Int, max_outliers * n))
    else
        throw(ArgumentError("max_outliers must be an integer or a fraction"))
    end
    return max(1, min(r, n ÷ 2, n - 2))
end

"""
    esd(z; max_outliers = 0.1, level = 0.05, critical = :auto)

Rosner's generalized extreme studentized deviate test ([Rosner1983](@cite)) on the values
`z`, assumed to be approximately normal once the outliers are removed. It declares up to
`max_outliers` outliers (a count, or a fraction of `length(z)`) with a probability of about
`level` of declaring any when there are none. Returns an [`ESDResult`](@ref).

`critical` chooses the critical values, see [`esd_critical_values`](@ref). Samples of fewer
than three values cannot be tested and throw an `ArgumentError`; `NaN` must be removed by
the caller.
"""
function esd(
    z::AbstractVector{<:Real};
    max_outliers = 0.1,
    level::Real = 0.05,
    critical::Symbol = :auto,
)
    n = length(z)
    n >= 3 || throw(ArgumentError("the ESD test needs at least 3 values, got $n"))
    any(isnan, z) && throw(ArgumentError("z contains NaN"))
    r = resolve_max_outliers(max_outliers, n)
    order, statistic = esd_removal_sequence(Float64[v for v in z], r)
    lambda = esd_critical_values(n, r, level; method = critical)
    count = 0
    for i = r:-1:1
        if statistic[i] > lambda[i]
            count = i
            break
        end
    end
    return ESDResult(n, r, Float64(level), order, statistic, lambda, count)
end

# ----------------------------------------------------------------------------------
# Confidence in a flag
# ----------------------------------------------------------------------------------

"""
    flag_certainty(z) -> Vector{Float64}

Estimated probability that each value of the pool `z` is a true outlier, `1 - fdr`, where
`fdr` is the tail-area false discovery rate of [Efron2007](@cite): among the `k` values at
least as far from zero as `|zᵢ|`, about `n · 2Φ(-|zᵢ| / σ₀)` are expected from a pool without
outliers, so the fraction of false discoveries is that over `k` (at most 1). `σ₀` is the
scale of the bulk of the pool, estimated from its median absolute value and never taken below
1: a pool whose standardized residuals are wider than they should be (noisier than the model
assumes) gets a low confidence however large its extremes look. The estimate is empirical and
approximate; it is a measure of how well separated the flags are from the rest, not a
guarantee.
"""
function flag_certainty(z::AbstractVector{Float64})
    n = length(z)
    a = Float64[abs(v) for v in z]
    sigma = max(1.0, MAD_TO_SD * median!(copy(a)))
    order = sortperm(a; rev = true)
    out = Vector{Float64}(undef, n)
    for (rank, i) in enumerate(order)
        expected = 2n * normal_cdf(-a[i] / sigma)
        out[i] = 1 - min(1.0, expected / rank)
    end
    return out
end
