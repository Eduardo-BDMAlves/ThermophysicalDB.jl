# Stage 2 engine: the local quadratic surface of the joint analysis.
#
# The cost of this stage is what decides whether the whole detection is usable, so it is
# organised around four ideas.
#
#   TILES.    Points that sit close together share ONE surface fit. The coordinates of the
#             subgroup (scaled to the unit box) are binned in a grid; the points of a cell
#             form a tile of at most `tile` points, and the window of the tile is its own
#             points plus the nearest others. Every member gets its standardized deleted
#             residual from the shared fit, exactly as the points of a line window do in
#             stage 1.
#   SCREENING. Every tile is first fitted with a cheap robust procedure (least squares, a
#             MAD-based trim, then reweighting to a fixed point). Only the tiles in which a
#             point looks suspicious, and the tiles around a clearly deviating point (which
#             could hide a cluster of wrong points), are fitted again with the expensive
#             consensus step. A clean point costs about one microsecond.
#   LQS.      The consensus step is a least quantile of squares fit (Rousseeuw 1984) over
#             a fixed number of elemental subsets drawn with a small deterministic generator,
#             refined by concentration steps. It replaces the former RANSAC with a ladder of
#             thresholds, which repeated a randomised search about seven times per point.
#   NO ALLOCATION.  Every buffer lives in a per-thread workspace (`SurfaceWS`); the linear
#             algebra of the 6 × 6 or 10 × 10 systems is written out, so the loops over
#             windows allocate nothing.
#
# Nothing here is random: the elemental subsets come from a counter-based generator seeded
# with the user's `seed` and the number of the tile, so the result is the same on any number
# of threads and on any run.

# ----------------------------------------------------------------------------------
# Small deterministic generator (SplitMix64)
# ----------------------------------------------------------------------------------

