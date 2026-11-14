# The machinery of the study of allocations: scenarios, measurement, fingerprints of the results,
# the allocation sites by line and the optimization report of JET. It knows nothing about the data
# or about what is measured (see `context.jl` and `scenarios.jl`).
#
# A scenario is a function of the package called on prepared data. For each one the study
#
#   1. runs it once outside the measurement (compilation),
#   2. runs it again `repeats` times, each time on a state that `setup` just built, and keeps the
#      smallest time and the smallest number of bytes (the bytes do not vary between runs),
#   3. reduces the result to a fingerprint, the proof that a change of code did not change the data.

module AllocStudy

using Dates: Dates
using Printf: @sprintf
using Profile: Profile
using SHA: SHA
using Tables: Tables

export Scenario, SCENARIOS, scenario!, Measurement, Site, measure, allocation_sites, digest

# ----------------------------------------------------------------------------------
# Scenarios
# ----------------------------------------------------------------------------------

"""
    Scenario

`setup(ctx)` builds the state (not measured, rebuilt before every run), `run(state)` is what is
measured, `fingerprint(result)` reduces the result to what must not change, and `output(result)` is
the part of the result whose size is compared with the allocated bytes. `requires` is `:any` or
`:synthetic` (the scenario needs the generator of the synthetic database).
"""
struct Scenario
    group::String
    name::String
    requires::Symbol
    setup::Any
    run::Any
    fingerprint::Any
    output::Any
    repeats::Int
end

Base.show(io::IO, s::Scenario) = print(io, s.group, "/", s.name)
label(s::Scenario) = string(s.group, "/", s.name)

const SCENARIOS = Scenario[]

function scenario!(
    group::AbstractString,
    name::AbstractString;
    setup,
    run,
    requires::Symbol = :any,
    fingerprint = identity,
    output = identity,
    repeats::Integer = 3,
)
    requires in (:any, :synthetic) ||
        throw(ArgumentError("requires must be :any or :synthetic, got :$requires"))
    push!(
        SCENARIOS,
        Scenario(
            String(group),
            String(name),
            requires,
            setup,
            run,
            fingerprint,
            output,
            Int(repeats),
        ),
    )
    return nothing
end

# ----------------------------------------------------------------------------------
# Fingerprints
# ----------------------------------------------------------------------------------

# Types whose content is not part of a fingerprint (a whole database shared by many results);
# the scenarios add the types of the package.
const SKIP_TYPES = Type[]

mutable struct Digest
    context::SHA.SHA1_CTX
    items::Int
    floats::Int          # how many of the items are floating-point numbers
    total::Float64       # their sum (finite ones)
    weighted::Float64    # their sum, each weighted by its position, so a reordering shows
end
Digest() = Digest(SHA.SHA1_CTX(), 0, 0, 0.0, 0.0)

weight(position::Int) = Float64(position % 1009 + 1)

tag!(d::Digest, byte::UInt8) = (SHA.update!(d.context, UInt8[byte]); nothing)
bytes!(d::Digest, x::AbstractVector{UInt8}) = (SHA.update!(d.context, x); nothing)
text!(d::Digest, s::AbstractString) = (bytes!(d, collect(codeunits(s))); tag!(d, 0x00))

"""
    canon(x)

What of `x` goes into a fingerprint; the scenarios add methods for the types of the package.
"""
canon(x) = x

feed!(d::Digest, x, depth::Int = 0) = feed_value!(d, canon(x), depth)

function feed_value!(d::Digest, x::AbstractFloat, ::Int)
    tag!(d, 0x10)
    bytes!(d, collect(reinterpret(UInt8, [Float64(x)])))
    d.items += 1
    d.floats += 1
    if isfinite(x)
        d.total += x
        d.weighted += x * weight(d.items)
    end
    return nothing
end

function feed_value!(d::Digest, x::Integer, ::Int)
    tag!(d, 0x11)
    bytes!(d, collect(reinterpret(UInt8, [Int64(x)])))
    d.items += 1
    return nothing
end

feed_value!(d::Digest, x::Bool, ::Int) = (tag!(d, x ? 0x12 : 0x13); d.items += 1; nothing)
feed_value!(d::Digest, x::AbstractString, ::Int) =
    (tag!(d, 0x14); text!(d, x); d.items += 1; nothing)
