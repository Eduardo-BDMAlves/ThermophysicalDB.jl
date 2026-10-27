# Local robust regression used by the trend stages.
#
# A window of neighbouring points is fitted with a low-order polynomial in three steps:
#
#   1. a CONSENSUS step finds which points of the window follow one smooth curve, without
#      being pulled by the ones that do not (least quantile of squares: exhaustive in one
#      dimension, over elemental subsets with concentration steps in several, see
#      `surface.jl`);
#   2. the model is REFITTED by weighted least squares on that consensus set, with weights
#      1/uᵢ² (the declared standard uncertainty), which is the statistically efficient fit
#      once the outliers are out;
#   3. every point of the window, in or out of the consensus, gets a STANDARDIZED DELETED
#      RESIDUAL: its distance to the curve fitted without it, in units of the scatter that
#      the fit itself expects there.
#
# The scale factor φ of the third step joins what the sources declare (uᵢ) with what the
# data show: it is 1 when the scatter agrees with the declared uncertainties, larger when
# the data are noisier than declared, and it is never smaller than 1 when the uncertainties
# are known (an optimistic uncertainty does not make a point an outlier).

"Consistency of the median absolute residual with the standard deviation of a normal sample."
const SCALE_CONSISTENCY = MAD_TO_SD

"""
Largest variance inflation factor (VIF) that a fit may have. The VIF of a coefficient is the
factor by which the collinearity of the design inflates its variance
([Belsley2005](@cite)); it is `Aⱼⱼ (A⁻¹)ⱼⱼ` for the normal matrix `A`. A window whose points
lie almost on a line or a curve in the space of the coordinates has an enormous VIF, and its
fitted surface is then determined by rounding errors; such windows are discarded.
"""
const MAX_VARIANCE_INFLATION = 1.0e6

"Most reweighting steps of [`robust_refit`](@ref)."
const MAX_REWEIGHTING_STEPS = 12

"""
    WindowFit

Weighted least-squares fit of one window on its consensus set. The scale `phi` is the root
mean square of the weighted residuals of the consensus, divided by the consistency factor of
a normal distribution truncated at `cutoff` (see [`truncated_variance`](@ref)).

- `beta`: coefficients of the local polynomial.
- `ainv`: `(XᵀWX)⁻¹`, so that the covariance of `beta` is `phi^2 * ainv`.
- `phi`: scale factor (see the file header).
- `z`: standardized deleted residual of every point of the window (`NaN` where the
  leverage makes it undefined).
- `e`: raw residual `y - Xβ` of every point.
- `h`: leverage of every point (`NaN` for the ones outside the consensus).
- `inliers`: the consensus mask.
"""
struct WindowFit
    beta::Vector{Float64}
    ainv::Matrix{Float64}
    phi::Float64
    z::Vector{Float64}
    e::Vector{Float64}
    h::Vector{Float64}
    inliers::BitVector
end

"""
    fill_missing_uncertainty(u) -> (u′, known)

Replace the `NaN` entries of `u` by the median of the known ones. When none is known all
become 1 and `known` is `false`: the residuals are then measured in the units of the
response and the scale `φ` carries the whole scatter.
"""
function fill_missing_uncertainty(u::AbstractVector{Float64})
    known = Float64[v for v in u if isfinite(v) && v > 0]
    isempty(known) && return (ones(length(u)), false)
    length(known) == length(u) && return (Vector{Float64}(u), true)
    fill = median!(known)
    return (Float64[isfinite(v) && v > 0 ? v : fill for v in u], true)
end

"""
    truncated_variance(c) -> Float64

Variance of a standard normal variable conditioned on `|Z| ≤ c`:
`1 - 2c φ(c) / (2Φ(c) - 1)`. A scale estimated from residuals that were kept because they lie
within `c` of the fit is too small by the square root of this factor, and dividing by it makes
the estimate consistent again ([Rousseeuw2003](@cite)). `c = Inf` gives 1.
"""
function truncated_variance(c::Real)
    isinf(c) && return 1.0
    density = exp(-c^2 / 2) / sqrt(2π)
    return 1 - 2c * density / (2normal_cdf(c) - 1)
end