@inline function splitmix(state::UInt64)
    state += 0x9e3779b97f4a7c15
    z = state
    z = (z ⊻ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return z ⊻ (z >> 31), state
end

# ----------------------------------------------------------------------------------
# Neighbour search on a grid
# ----------------------------------------------------------------------------------

"""
    SurfaceGrid

Uniform grid of `g` cells per axis over the unit box that holds the scaled coordinates of a
subgroup. `start` and `members` are in the layout of a counting sort: the points of cell
`c` are `members[start[c]:start[c+1]-1]`, in increasing order of their number.
"""
struct SurfaceGrid
    d::Int
    g::Int
    width::Float64
    start::Vector{Int32}
    members::Vector{Int32}
end

function SurfaceGrid(c::Matrix{Float64}, per_cell::Real)
    d, n = size(c)
    g = clamp(round(Int, (n / per_cell)^(1 / d)), 1, 4096)
    ncell = g^d
    cellof = Vector{Int32}(undef, n)
    start = zeros(Int32, ncell + 1)
    @inbounds for j = 1:n
        idx = 0
        stride = 1
        for a = 1:d
            idx += min(floor(Int, c[a, j] * g), g - 1) * stride
            stride *= g
        end
        cellof[j] = idx + 1
        start[idx+2] += 1
    end
    start[1] = 1
    @inbounds for k = 1:ncell
        start[k+1] += start[k]
    end
    fill_at = copy(start)
    members = Vector{Int32}(undef, n)
    @inbounds for j = 1:n
        k = cellof[j]
        members[fill_at[k]] = j
        fill_at[k] += 1
    end
    return SurfaceGrid(d, g, 1 / g, start, members)
end

"""
    Tiles

The partition of the points of a subgroup into tiles, by grid cell (a crowded cell is cut
into chunks of at most `tile` points). Tile `t` holds `grid.members[lo[t]:hi[t]]`.
`windows[1:size[t], t]` are the points of its window, its own members first and then the
nearest others by increasing distance; `tile_of` maps every point to its tile.
"""
struct Tiles
    lo::Vector{Int}
    hi::Vector{Int}
    windows::Matrix{Int32}
    size::Vector{Int}
    tile_of::Vector{Int32}
    wmax::Int
end

function Tiles(grid::SurfaceGrid, k::Int, tile::Int)
    lo = Int[]
    hi = Int[]
    n = length(grid.members)
    for cell = 1:(length(grid.start)-1)
        a = Int(grid.start[cell])
        count = Int(grid.start[cell+1]) - a
        count > 0 || continue
        chunks = cld(count, tile)
        for q = 0:(chunks-1)
            push!(lo, a + (q * count) ÷ chunks)
            push!(hi, a + ((q + 1) * count) ÷ chunks - 1)
        end
    end
    ntiles = length(lo)
    wmax = k + tile - 1
    tile_of = Vector{Int32}(undef, n)
    for t = 1:ntiles, a = lo[t]:hi[t]
        tile_of[grid.members[a]] = t
    end
    return Tiles(lo, hi, zeros(Int32, wmax, ntiles), zeros(Int, ntiles), tile_of, wmax)
end

# ----------------------------------------------------------------------------------
# Workspace
# ----------------------------------------------------------------------------------

"""
    SurfaceWS

Per-thread buffers of the surface fits. `p` is the number of coefficients of the quadratic
in `d` variables and `wmax` the largest window.
"""
mutable struct SurfaceWS
    d::Int
    p::Int
    wmax::Int
    W::Int                         # points in the current window
    pair_a::Vector{Int}            # factors of the second-order columns
    pair_b::Vector{Int}
    # neighbour search
    best_d::Vector{Float64}
    best_i::Vector{Int32}
    offsets::Vector{Int}
    cell::Vector{Int}
    centre::Vector{Float64}
    # window
    win::Vector{Int32}
    delta::Matrix{Float64}         # d × wmax: coordinates relative to the centre, over h
    X::Matrix{Float64}             # wmax × p
    y::Vector{Float64}
    u::Vector{Float64}
    wgt::Vector{Float64}           # 1 / u²
    scratch::Vector{Float64}
    h::Float64
    ymax::Float64
    known::Bool
    # fit
    mask::Vector{Bool}
    previous::Vector{Bool}
    keep::Vector{Bool}
    A::Matrix{Float64}
    ainv::Matrix{Float64}
    b::Vector{Float64}
    beta::Vector{Float64}
    diagonal::Vector{Float64}
    e::Vector{Float64}
    z::Vector{Float64}
    hat::Vector{Float64}
    phi::Float64
    nin::Int
    # consensus search
    perm::Vector{Int}
    G::Matrix{Float64}
    trial::Vector{Float64}
    best_beta::Vector{Float64}
    resid::Vector{Float64}
    select::Vector{Float64}
    gradient::Vector{Float64}
    rng::UInt64
end

function SurfaceWS(d::Int, wmax::Int)
    p = quadratic_size(d)
    terms = quadratic_terms(d)
    return SurfaceWS(
        d,
        p,
        wmax,
        0,
        Int[t[1] for t in terms],
        Int[t[2] for t in terms],
        Vector{Float64}(undef, wmax),
        Vector{Int32}(undef, wmax),
        zeros(Int, d),
        zeros(Int, d),
        zeros(d),
        Vector{Int32}(undef, wmax),
        zeros(d, wmax),
        zeros(wmax, p),
        zeros(wmax),
        zeros(wmax),
        zeros(wmax),
        zeros(wmax),
        1.0,
        1.0,
        false,
        fill(false, wmax),
        fill(false, wmax),
        fill(false, wmax),
        zeros(p, p),
        zeros(p, p),
        zeros(p),
        zeros(p),
        zeros(p),
        zeros(wmax),
        zeros(wmax),
        zeros(wmax),
        1.0,
        0,
        collect(1:wmax),
        zeros(p, p + 1),
        zeros(p),
        zeros(p),
        zeros(wmax),
        zeros(wmax),
        zeros(p),
        UInt64(0),
    )
end

# ----------------------------------------------------------------------------------
# Linear algebra of the small systems
# ----------------------------------------------------------------------------------

# In-place Cholesky factor `L` (the lower triangle of `A` is replaced) of a symmetric
# positive definite matrix given by its lower triangle; `false` if it is not positive definite.
function cholesky_lower!(A::Matrix{Float64}, p::Int)
    @inbounds for j = 1:p
        s = A[j, j]
        for k = 1:(j-1)
            s -= A[j, k] * A[j, k]
        end
        (s > 0 && isfinite(s)) || return false
        ljj = sqrt(s)
        A[j, j] = ljj
        for i = (j+1):p
            t = A[i, j]
            for k = 1:(j-1)
                t -= A[i, k] * A[j, k]
            end
            A[i, j] = t / ljj
        end
    end
    return true
end

# Solve `L Lᵀ x = b` in place in `b`.
function cholesky_solve!(L::Matrix{Float64}, b::AbstractVector{Float64}, p::Int)
    @inbounds for i = 1:p
        s = b[i]
        for k = 1:(i-1)
            s -= L[i, k] * b[k]
        end
        b[i] = s / L[i, i]
    end
    @inbounds for i = p:-1:1
        s = b[i]
        for k = (i+1):p
            s -= L[k, i] * b[k]
        end
        b[i] = s / L[i, i]
    end
    return b
end

# The inverse of `L Lᵀ`, column by column.
function cholesky_inverse!(ainv::Matrix{Float64}, L::Matrix{Float64}, p::Int)
    @inbounds for j = 1:p
        for i = 1:p
            ainv[i, j] = i == j ? 1.0 : 0.0
        end
        cholesky_solve!(L, view(ainv, :, j), p)
    end
    return ainv
end

# The k-th smallest of v[1:n] (1-based), by quickselect; reorders v.
function kth_smallest!(v::Vector{Float64}, n::Int, k::Int)
    lo, hi = 1, n
    @inbounds while lo < hi
        pivot = v[(lo+hi)>>>1]
        i, j = lo, hi
        while i <= j
            while v[i] < pivot
                i += 1
            end
            while v[j] > pivot
                j -= 1
            end
            if i <= j
                v[i], v[j] = v[j], v[i]
                i += 1
                j -= 1
            end
        end
        if k <= j
            hi = j
        elseif k >= i
            lo = i
        else
            break
        end
    end
    return @inbounds v[k]
end

# Insertion sort of v[1:n]; the windows have a few tens of values.
function sort_prefix!(v::Vector{Float64}, n::Int)
    @inbounds for i = 2:n
        x = v[i]
        j = i - 1
        while j >= 1 && v[j] > x
            v[j+1] = v[j]
            j -= 1
        end
        v[j+1] = x
    end
    return v
end

# ----------------------------------------------------------------------------------
# The window
# ----------------------------------------------------------------------------------

# Squared distances are compared as (distance, index) pairs, so that ties are broken the same
# way on every run and every thread count.
@inline closer(d1, i1, d2, i2) = d1 < d2 || (d1 == d2 && i1 < i2)

# Find the `want` points nearest to `ws.centre` that are not among the first `m` entries of
# `ws.win`, ring by ring of grid cells around the cell of the centre, and leave them sorted in
# `ws.best_i`. A ring is the set of cells at the same Chebyshev distance `r` from the central
# cell; once the `want` best candidates are all closer than `r` cell widths, no cell that is
# left can hold a closer point. Returns the number found.
function nearest_others!(
    ws::SurfaceWS,
    grid::SurfaceGrid,
    c::Matrix{Float64},
    m::Int,
    want::Int,
)
    d, g = grid.d, grid.g
    q, cc, off = ws.centre, ws.cell, ws.offsets
    bd, bi = ws.best_d, ws.best_i
    @inbounds for a = 1:d
        cc[a] = clamp(floor(Int, q[a] * g), 0, g - 1)
    end
    found = 0
    r = 0
    @inbounds while true
        fill!(off, -r)
        while true
            on_ring = r == 0
            inside = true
            idx = 0
            stride = 1
            for a = 1:d
                o = off[a]
                abs(o) == r && (on_ring = true)
                ca = cc[a] + o
                (ca < 0 || ca >= g) && (inside = false)
                idx += ca * stride
                stride *= g
            end
            if on_ring && inside
                cell = idx + 1
                for s = Int(grid.start[cell]):(Int(grid.start[cell+1])-1)
                    j = Int(grid.members[s])
                    member = false
                    for l = 1:m
                        if Int(ws.win[l]) == j
                            member = true
                            break
                        end
                    end
                    member && continue
                    dist = 0.0
                    for a = 1:d
                        t = c[a, j] - q[a]
                        dist += t * t
                    end
                    if found < want
                        found += 1
                        pos = found
                    elseif closer(dist, j, bd[want], bi[want])
                        pos = want
                    else
                        continue
                    end
                    while pos > 1 && closer(dist, j, bd[pos-1], bi[pos-1])
                        bd[pos] = bd[pos-1]
                        bi[pos] = bi[pos-1]
                        pos -= 1
                    end
                    bd[pos] = dist
                    bi[pos] = j
                end
            end
            a = 1
            while a <= d
                off[a] += 1
                off[a] <= r && break
                off[a] = -r
                a += 1
            end
            a > d && break
        end
        found == want && bd[want] <= (r * grid.width)^2 && break
        r >= g && break
        r += 1
    end
    return found
end

# Put the window of tile `t` into `ws`: its own points, then the nearest others, so that
# every member has at least `k - 1` other points in the window. `false` if the subgroup is
# too small.
function make_window!(
    ws::SurfaceWS,
    grid::SurfaceGrid,
    c::Matrix{Float64},
    tiles::Tiles,
    t::Int,
    k::Int,
)
    lo, hi = tiles.lo[t], tiles.hi[t]
    m = hi - lo + 1
    n = length(grid.members)
    total = min(k + m - 1, n)
    @inbounds for l = 1:m
        ws.win[l] = grid.members[lo+l-1]
    end
    set_centre!(ws, c, m)
    found = nearest_others!(ws, grid, c, m, total - m)
    found == total - m || return false
    @inbounds for l = 1:found
        ws.win[m+l] = ws.best_i[l]
        tiles.windows[m+l, t] = ws.best_i[l]
    end
    @inbounds for l = 1:m
        tiles.windows[l, t] = ws.win[l]
    end
    tiles.size[t] = total
    ws.W = total
    return true
end

# The window that a first pass stored, for the second pass.
function load_window!(ws::SurfaceWS, c::Matrix{Float64}, tiles::Tiles, t::Int)
    total = tiles.size[t]
    total > 0 || return false
    @inbounds for l = 1:total
        ws.win[l] = tiles.windows[l, t]
    end
    ws.W = total
    set_centre!(ws, c, tiles.hi[t] - tiles.lo[t] + 1)
    return true
end

function set_centre!(ws::SurfaceWS, c::Matrix{Float64}, m::Int)
    @inbounds for a = 1:ws.d
        s = 0.0
        for l = 1:m
            s += c[a, Int(ws.win[l])]
        end
        ws.centre[a] = s / m
    end
    return nothing
end

# Fill the data of the window: coordinates relative to the centre and divided by the radius
# `h` of the window (so that every column of the design is O(1)), the response, the
# uncertainty (with the missing ones replaced as in `fill_missing_uncertainty`) and the
# design. `false` when an axis has fewer than three distinct values in the window.
function load_data!(ws::SurfaceWS, task::JointTask)
    d, p, W = ws.d, ws.p, ws.W
    c = task.scaled
    h2 = 0.0
    @inbounds for l = 1:W
        j = Int(ws.win[l])
        dist = 0.0
        for a = 1:d
            t = c[a, j] - ws.centre[a]
            dist += t * t
        end
        h2 = max(h2, dist)
    end
    h = max(sqrt(h2), 1.0e-12)
    ws.h = h
    @inbounds for a = 1:d
        for l = 1:W
            ws.scratch[l] = c[a, Int(ws.win[l])]
        end
        sort_prefix!(ws.scratch, W)
        distinct = 1
        previous = ws.scratch[1]
        for l = 2:W
            if ws.scratch[l] - previous > 1.0e-6
                distinct += 1
                previous = ws.scratch[l]
            end
        end
        distinct >= 3 || return false
    end
    known = 0
    @inbounds for l = 1:W
        ul = task.u[Int(ws.win[l])]
        if isfinite(ul) && ul > 0
            known += 1
            ws.scratch[known] = ul
        end
    end
    fill_value = 1.0
    ws.known = known > 0
    if 0 < known < W
        sort_prefix!(ws.scratch, known)
        fill_value =
            isodd(known) ? ws.scratch[(known+1)>>1] :
            (ws.scratch[known>>1] + ws.scratch[(known>>1)+1]) / 2
    end
    ymax = 0.0
    @inbounds for l = 1:W
        j = Int(ws.win[l])
        ws.y[l] = task.y[j]
        ymax = max(ymax, abs(task.y[j]))
        ul = task.u[j]
        ul = ws.known ? (isfinite(ul) && ul > 0 ? ul : fill_value) : 1.0
        ws.u[l] = ul
        ws.wgt[l] = 1 / (ul * ul)
        for a = 1:d
            ws.delta[a, l] = (c[a, j] - ws.centre[a]) / h
        end
        ws.X[l, 1] = 1.0
        for a = 1:d
            ws.X[l, 1+a] = ws.delta[a, l]
        end
        for s = 1:length(ws.pair_a)
            ws.X[l, 1+d+s] = ws.delta[ws.pair_a[s], l] * ws.delta[ws.pair_b[s], l]
        end
    end
    ws.ymax = ymax
    return true
end

# ----------------------------------------------------------------------------------
# Weighted least squares on the mask, and the standardized deleted residuals
# ----------------------------------------------------------------------------------

# Normal equations of the points in `ws.mask`, their Cholesky factor (left in `ws.A`) and
# the coefficients. `false` if there are `p` points or fewer or the system is singular.
function wls!(ws::SurfaceWS)
    W, p = ws.W, ws.p
    A, b = ws.A, ws.b
    fill!(A, 0.0)
    fill!(b, 0.0)
    nin = 0
    @inbounds for i = 1:W
        ws.mask[i] || continue
        nin += 1
        w = ws.wgt[i]
        yi = ws.y[i]
        for c = 1:p
            wx = w * ws.X[i, c]
            b[c] += wx * yi
            for r = c:p
                A[r, c] += wx * ws.X[i, r]
            end
        end
    end
    ws.nin = nin
    nin > p || return false
    @inbounds for c = 1:p
        ws.diagonal[c] = A[c, c]
    end
    cholesky_lower!(A, p) || return false
    copyto!(ws.beta, b)
    cholesky_solve!(A, ws.beta, p)
    s = 0.0
    @inbounds for c = 1:p
        s += ws.beta[c]
    end
    return isfinite(s)
end

# Port of `refit_window` to the workspace: the fit on the mask, its scale `phi` and the
# standardized deleted residual `z` of every point of the window.
function refit!(ws::SurfaceWS, cutoff::Float64, tvar::Float64)
    wls!(ws) || return false
    W, p = ws.W, ws.p
    cholesky_inverse!(ws.ainv, ws.A, p)
    @inbounds for c = 2:p
        inflation = ws.diagonal[c] * ws.ainv[c, c]
        (isfinite(inflation) && inflation <= MAX_VARIANCE_INFLATION) || return false
    end
    rss = 0.0
    @inbounds for i = 1:W
        fitted = 0.0
        for c = 1:p
            fitted += ws.X[i, c] * ws.beta[c]
        end
        ei = ws.y[i] - fitted
        ws.e[i] = ei
        ws.mask[i] && (rss += (ei / ws.u[i])^2)
    end
    spread = sqrt(rss / (ws.nin - p) / tvar)
    phi = max(ws.known ? 1.0 : 0.0, spread)
    phi > 0 || (phi = 1.0e-12 * max(1.0, ws.ymax))
    ws.phi = phi
    @inbounds for i = 1:W
        quad = 0.0
        for r = 1:p
            inner = 0.0
            for c = 1:p
                inner += ws.ainv[r, c] * ws.X[i, c]
            end
            quad += ws.X[i, r] * inner
        end
        ui = ws.u[i]
        if ws.mask[i]
            hi = quad * ws.wgt[i]
            ws.hat[i] = hi
            ws.z[i] = 1 - hi > 1.0e-8 ? ws.e[i] / (phi * ui * sqrt(1 - hi)) : NaN
        else
            ws.hat[i] = NaN
            ws.z[i] = ws.e[i] / (phi * sqrt(ui * ui + quad))
        end
    end
    return true
end

# Port of `robust_refit`: refit until the set of points with |z| ≤ cutoff stops changing. On
# failure after a first success the last good fit is restored.
function robust_refit!(ws::SurfaceWS, cutoff::Float64, tvar::Float64)
    W, p = ws.W, ws.p
    have = false
    for _ = 1:MAX_REWEIGHTING_STEPS
        if !refit!(ws, cutoff, tvar)
            have || return false
            copyto!(ws.mask, 1, ws.previous, 1, W)
            return refit!(ws, cutoff, tvar)
        end
        have = true
        same = true
        kept = 0
        @inbounds for i = 1:W
            zi = ws.z[i]
            keep = isfinite(zi) ? abs(zi) <= cutoff : ws.mask[i]
            ws.keep[i] = keep
            keep && (kept += 1)
            keep == ws.mask[i] || (same = false)
        end
        (same || kept <= p) && break
        copyto!(ws.previous, 1, ws.mask, 1, W)
        copyto!(ws.mask, 1, ws.keep, 1, W)
    end
    return true
end

# ----------------------------------------------------------------------------------
# Cheap start (screening) and least-quantile-of-squares start (consensus)
# ----------------------------------------------------------------------------------

# Least squares on every point, then keep the points within `cutoff` robust standard
# deviations (MAD of the scaled residuals) of the fit.
function cheap_mask!(ws::SurfaceWS, cutoff::Float64)
    W, p = ws.W, ws.p
    @inbounds for i = 1:W
        ws.mask[i] = true
    end
    refit!(ws, Inf, 1.0) || return false
    @inbounds for i = 1:W
        ws.select[i] = abs(ws.e[i]) / ws.u[i]
    end
    sort_prefix!(ws.select, W)
    median = isodd(W) ? ws.select[(W+1)>>1] : (ws.select[W>>1] + ws.select[(W>>1)+1]) / 2
    scale = max(ws.known ? 1.0 : 0.0, SCALE_CONSISTENCY * median)
    scale > 0 || return true
    limit = cutoff * scale
    kept = 0
    @inbounds for i = 1:W
        inside = abs(ws.e[i]) / ws.u[i] <= limit
        ws.mask[i] = inside
        inside && (kept += 1)
    end
    if kept <= p
        @inbounds for i = 1:W
            ws.mask[i] = true
        end
    end
    return true
end

# Scaled absolute residuals of the model `beta` into `ws.resid`, and their q-th smallest.
function scaled_quantile!(ws::SurfaceWS, beta::Vector{Float64}, q::Int)
    W, p = ws.W, ws.p
    @inbounds for i = 1:W
        fitted = 0.0
        for c = 1:p
            fitted += ws.X[i, c] * beta[c]
        end
        r = abs(ws.y[i] - fitted) / ws.u[i]
        ws.resid[i] = r
        ws.select[i] = r
    end
    return kth_smallest!(ws.select, W, q)
end

# Exact fit through the p points `ws.perm[1:p]` into `ws.trial`.
function elemental!(ws::SurfaceWS)
    p = ws.p
    G = ws.G
    @inbounds for s = 1:p
        i = ws.perm[s]
        for c = 1:p
            G[s, c] = ws.X[i, c]
        end
        G[s, p+1] = ws.y[i]
    end
    @inbounds for col = 1:p
        piv = col
        best = abs(G[col, col])
        for r = (col+1):p
            v = abs(G[r, col])
            if v > best
                best = v
                piv = r
            end
        end
        best > 1.0e-12 || return false
        if piv != col
            for c = col:(p+1)
                G[col, c], G[piv, c] = G[piv, c], G[col, c]
            end
        end
        for r = (col+1):p
            f = G[r, col] / G[col, col]
            f == 0 && continue
            for c = col:(p+1)
                G[r, c] -= f * G[col, c]
            end
        end
    end
    s = 0.0
    @inbounds for i = p:-1:1
        acc = G[i, p+1]
        for c = (i+1):p
            acc -= G[i, c] * ws.trial[c]
        end
        ws.trial[i] = acc / G[i, i]
        s += ws.trial[i]
    end
    return isfinite(s)
end

"Elemental subsets tried per coefficient of the surface by [`lqs_consensus!`](@ref)."
const LQS_TRIALS_PER_COEFFICIENT = 20

"Most concentration steps applied to the best elemental fit."
const CONCENTRATION_STEPS = 10

"""
    lqs_consensus!(ws, q, cutoff)

Least quantile of squares on the window ([Rousseeuw1984](@cite)): among the surfaces through
`p` points of the window, the one for which the `q`-th smallest scaled residual
`|yᵢ - ŷᵢ| / uᵢ` is smallest, so that at least `q` points lie within that distance of it. The
subsets are drawn with the generator of `ws.rng` (deterministic), and the winner is refined
by concentration steps: refit by weighted least squares on the `q` points closest to the
current surface, which never makes the fit of those points worse. The mask is left in
`ws.mask`: the points within `cutoff` times the scale of the winner (the scale is the larger
of the quantile over `cutoff` and the declared uncertainty, as in [`lqs_parabola`](@ref)).
"""
function lqs_consensus!(ws::SurfaceWS, q::Int, cutoff::Float64)
    W, p = ws.W, ws.p
    @inbounds for i = 1:W
        ws.perm[i] = i
    end
    best = Inf
    for _ = 1:(LQS_TRIALS_PER_COEFFICIENT*p)
        @inbounds for s = 1:p
            out, ws.rng = splitmix(ws.rng)
            j = s + Int(out % UInt64(W - s + 1))
            ws.perm[s], ws.perm[j] = ws.perm[j], ws.perm[s]
        end
        elemental!(ws) || continue
        value = scaled_quantile!(ws, ws.trial, q)
        if value < best
            best = value
            copyto!(ws.best_beta, ws.trial)
        end
    end
    isfinite(best) || return false
    copyto!(ws.trial, ws.best_beta)
    for _ = 1:CONCENTRATION_STEPS
        value = scaled_quantile!(ws, ws.trial, q)
        @inbounds for i = 1:W
            ws.mask[i] = ws.resid[i] <= value
        end
        wls!(ws) || break
        improved = scaled_quantile!(ws, ws.beta, q)
        improved < best || break
        best = improved
        copyto!(ws.best_beta, ws.beta)
        copyto!(ws.trial, ws.beta)
    end
    scale = max(ws.known ? 1.0 : 0.0, best / cutoff)
    scale > 0 || (scale = 1.0e-12 * max(1.0, ws.ymax))
    limit = cutoff * scale * (1 + 1.0e-12)
    scaled_quantile!(ws, ws.best_beta, q)
    kept = 0
    @inbounds for i = 1:W
        inside = ws.resid[i] <= limit
        ws.mask[i] = inside
        inside && (kept += 1)
    end
    return kept > p
end

# ----------------------------------------------------------------------------------
# One tile
# ----------------------------------------------------------------------------------

# Write the results of the members of the tile (the first `m` points of the window) from the
# fit in the workspace. Returns the largest |z| among them (0 when none is defined).
function store_members!(task::JointTask, ws::SurfaceWS, m::Int)
    d, p, W = ws.d, ws.p, ws.W
    scale, h = task.scale, ws.h
    nconsensus = 0
    @inbounds for i = 1:W
        ws.mask[i] && (nconsensus += 1)
    end
    first_ref = task.ref[Int(ws.win[1])]
    multi = false
    @inbounds for l = 2:W
        task.ref[Int(ws.win[l])] != first_ref && (multi = true)
    end
    peak = 0.0
    g = ws.gradient
    @inbounds for l = 1:m
        j = Int(ws.win[l])
        zl = ws.z[l]
        task.z[j] = zl
        isfinite(zl) && (peak = max(peak, abs(zl)))
        task.window[j] = W
        task.consensus[j] = nconsensus
        task.phi[j] = ws.phi
        task.multi_source[j] = multi
        fitted = ws.beta[1]
        for a = 1:d
            fitted += ws.beta[1+a] * ws.delta[a, l]
        end
        for s = 1:length(ws.pair_a)
            fitted += ws.beta[1+d+s] * ws.delta[ws.pair_a[s], l] * ws.delta[ws.pair_b[s], l]
        end
        task.yhat[j] = fitted
        for a = 1:d
            fill!(g, 0.0)
            g[1+a] = 1.0
            for s = 1:length(ws.pair_a)
                ia, ib = ws.pair_a[s], ws.pair_b[s]
                ia == a && (g[1+d+s] += ws.delta[ib, l])
                ib == a && (g[1+d+s] += ws.delta[ia, l])
            end
            slope = 0.0
            quad = 0.0
            for r = 1:p
                slope += g[r] * ws.beta[r]
                inner = 0.0
                for c = 1:p
                    inner += ws.ainv[r, c] * g[c]
                end
                quad += g[r] * inner
            end
            unit = scale[a] * h
            task.slope[a, j] = slope / unit
            task.slope_sd[a, j] = ws.phi * sqrt(max(quad, 0.0)) / unit
            col = 0
            for s = 1:length(ws.pair_a)
                if ws.pair_a[s] == a && ws.pair_b[s] == a
                    col = 1 + d + s
                end
            end
            task.curvature[a, j] = 2ws.beta[col] / unit^2
            task.curvature_sd[a, j] = 2ws.phi * sqrt(max(ws.ainv[col, col], 0.0)) / unit^2
        end
        if d >= 2
            col = 0
            for s = 1:length(ws.pair_a)
                if ws.pair_a[s] == 1 && ws.pair_b[s] == 2
                    col = 1 + d + s
                end
            end
            unit = scale[1] * scale[2] * h^2
            task.cross[j] = ws.beta[col] / unit
            task.cross_sd[j] = ws.phi * sqrt(max(ws.ainv[col, col], 0.0)) / unit
        end
    end
    return peak
end

# Fit tile `t`. The first pass builds the window and uses the cheap start; the second pass
# (`robust`) reuses the window and starts from the least quantile of squares. Returns the
# largest |z| of the members, or -1 when the tile could not be fitted.
function fit_tile!(
    task::JointTask,
    grid::SurfaceGrid,
    tiles::Tiles,
    ws::SurfaceWS,
    t::Int,
    set::Settings,
    k::Int,
    tvar::Float64,
    robust::Bool,
)
    c = task.scaled
    m = tiles.hi[t] - tiles.lo[t] + 1
    if robust
        load_window!(ws, c, tiles, t) || return -1.0
    else
        make_window!(ws, grid, c, tiles, t, k) || return -1.0
    end
    load_data!(ws, task) || return -1.0
    if robust
        ws.rng = splitmix(UInt64(set.seed) * 0x2545f4914f6cdd1d + UInt64(t))[2]
        q = clamp(ceil(Int, set.fraction * ws.W), ws.p + 1, ws.W)
        lqs_consensus!(ws, q, set.cutoff) || return -1.0
    else
        cheap_mask!(ws, set.cutoff) || return -1.0
    end
    robust_refit!(ws, set.cutoff, tvar) || return -1.0
    return store_members!(task, ws, m)
end

# ----------------------------------------------------------------------------------
# The whole subgroup
# ----------------------------------------------------------------------------------

function for_each_tile(work!, count::Int, make_state, threaded::Bool)
    if threaded
        dynamic_foreach(work!, count; init = make_state)
    else
        state = make_state()
        for i = 1:count
            work!(state, i)
        end
    end
    return nothing
end

"""
    process_joint!(task, set; threaded = true)

Fit the local quadratic surface of every point of the subgroup and fill the result arrays of
`task`; the module header of `surface.jl` explains the strategy. In short: the points are
grouped in tiles that share a window of `neighbors` points; all tiles get a cheap robust
fit; the tiles with a point beyond `screening * inlier_threshold` (and the tiles around a
point beyond `inlier_threshold`) are fitted again with the least-quantile-of-squares
consensus. Distances are measured in the coordinates scaled to the unit range of the
subgroup, so that a kelvin and a mole fraction weigh as much as their spans say.

The result does not depend on the number of threads: every tile writes only the entries of
its own points, and the random numbers of a tile depend on its number only.
"""
function process_joint!(task::JointTask, set::Settings; threaded::Bool = true)
    d, n = size(task.xi)
    p = quadratic_size(d)
    k = set.neighbors === nothing ? 4p : set.neighbors
    k >= p + 2 || throw(
        ArgumentError("neighbors must be at least $(p + 2) for $d varying axes, got $k"),
    )
    if n < k || n > set.max_joint_points
        task.skipped[] = true
        return nothing
    end
    grid = SurfaceGrid(task.scaled, set.tile)
    tiles = Tiles(grid, k, set.tile)
    ntiles = length(tiles.lo)
    tvar = truncated_variance(set.cutoff)
    make_state() = SurfaceWS(d, tiles.wmax)
    peak = fill(-1.0, ntiles)
    for_each_tile(ntiles, make_state, threaded) do ws, t
        peak[t] = fit_tile!(task, grid, tiles, ws, t, set, k, tvar, false)
    end
    todo = promoted_tiles(tiles, peak, k, set)
    for_each_tile(length(todo), make_state, threaded) do ws, a
        fit_tile!(task, grid, tiles, ws, todo[a], set, k, tvar, true)
    end
    return nothing
end

# Tiles that need the consensus fit: the ones with a point beyond the screening threshold,
# and, around every point beyond the inlier threshold, the tiles of its closest neighbours
# (a cluster of wrong points can hide from a cheap fit).
function promoted_tiles(tiles::Tiles, peak::Vector{Float64}, k::Int, set::Settings)
    ntiles = length(peak)
    screen = set.screening * set.cutoff
    promote = fill(false, ntiles)
    for t = 1:ntiles
        peak[t] >= screen && (promote[t] = true)
    end
    reach = (k + 1) ÷ 2
    for t = 1:ntiles
        peak[t] > set.cutoff || continue
        m = tiles.hi[t] - tiles.lo[t] + 1
        for l = (m+1):min(tiles.size[t], m+reach)
            promote[tiles.tile_of[tiles.windows[l, t]]] = true
        end
    end
    return findall(promote)
end