feed_value!(d::Digest, x::Symbol, ::Int) =
    (tag!(d, 0x15); text!(d, String(x)); d.items += 1; nothing)
feed_value!(d::Digest, ::Nothing, ::Int) = (tag!(d, 0x16); nothing)
feed_value!(d::Digest, ::Missing, ::Int) = (tag!(d, 0x17); nothing)

function feed_value!(d::Digest, x::AbstractArray, depth::Int)
    tag!(d, 0x20)
    for n in size(x)
        feed_value!(d, n, depth)
    end
    E = eltype(x)
    # The bytes of an array of plain values are hashed as they are, except when the element has
    # padding (a struct of a `Float64` and seven `Int32`, say): the padding is not initialised and
    # would make the same values hash differently from one run to the next.
    if x isa DenseArray && isbitstype(E) && !Base.datatype_haspadding(E)
        text!(d, string(E))
        GC.@preserve x bytes!(d, unsafe_wrap(Array, Ptr{UInt8}(pointer(x)), sizeof(x)))
        base = d.items
        d.items += length(x)
        if E <: AbstractFloat
            d.floats += length(x)
            s = 0.0
            w = 0.0
            for (i, v) in enumerate(x)
                if isfinite(v)
                    s += Float64(v)
                    w += Float64(v) * weight(base + i)
                end
            end
            d.total += s
            d.weighted += w
        end
    else
        for e in x
            feed!(d, e, depth)
        end
    end
    return nothing
end

function feed_value!(d::Digest, x::Union{Tuple,NamedTuple}, depth::Int)
    tag!(d, 0x30)
    x isa NamedTuple && foreach(k -> text!(d, String(k)), keys(x))
    for e in x
        feed!(d, e, depth)
    end
    return nothing
end

function feed_value!(d::Digest, x::AbstractDict, depth::Int)
    tag!(d, 0x31)
    for k in sort!(collect(keys(x)); by = string)
        feed!(d, k, depth)
        feed!(d, x[k], depth)
    end
    return nothing
end

function feed_value!(d::Digest, x, depth::Int)
    T = typeof(x)
    if any(S -> T <: S, SKIP_TYPES)
        tag!(d, 0x40)
        text!(d, string(T))
    elseif Tables.istable(T)
        feed_value!(d, Tables.columntable(x), depth)
    elseif isstructtype(T) && !isempty(fieldnames(T)) && depth < 4
        tag!(d, 0x41)
        text!(d, string(T))
        for name in fieldnames(T)
            isdefined(x, name) && feed!(d, getfield(x, name), depth + 1)
        end
    else
        tag!(d, 0x42)
        text!(d, repr(x))
    end
    return nothing
end

"""
    digest(x) -> NamedTuple

The fingerprint of `x`: `hash` (SHA-1 of every value, bit by bit), `items` (how many numbers and
texts went in), `floats` (how many of them are floating-point), and `total` and `weighted` (the sum of
the finite floats and the same sum weighted by position), which tell a change in the last digits from
a change of the data (a reordering changes `weighted`).
"""
function digest(x)
    d = Digest()
    feed!(d, x)
    return (;
        hash = bytes2hex(SHA.digest!(d.context)),
        items = d.items,
        floats = d.floats,
        total = d.total,
        weighted = d.weighted,
    )
end

# ----------------------------------------------------------------------------------
# Measurement
# ----------------------------------------------------------------------------------

"Seconds of calls in the steady-state loop of `measure` (set by the option `pressure=`)."
const PRESSURE_SECONDS = Ref(2.0)

struct Measurement
    seconds::Float64
    bytes::Int
    allocations::Int
    gc_share::Float64   # share of the time in the garbage collector, in steady state (no forced collection before)
    gc_after::Float64   # seconds of one young collection right after a run (what the garbage of one call costs when the collector does run)
    output_bytes::Int
    items::Int
    fingerprint::NamedTuple{
        (:hash, :items, :floats, :total, :weighted),
        Tuple{String,Int,Int,Float64,Float64},
    }
    stable::Bool        # the fingerprint was the same in every run
end

nitems(x::AbstractVector) = length(x)
nitems(x::NamedTuple) = isempty(x) ? 0 : nitems(first(x))
nitems(x) = 1

