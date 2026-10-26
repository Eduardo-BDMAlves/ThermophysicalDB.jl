# Bookkeeping shared by the outlier stages: tolerances, coordinate transformations, the
# clustering of points into lines of constant state, and a small work scheduler.

# ----------------------------------------------------------------------------------
# Axes and tolerances
# ----------------------------------------------------------------------------------

"""
The coordinates of a point, in this order: temperature `:T`, pressure `:P`, and the amount
of the first and second component of the system in canonical order (`:x1`, `:x2`). A
binary system has `:x1` only, a ternary one has both, a pure fluid has neither.
"""
const AXES = (:T, :P, :x1, :x2)

"""
    Tolerance(T, P, x)

Distance under which two values of a coordinate are taken to be the same state: `T` in K
(absolute), `P` as a fraction of the pressure (relative) and `x` in composition units
(absolute). Measurements are rounded and instruments drift, so "the same temperature" never
means exactly equal.
"""
struct Tolerance
    T::Float64
    P::Float64
    x::Float64
end

function Tolerance(spec::NamedTuple)
    unknown = setdiff(keys(spec), (:T, :P, :x))
    isempty(unknown) ||
        throw(ArgumentError("unknown tolerance keys $(collect(unknown)); use T, P and x"))
    tol = Tolerance(
        Float64(get(spec, :T, 0.1)),
        Float64(get(spec, :P, 0.01)),
        Float64(get(spec, :x, 1.0e-3)),
    )
    tol.T >= 0 && 0 <= tol.P < 1 && tol.x >= 0 ||
        throw(ArgumentError("tolerances must be non-negative and the pressure one below 1"))
    return tol
end

"Tolerance of `axis` (1 to 4) around the magnitude `scale`."
function axis_tolerance(tol::Tolerance, axis::Integer, scale::Real)
    axis == 1 && return tol.T
    axis == 2 && return tol.P * abs(scale)
    return tol.x
end

same_state(tol::Tolerance, axis::Integer, a::Real, b::Real) =
    abs(a - b) <= axis_tolerance(tol, axis, max(abs(a), abs(b)))

"Number of distinct values, under the tolerance, in values already sorted."
function count_distinct(tol::Tolerance, axis::Integer, sorted::AbstractVector{Float64})
    isempty(sorted) && return 0
    count = 1
    previous = sorted[1]
    for i = 2:length(sorted)
        if !same_state(tol, axis, sorted[i], previous)
            count += 1
            previous = sorted[i]
        end
    end
    return count
end

# ----------------------------------------------------------------------------------
# Coordinate transformations
# ----------------------------------------------------------------------------------

"""
    Transformation(log_response, inverse_T, log_P)

The coordinates in which a subgroup is fitted. Many properties are close to straight lines
or gentle parabolas only after a change of variable, and a local parabola fitted in the
wrong variable leaves systematic residuals that look like outliers:

- `log_response`: fit `ln y` instead of `y`. Viscosity, vapor pressure, diffusion
  coefficients and the Henry constants span decades and follow Arrhenius-like laws.
- `inverse_T`: use `1/T` instead of `T`. It goes with `log_response` because
  `ln y ≈ A + B/T` for an activated process (`B = -E/R` for a viscosity).
- `log_P`: use `ln P` instead of `P`. Automatically it is chosen only for the properties
  that follow a power law of the pressure in a gas (kinematic viscosity, thermal
  diffusivity, diffusion coefficient: `y ∝ 1/P` because they carry a factor `1/ρ`), and only
  in a gas phase. Elsewhere it is not: a liquid density is close to linear in `P` (the Tait
  equation is linear in `ln(P + B)` with `B` of the order of hundreds of MPa), a gas density
  is linear in `P` at low pressure, and a viscosity follows Barus' law `ln η ≈ a + αP`. Ask
  for it with `transform = (P = :log,)` where it fits.

Compositions are never transformed.
"""
struct Transformation
    log_response::Bool
    inverse_T::Bool
    log_P::Bool
end

const LOG_RESPONSE_PATTERN =
    r"viscosity|vapor|vapour|sublimation|diffusion|diffusivity|henry"i

# In the gas phase the kinematic viscosity, the thermal diffusivity and the diffusion
# coefficient are inversely proportional to the pressure (they carry a factor 1/ρ and the
# density of a gas is proportional to P), so ln y is a straight line against ln P.
const GAS_POWER_LAW_PATTERN = r"kinematic|diffusivity|diffusion"i
const GAS_PHASE_PATTERN = r"\bgas\b|vapou?r"i