"""
    refit_window(X, y, u, inliers, known; cutoff = Inf) -> Union{WindowFit,Nothing}

Weighted least squares of the `m × p` design `X` on the points flagged in `inliers`, and the
standardized deleted residual of all `m` points. `nothing` when the consensus set has
`p` points or fewer, the normal equations are singular or the design is so collinear that
the variance inflation exceeds [`MAX_VARIANCE_INFLATION`](@ref).
"""
function refit_window(
    X::AbstractMatrix{Float64},
    y::AbstractVector{Float64},
    u::AbstractVector{Float64},
    inliers::BitVector,
    known::Bool;
    cutoff::Float64 = Inf,
)
    m, p = size(X)
    nin = count(inliers)
    nin > p || return nothing
    A = zeros(p, p)
    b = zeros(p)
    for i = 1:m
        inliers[i] || continue
        w = 1 / u[i]^2
        for c = 1:p
            xc = X[i, c]
            b[c] += w * xc * y[i]
            for r = c:p
                A[r, c] += w * xc * X[i, r]
            end
        end
    end
    for c = 1:p, r = 1:(c-1)
        A[r, c] = A[c, r]
    end
    diagonal = Float64[A[c, c] for c = 1:p]
    F = cholesky!(Symmetric(A, :L); check = false)
    issuccess(F) || return nothing
    beta = F \ b
    ainv = Matrix{Float64}(F \ Matrix{Float64}(I, p, p))
    for c = 2:p
        inflation = diagonal[c] * ainv[c, c]
        (isfinite(inflation) && inflation <= MAX_VARIANCE_INFLATION) || return nothing
    end
    e = Vector{Float64}(undef, m)
    for i = 1:m
        fitted = 0.0
        for c = 1:p
            fitted += X[i, c] * beta[c]
        end
        e[i] = y[i] - fitted
    end
    rss = 0.0
    for i = 1:m
        inliers[i] && (rss += (e[i] / u[i])^2)
    end
    spread = sqrt(rss / (nin - p) / truncated_variance(cutoff))
    floor = known ? 1.0 : 0.0
    phi = max(floor, spread)
    if !(phi > 0)
        # An exact fit with no declared uncertainty: keep a scale at the level of the
        # rounding error, so that only a real departure produces a large residual.
        phi = 1.0e-12 * max(1.0, maximum(abs, y))
    end
    z = Vector{Float64}(undef, m)
    h = fill(NaN, m)
    for i = 1:m
        quad = 0.0
        for r = 1:p, c = 1:p
            quad += X[i, r] * ainv[r, c] * X[i, c]
        end
        if inliers[i]
            hi = quad / u[i]^2
            h[i] = hi
            z[i] = 1 - hi > 1.0e-8 ? e[i] / (phi * u[i] * sqrt(1 - hi)) : NaN
        else
            z[i] = e[i] / (phi * sqrt(u[i]^2 + quad))
        end
    end
    return WindowFit(beta, ainv, phi, z, e, h, inliers)
end


# ----------------------------------------------------------------------------------
# One dimension: exhaustive least quantile of squares for a parabola
# ----------------------------------------------------------------------------------