allocation_count(gc) = Int(gc.malloc + gc.realloc + gc.poolalloc + gc.bigalloc)

"""
    measure(s, ctx) -> Measurement

Run the scenario `s` on the data `ctx`; any error is for the caller.
"""
function measure(s::Scenario, ctx)
    state = s.setup(ctx)
    warm = s.run(state)                       # compilation, not measured
    reference = digest(s.fingerprint(warm))
    stable = true
    seconds, bytes, allocations = Inf, typemax(Int), typemax(Int)
    for _ = 1:s.repeats
        state = s.setup(ctx)
        GC.gc()
        timed = @timed s.run(state)
        seconds = min(seconds, timed.time)
        if timed.bytes < bytes
            bytes = timed.bytes
            allocations = allocation_count(timed.gcstats)
        end
        stable &= digest(s.fingerprint(timed.value)).hash == reference.hash
    end
    # The runs above start after a forced collection, so a young heap rarely collects inside them and
    # the time of the collector would read zero. Steady state: no forced collection, so the pauses
    # that the garbage of the earlier runs and of the setups brings are counted.
    # The loop runs until the calls have taken `PRESSURE_SECONDS` in all (or 20000 calls, or three
    # times that in wall time with the setups): the collector only starts after some GiB of garbage
    # on a machine with a lot of memory, so a few calls never show it.
    total, collecting, after = 0.0, 0.0, Inf
    wall = time()
    for i = 1:20000
        state = s.setup(ctx)
        timed = @timed s.run(state)
        total += timed.time
        collecting += timed.gctime
        (i >= max(s.repeats, 5) && total >= PRESSURE_SECONDS[]) && break
        time() - wall > 3 * PRESSURE_SECONDS[] + 1 && break
    end
    gc_share = total > 0 ? collecting / total : 0.0
    for _ = 1:3                                  # then the collection that one call's garbage costs
        state = s.setup(ctx)
        value = s.run(state)
        after = min(after, @elapsed GC.gc(false))
        value === nothing && println()
    end
    out = s.output(warm)
    return Measurement(
        seconds,
        bytes,
        allocations,
        gc_share,
        after,
        Base.summarysize(out),
        nitems(out),
        reference,
        stable,
    )
end

# ----------------------------------------------------------------------------------
# Allocation sites
# ----------------------------------------------------------------------------------

struct Site
    file::String
    line::Int
    func::String
    type::String
    bytes::Float64
    count::Float64
end

# Fraction of the allocations that the profiler records: all of them for what is small, fewer for
# what is large (the numbers are scaled back, so they are estimates there).
function sample_rate(bytes::Integer)
    bytes > 500 * 2^20 && return 0.01
    bytes > 50 * 2^20 && return 0.05
    bytes > 5 * 2^20 && return 0.25
    return 1.0
end

# The innermost frame in the code of the package (`roots`), or the first frame when there is none.
function site_of(frames, roots)
    for f in frames
        file = String(f.file)
        for root in roots
            startswith(file, root) &&
                return (relpath(file, dirname(root)), Int(f.line), String(f.func))
        end
    end
    isempty(frames) && return ("(unknown)", 0, "(unknown)")
    f = first(frames)
    return ("(outside the package)", 0, String(f.func))
end

"""
    allocation_sites(s, ctx, roots, bytes) -> Vector{Site}

Where the scenario allocates, by line of the package and type, from `Profile.Allocs`.
"""
function allocation_sites(s::Scenario, ctx, roots, bytes::Integer)
    rate = sample_rate(bytes)
    state = s.setup(ctx)
    s.run(s.setup(ctx))                       # nothing is left to compile
    GC.gc()
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate = rate s.run(state)
    result = Profile.Allocs.fetch()
    Profile.Allocs.clear()
    table = Dict{NTuple{4,String},Tuple{Float64,Float64}}()
    for a in result.allocs
        file, line, func = site_of(a.stacktrace, roots)
        key = (file, string(line), func, string(a.type))
        b, c = get(table, key, (0.0, 0.0))
        table[key] = (b + a.size / rate, c + 1 / rate)
    end
    sites = Site[Site(k[1], parse(Int, k[2]), k[3], k[4], v[1], v[2]) for (k, v) in table]
    sort!(sites; by = x -> -x.bytes)
    return sites
end

end # module
