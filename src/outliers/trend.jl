# Stages 1 and 2: where a point sits relative to the trend of its neighbours.
#
# Stage 1 follows ONE coordinate at a time along a line of constant state (an isotherm, an
# isobar, a fixed composition) and fits local parabolas to windows of consecutive points.
# Stage 2 looks at ALL varying coordinates together, fitting a local quadratic surface
# (with the cross terms) to the nearest neighbours in the space of the coordinates.
# Both end in the same quantity, the standardized deleted residual `z` of each point, which
# the detection then pools and tests with the ESD procedure.

"""
    Settings

Resolved numeric settings of one run of [`find_outliers`](@ref). Build it with keywords:
every field has a default, see [`find_outliers`](@ref) for what they mean. Besides those,
`min_pool` is the smallest pool of `z` values that is tested with ESD, `offset_fraction` and
`offset_points` define a systematic offset of one source, `screening` is the fraction of
`cutoff` above which the cheap surface fit of a tile is repeated with the robust one (`0`
repeats every tile) and `tile` the largest number of neighbouring points that share one
surface fit (`1` fits every point on its own).
"""
struct Settings
    window::Int
    min_points::Int
    neighbors::Union{Nothing,Int}
    fraction::Float64
    cutoff::Float64
    level::Float64
    max_outliers::Union{Int,Float64}
    critical::Symbol
    seed::Int
    tolerance::Tolerance
    sign_sigma::Float64
    max_joint_points::Int
    min_pool::Int
    offset_fraction::Float64
    offset_points::Int
    screening::Float64
    tile::Int
end

function Settings(;
    window = 9,
    min_points = 7,
    neighbors = nothing,
    fraction = 0.6,
    cutoff = 2.5,
    level = 0.05,
    max_outliers = 0.1,
    critical = :auto,
    seed = 1,
    tolerance = Tolerance((;)),
    sign_sigma = 2.0,
    max_joint_points = 250_000,
    min_pool = 6,
    offset_fraction = 0.75,
    offset_points = 3,
    screening = 0.7,
    tile = 3,
)
    return Settings(
        window,
        min_points,
        neighbors,
        fraction,
        cutoff,
        level,
        max_outliers,
        critical,
        seed,
        tolerance,
        sign_sigma,
        max_joint_points,
        min_pool,
        offset_fraction,
        offset_points,
        screening,
        tile,
    )
end

# ----------------------------------------------------------------------------------
# Stage 1: lines
# ----------------------------------------------------------------------------------

"""
    LineTask

The points of one subgroup that share the same state in every coordinate but `axis`, in
increasing order of the transformed coordinate, with room for the result of each one.
"""
struct LineTask
    group::Int
    axis::Int
    pos::Vector{Int}
    xi::Vector{Float64}
    x::Vector{Float64}
    y::Vector{Float64}
    u::Vector{Float64}
    ref::Vector{Int32}
    z::Vector{Float64}
    window::Vector{Int}
    consensus::Vector{Int}
    phi::Vector{Float64}
    yhat::Vector{Float64}
    slope::Vector{Float64}
    slope_sd::Vector{Float64}
    curvature::Vector{Float64}
    curvature_sd::Vector{Float64}
    influence::Vector{Float64}
    offset::BitVector
    offset_members::Vector{Int}
    offset_deviating::Vector{Int}
    flag::BitVector
    statistic::Vector{Float64}
    critical::Vector{Float64}
    rank::Vector{Int}
    multi_source::BitVector
end

function LineTask(group, axis, pos, xi, x, y, u, ref)
    n = length(pos)
    return LineTask(
        group,
        axis,
        pos,
        xi,
        x,
        y,
        u,
        ref,
        fill(NaN, n),
        zeros(Int, n),
        zeros(Int, n),
        fill(NaN, n),
        fill(NaN, n),
        fill(NaN, n),
        fill(NaN, n),
        fill(NaN, n),
        fill(NaN, n),
        fill(NaN, n),
        falses(n),
        zeros(Int, n),
        zeros(Int, n),
        falses(n),
        fill(NaN, n),
        fill(NaN, n),
        zeros(Int, n),
        falses(n),
    )
end

"""
    process_line!(ws, task, set)
    process_line!(task, set)

Fill the result arrays of `task`. Each point gets the window of `set.window` consecutive
points centered on it (shifted at the two ends of the line, so that every window is full);
the fit of a window is shared by the points that use it. The fits are made in the workspace
`ws` (a [`LineWS`](@ref) of at least `set.window` points, which a worker keeps for all its
lines); without one, a workspace is made for the line.
"""
function process_line!(ws::LineWS, task::LineTask, set::Settings)
    m = length(task.pos)
    m >= set.min_points || return nothing
    w = min(set.window, m)
    resize_window!(ws, w)
    tvar = truncated_variance(set.cutoff)
    half = (w - 1) ÷ 2
    last_start = m - w + 1
    j = 1
    while j <= m
        s = clamp(j - half, 1, last_start)
        jend = j
        while jend < m && clamp(jend + 1 - half, 1, last_start) == s
            jend += 1
        end
        process_window!(ws, task, s, w, j:jend, set, tvar)
        j = jend + 1
    end
    return nothing
end

function process_line!(task::LineTask, set::Settings)
    length(task.pos) >= set.min_points || return nothing
    return process_line!(LineWS(min(set.window, length(task.pos))), task, set)
end