"""
    lqs_parabola(t, y, u, q) -> Union{Tuple{Vector{Bool},Float64},Nothing}

Consensus of a window with a parabola `y ≈ c₀ + c₁ t + c₂ t²`, by least quantile of
squares (Rousseeuw 1984): among the parabolas through three points of the window, the one
for which the `q`-th smallest weighted residual `|yᵢ - ŷᵢ| / uᵢ` is smallest, so that at
least `q` points lie within that distance of it.

The three-point parabolas are enumerated exhaustively, not drawn at random: the result is
deterministic and, unlike a count-based RANSAC with a fixed tolerance, does not need to know
the scatter in advance. A window has at most a few tens of points, so `C(m, 3)` is small.
Returns the points within `cutoff * max(floor, sₚ / cutoff)` of the winner, as a mask, and
that scale; `nothing` when no three points have distinct `t`.
"""
function lqs_parabola(
    t::AbstractVector{Float64},
    y::AbstractVector{Float64},
    u::AbstractVector{Float64},
    q::Integer,
    cutoff::Float64,
    floor::Float64,
)
    m = length(t)
    buffer = Vector{Float64}(undef, m)
    best_quantile = Inf
    best = (0.0, 0.0, 0.0)
    for i = 1:(m-2), j = (i+1):(m-1)
        dtij = t[j] - t[i]
        abs(dtij) > 1.0e-12 || continue
        slope_ij = (y[j] - y[i]) / dtij
        for k = (j+1):m
            dtjk = t[k] - t[j]
            dtik = t[k] - t[i]
            (abs(dtjk) > 1.0e-12 && abs(dtik) > 1.0e-12) || continue
            c2 = ((y[k] - y[i]) / dtik - slope_ij) / dtjk
            c1 = slope_ij - c2 * (t[i] + t[j])
            c0 = y[i] - c1 * t[i] - c2 * t[i]^2
            for l = 1:m
                buffer[l] = abs(y[l] - (c0 + t[l] * (c1 + t[l] * c2))) / u[l]
            end
            quantile = partialsort!(buffer, q)
            if quantile < best_quantile
                best_quantile = quantile
                best = (c0, c1, c2)
            end
        end
    end
    isfinite(best_quantile) || return nothing
    scale = max(floor, best_quantile / cutoff)
    scale > 0 || (scale = 1.0e-12 * max(1.0, maximum(abs, y)))
    limit = cutoff * scale
    c0, c1, c2 = best
    mask = BitVector(undef, m)
    for l = 1:m
        mask[l] = abs(y[l] - (c0 + t[l] * (c1 + t[l] * c2))) / u[l] <= limit * (1 + 1.0e-12)
    end
    return mask, scale
end

# ----------------------------------------------------------------------------------
# Several dimensions
# ----------------------------------------------------------------------------------

"""
    quadratic_terms(d) -> Vector{Tuple{Int,Int}}

Pairs `(i, j)`, `i ≤ j`, of the products `xᵢxⱼ` of a full quadratic in `d` variables, in
the order of their columns after the constant and the `d` linear terms.
"""
quadratic_terms(d::Integer) = Tuple{Int,Int}[(i, j) for i = 1:d for j = i:d]

"Number of coefficients of a full quadratic in `d` variables, `(d + 1)(d + 2) / 2`."
quadratic_size(d::Integer) = (d + 1) * (d + 2) ÷ 2

"""
    quadratic_row!(row, x, terms)

Fill `row` with `[1, x₁, …, x_d, xᵢxⱼ …]` for the point `x`.
"""
function quadratic_row!(row::AbstractVector{Float64}, x, terms)
    d = length(x)
    row[1] = 1.0
    for i = 1:d
        row[1+i] = x[i]
    end
    for (c, (i, j)) in enumerate(terms)
        row[1+d+c] = x[i] * x[j]
    end
    return row
end

# ----------------------------------------------------------------------------------
# Reweighting
# ----------------------------------------------------------------------------------

"""
    robust_refit(X, y, u, consensus, known, cutoff) -> Union{WindowFit,Nothing}

[`refit_window`](@ref) iterated until the inlier set stops changing. The consensus step
keeps the best `q` points, which is a truncated sample, so the scale estimated from it is too
small and `z` would be inflated for every point of an honest data set. After each fit the
inliers are recomputed as the points with `|z| ≤ cutoff` under the scale of that fit, which
is corrected for the truncation at `cutoff` (see [`truncated_variance`](@ref)); the process
settles at a scale that agrees with the data ([Rousseeuw2003](@cite)). At most
$(MAX_REWEIGHTING_STEPS) steps are taken.
"""
function robust_refit(
    X::AbstractMatrix{Float64},
    y::AbstractVector{Float64},
    u::AbstractVector{Float64},
    consensus::BitVector,
    known::Bool,
    cutoff::Float64,
)
    p = size(X, 2)
    mask = consensus
    fit = nothing
    for _ = 1:MAX_REWEIGHTING_STEPS
        attempt = refit_window(X, y, u, mask, known; cutoff)
        attempt === nothing && return fit
        fit = attempt
        keep = BitVector(undef, length(y))
        for i in eachindex(keep)
            z = fit.z[i]
            keep[i] = isfinite(z) ? abs(z) <= cutoff : mask[i]
        end
        (keep == mask || count(keep) <= p) && break
        mask = keep
    end
    return fit
end
