# Small descriptive statistics used by the outlier detection. They are written out here
# instead of being taken from Statistics.jl: the detection needs only a handful of them,
# and each one is checked against the worked example of the manual (eight densities, one
# of them suspicious).

"""
Factor that turns the median absolute deviation of a normal sample into an estimate of its
standard deviation: `1 / Φ⁻¹(3/4)`.
"""
const MAD_TO_SD = 1.482602218505602

"`Φ⁻¹(3/4)`, the inverse of [`MAD_TO_SD`](@ref). It scales a MAD in the modified z-score."
const SD_TO_MAD = 0.6744897501960817

"Factor that turns the mean absolute deviation of a normal sample into its standard deviation: `√(π/2)`."
const MEANAD_TO_SD = 1.2533141373155003

"""
    median!(v) -> Float64

Median of `v`, which is reordered in the process. `NaN` for an empty vector.
"""
function median!(v::AbstractVector{Float64})
    n = length(v)
    n == 0 && return NaN
    h = n >>> 1
    if isodd(n)
        return partialsort!(v, h + 1)
    end
    pair = partialsort!(v, h:(h+1))
    return (pair[1] + pair[2]) / 2
end

"""
    median_value(x) -> Float64

Median of `x` without touching it.
"""
median_value(x::AbstractVector{<:Real}) = median!(Float64[v for v in x])

"""
    mean_and_sd(x) -> (mean, sd)

Mean and sample standard deviation (denominator `n - 1`) of `x`, in two passes. The
standard deviation of fewer than two values is `NaN`.
"""
function mean_and_sd(x::AbstractVector{<:Real})
    n = length(x)
    n == 0 && return (NaN, NaN)
    m = sum(x) / n
    n == 1 && return (Float64(m), NaN)
    s = 0.0
    for v in x
        s += (v - m)^2
    end
    return (Float64(m), sqrt(s / (n - 1)))
end

"""
    median_abs_deviation(x) -> Float64

Median absolute deviation of `x` about its median, `median(|xᵢ - median(x)|)`, without any
consistency constant. See [`MAD_TO_SD`](@ref).
"""
function median_abs_deviation(x::AbstractVector{<:Real})
    center = median_value(x)
    return median!(Float64[abs(v - center) for v in x])
end

"""
    modified_zscores(x) -> Vector{Float64}

Modified z-scores of Iglewicz and Hoaglin, `0.6745 (xᵢ - median) / MAD`. A value is
usually called suspect when `|Mᵢ| > 3.5`. When the MAD is zero (more than half of the
values are identical) the mean absolute deviation is used instead, with the factor
`1.253314`, as those authors suggest; when that is zero too every score is zero.
"""
function modified_zscores(x::AbstractVector{<:Real})
    center = median_value(x)
    mad = median_abs_deviation(x)
    if mad > 0
        return [SD_TO_MAD * (v - center) / mad for v in x]
    end
    meanad = isempty(x) ? 0.0 : sum(abs(v - center) for v in x) / length(x)
    meanad > 0 || return zeros(Float64, length(x))
    return [(v - center) / (MEANAD_TO_SD * meanad) for v in x]
end
