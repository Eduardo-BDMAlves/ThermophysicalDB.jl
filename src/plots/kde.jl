# Distributions for the violin and box figures, without dependencies: quartiles and a Gaussian
# kernel density estimate that the extensions of both backends draw as polygons.

"""
    quartiles(values) -> NTuple{5,Float64}

The minimum, the three quartiles and the maximum of the finite `values` (linear interpolation
between the order statistics, the usual definition); `NaN`s where there are none.
"""
function quartiles(values::AbstractVector{<:Real})
    v = Float64[x for x in values if isfinite(x)]
    isempty(v) && return ntuple(_ -> NaN, 5)
    sort!(v)
    return (
        v[1],
        sorted_quantile(v, 0.25),
        sorted_quantile(v, 0.5),
        sorted_quantile(v, 0.75),
        v[end],
    )
end

# The `q`-quantile of a sorted vector.
function sorted_quantile(v::AbstractVector{Float64}, q::Float64)
    n = length(v)
    n == 1 && return v[1]
    h = 1 + (n - 1) * q
    lo = floor(Int, h)
    hi = min(lo + 1, n)
    return v[lo] + (h - lo) * (v[hi] - v[lo])
end

"""
    silverman_bandwidth(values) -> Float64

Silverman's rule of thumb for a Gaussian kernel: `0.9 min(s, iqr / 1.34) n^(-1/5)`, with `s` the
standard deviation. When the values are all equal the bandwidth is 1 (there is no spread to
smooth).
"""
function silverman_bandwidth(values::AbstractVector{<:Real})
    v = Float64[x for x in values if isfinite(x)]
    n = length(v)
    n < 2 && return 1.0
    m = sum(v) / n
    s = sqrt(sum(abs2, v .- m) / (n - 1))
    _, q1, _, q3, _ = quartiles(v)
    spread = min(s, (q3 - q1) / 1.34)
    spread > 0 || (spread = s)
    spread > 0 || return 1.0
    return 0.9 * spread * n^(-0.2)
end

"""
    density_profile(values; points = 64, bandwidth = nothing, cut = 2.0)
        -> NamedTuple{(:y, :density)}

The Gaussian kernel density of `values` on a grid of `points` between `cut` bandwidths below the
smallest value and above the largest, with the bandwidth of [`silverman_bandwidth`](@ref) unless
one is given. `density` is scaled so that its maximum is 1, which is what a violin needs (its
widths are then comparable between groups; a violin with the same area for every group is
obtained by scaling with `length(values)` as well). A single value gives a profile of one
point.
"""
function density_profile(
    values::AbstractVector{<:Real};
    points::Integer = 64,
    bandwidth::Union{Nothing,Real} = nothing,
    cut::Real = 2.0,
)
    v = Float64[x for x in values if isfinite(x)]
    isempty(v) && return (y = Float64[], density = Float64[])
    length(v) == 1 && return (y = [v[1]], density = [1.0])
    h = bandwidth === nothing ? silverman_bandwidth(v) : Float64(bandwidth)
    h > 0 || throw(ArgumentError("bandwidth must be positive, got $bandwidth"))
    lo, hi = minimum(v) - cut * h, maximum(v) + cut * h
    y = collect(range(lo, hi; length = points))
    density = zeros(points)
    inv2h2 = 1 / (2 * h * h)
    @inbounds for (k, yk) in enumerate(y)
        acc = 0.0
        for x in v
            acc += exp(-(yk - x)^2 * inv2h2)
        end
        density[k] = acc
    end
    top = maximum(density)
    density ./= top
    return (y = y, density = density)
end