"""
    choose_transformation(spec, label, phase, y, pressure) -> Transformation

`spec` is `:auto`, `:none` or a `NamedTuple` with any of `response` (`:auto`, `:log`,
`:identity`), `T` (`:auto`, `:inverse`, `:identity`) and `P` (`:auto`, `:log`,
`:identity`; `:auto` is the identity except for the gas power laws). A logarithm is only applied when every value of the subgroup is positive.
"""
function choose_transformation(
    spec,
    label::AbstractString,
    phase::AbstractString,
    y::AbstractVector{Float64},
    pressure::AbstractVector{Float64},
)
    spec === :none && return Transformation(false, false, false)
    options = spec === :auto ? (;) : spec
    spec isa NamedTuple ||
        spec === :auto ||
        throw(
            ArgumentError(
                "transform must be :auto, :none or a NamedTuple, got $(repr(spec))",
            ),
        )
    unknown = setdiff(keys(options), (:response, :T, :P))
    isempty(unknown) || throw(
        ArgumentError("unknown transform keys $(collect(unknown)); use response, T and P"),
    )
    response = get(options, :response, :auto)
    response in (:auto, :log, :identity) ||
        throw(ArgumentError("transform response must be :auto, :log or :identity"))
    all_positive = all(v -> v > 0, y)
    log_response =
        all_positive &&
        (response === :log || (response === :auto && occursin(LOG_RESPONSE_PATTERN, label)))
    temperature = get(options, :T, :auto)
    temperature in (:auto, :inverse, :identity) ||
        throw(ArgumentError("transform T must be :auto, :inverse or :identity"))
    inverse_T = temperature === :inverse || (temperature === :auto && log_response)
    pressure_option = get(options, :P, :auto)
    pressure_option in (:auto, :log, :identity) ||
        throw(ArgumentError("transform P must be :auto, :log or :identity"))
    finite = Float64[v for v in pressure if isfinite(v)]
    positive = !isempty(finite) && minimum(finite) > 0
    gas_power_law =
        log_response &&
        occursin(GAS_POWER_LAW_PATTERN, label) &&
        occursin(GAS_PHASE_PATTERN, phase)
    log_P =
        positive &&
        (pressure_option === :log || (pressure_option === :auto && gas_power_law))
    return Transformation(log_response, inverse_T, log_P)
end

forward_response(tr::Transformation, y) = tr.log_response ? log(y) : y
backward_response(tr::Transformation, y) = tr.log_response ? exp(y) : y

function forward_axis(tr::Transformation, axis::Integer, x)
    axis == 1 && return tr.inverse_T ? 1 / x : x
    axis == 2 && return tr.log_P ? log(x) : x
    return x
end

"Derivative `dξ/dx` of the coordinate transformation of `axis` at `x`."
function axis_derivative(tr::Transformation, axis::Integer, x)
    axis == 1 && return tr.inverse_T ? -1 / x^2 : 1.0
    axis == 2 && return tr.log_P ? 1 / x : 1.0
    return 1.0
end

function describe(tr::Transformation)
    parts = String[]
    tr.log_response && push!(parts, "ln(y)")
    tr.inverse_T && push!(parts, "1/T")
    tr.log_P && push!(parts, "ln(P)")
    return isempty(parts) ? "identity" : join(parts, ", ")
end

# ----------------------------------------------------------------------------------
# Lines of constant state
# ----------------------------------------------------------------------------------

"""
    cluster_states(coord, members, others, tol) -> Vector{Vector{Int}}

Split `members` (row numbers of `coord`, an `n × 4` matrix of original coordinates) into
groups whose points share the same state in every axis of `others`, within the tolerance.
It is single linkage: a point joins a group when it is within tolerance of any point of
it, so a drifting setpoint (300.0, 300.04, 300.08 K) stays together while two distinct
isotherms do not. Points are swept in the order of the first axis, so the cost is close to
linear in practice.
"""
function cluster_states(
    coord::Matrix{Float64},
    members::Vector{Int},
    others::Vector{Int},
    tol::Tolerance,
)
    isempty(others) && return [members]
    first_axis = others[1]
    order = sort(members; by = i -> (coord[i, first_axis], i))
    n = length(order)
    parent = collect(1:n)
    function find(i)
        while parent[i] != i
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    for a = 1:n
        ia = order[a]
        for b = (a+1):n
            ib = order[b]
            same_state(tol, first_axis, coord[ia, first_axis], coord[ib, first_axis]) ||
                break
            if all(ax -> same_state(tol, ax, coord[ia, ax], coord[ib, ax]), others)
                ra, rb = find(a), find(b)
                ra == rb || (parent[max(ra, rb)] = min(ra, rb))
            end
        end
    end
    clusters = Dict{Int,Vector{Int}}()
    for a = 1:n
        push!(get!(clusters, find(a), Int[]), order[a])
    end
    return [clusters[k] for k in sort!(collect(keys(clusters)))]
end

# ----------------------------------------------------------------------------------
# Work scheduling
# ----------------------------------------------------------------------------------

"""
    dynamic_foreach(work!, n; init = () -> nothing)

Call `work!(state, i)` for `i = 1:n` on all threads. Each worker creates its own `state`
with `init()` once and takes the next index from a shared counter, so a few expensive items
do not leave the other threads idle. Every call must write only to storage that belongs to
its own `i`; the result then does not depend on the number of threads.
"""
function dynamic_foreach(work!, n::Integer; init = () -> nothing)
    n <= 0 && return nothing
    workers = min(Threads.nthreads(), n)
    if workers == 1
        worker_loop(work!, init, Threads.Atomic{Int}(1), n)
        return nothing
    end
    counter = Threads.Atomic{Int}(1)
    tasks = [Threads.@spawn(worker_loop(work!, init, counter, n)) for _ = 1:workers]
    foreach(fetch, tasks)
    return nothing
end

# The loop of one worker lives in its own function so that `state` is a local variable of
# the call: a variable shared with a spawned closure would be one workspace for all threads.
function worker_loop(work!, init, counter::Threads.Atomic{Int}, n::Int)
    state = init()
    while true
        i = Threads.atomic_add!(counter, 1)
        i > n && break
        work!(state, i)
    end
    return nothing
end