function process_window!(
    ws::LineWS,
    task::LineTask,
    s::Int,
    w::Int,
    js::UnitRange{Int},
    set::Settings,
    tvar::Float64,
)
    for l = 1:w
        ws.x[l] = task.x[s+l-1]
    end
    sort!(ws.x)
    count_distinct(set.tolerance, task.axis, ws.x) >= 4 || return nothing
    lo, hi = task.xi[s], task.xi[s+w-1]
    hr = (hi - lo) / 2
    hr > 0 || return nothing
    mid = (hi + lo) / 2
    t, y, X = ws.t, ws.y, ws.X
    for l = 1:w
        tl = (task.xi[s+l-1] - mid) / hr
        t[l] = tl
        y[l] = task.y[s+l-1]
        X[l, 2] = tl
        X[l, 3] = tl^2
    end
    known = fill_missing_uncertainty!(ws, task.u, s)
    u = ws.u
    refs = task.ref
    q = clamp(ceil(Int, set.fraction * w), 4, w)
    scale = lqs_parabola!(ws, q, set.cutoff, known ? 1.0 : 0.0)
    isnan(scale) && return nothing
    robust_refit!(ws, known, set.cutoff, tvar) || return nothing
    multi_source = false
    for i = 2:w
        if refs[s+i-1] != refs[s]
            multi_source = true
            break
        end
    end
    if multi_source
        for j in js
            task.multi_source[j] = true
        end
    end
    phi, beta, ainv = ws.phi, ws.beta, ws.ainv
    consensus = 0
    for l = 1:w
        ws.inliers[l] && (consensus += 1)
    end
    for j in js
        l = j - s + 1
        tj = t[l]
        task.z[j] = ws.z[l]
        task.window[j] = w
        task.consensus[j] = consensus
        task.phi[j] = phi
        task.yhat[j] = beta[1] + tj * (beta[2] + tj * beta[3])
        g = (0.0, 1 / hr, 2tj / hr)
        gag = 0.0
        for a = 1:3, b = 1:3
            gag += g[a] * ainv[a, b] * g[b]
        end
        task.slope[j] = (beta[2] + 2beta[3] * tj) / hr
        task.slope_sd[j] = phi * sqrt(gag)
        task.curvature[j] = 2beta[3] / hr^2
        task.curvature_sd[j] = phi * 2 * sqrt(ainv[3, 3]) / hr^2
        if ws.inliers[l] && 1 - ws.h[l] > 1.0e-8
            factor = ws.e[l] / (u[l]^2 * (1 - ws.h[l]))
            xrow = (1.0, tj, tj^2)
            shift = 0.0
            for a = 1:3
                dbeta = 0.0
                for b = 1:3
                    dbeta += ainv[a, b] * xrow[b] * factor
                end
                shift += g[a] * dbeta
            end
            task.influence[j] = gag > 0 ? shift / (phi * sqrt(gag)) : NaN
        end
        # Systematic offset of one source: several points of the same publication on the
        # same side, far from the curve that the others define.
        zwl = ws.e[l] / (phi * u[l])
        if multi_source && abs(zwl) > set.cutoff
            members = 0
            deviating = 0
            for i = 1:w
                refs[s+i-1] == refs[s+l-1] || continue
                members += 1
                zwi = ws.e[i] / (phi * u[i])
                if abs(zwi) > set.cutoff && sign(zwi) == sign(zwl)
                    deviating += 1
                end
            end
            if members >= set.offset_points && deviating / members >= set.offset_fraction
                task.offset[j] = true
                task.offset_members[j] = members
                task.offset_deviating[j] = deviating
            end
        end
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Stage 2: joint local surface
# ----------------------------------------------------------------------------------

"""
    JointTask

All points of one subgroup in which at least two coordinates vary, with the transformed
coordinates (`xi`, one column per point), their ranges (`scale`) and room for the results.
`cross` is the mixed second derivative of the first two varying coordinates.
"""
struct JointTask
    group::Int
    axes::Vector{Int}
    pos::Vector{Int}
    xi::Matrix{Float64}
    scaled::Matrix{Float64}
    scale::Vector{Float64}
    x::Matrix{Float64}
    y::Vector{Float64}
    u::Vector{Float64}
    ref::Vector{Int32}
    z::Vector{Float64}
    window::Vector{Int}
    consensus::Vector{Int}
    phi::Vector{Float64}
    yhat::Vector{Float64}
    slope::Matrix{Float64}
    slope_sd::Matrix{Float64}
    curvature::Matrix{Float64}
    curvature_sd::Matrix{Float64}
    cross::Vector{Float64}
    cross_sd::Vector{Float64}
    multi_source::Vector{Bool}
    flag::BitVector
    statistic::Vector{Float64}
    critical::Vector{Float64}
    rank::Vector{Int}
    skipped::Base.RefValue{Bool}
end

function JointTask(group, axes, pos, xi, x, y, u, ref)
    d, n = size(xi)
    lows = Float64[minimum(view(xi, a, :)) for a = 1:d]
    scale = Float64[maximum(view(xi, a, :)) - lows[a] for a = 1:d]
    scaled = Matrix{Float64}(undef, d, n)
    for i = 1:n, a = 1:d
        scaled[a, i] = (xi[a, i] - lows[a]) / scale[a]
    end
    return JointTask(
        group,
        axes,
        pos,
        xi,
        scaled,
        scale,
        x,
        y,
        u,
        ref,
        fill(NaN, n),
        zeros(Int, n),
        zeros(Int, n),
        fill(NaN, n),
        fill(NaN, n),
        fill(NaN, d, n),
        fill(NaN, d, n),
        fill(NaN, d, n),
        fill(NaN, d, n),
        fill(NaN, n),
        fill(NaN, n),
        fill(false, n),
        falses(n),
        fill(NaN, n),
        fill(NaN, n),
        zeros(Int, n),
        Ref(false),
    )
end
