# Compact columns for the measurement table. A column of 2.8 million `Float64` that holds
# only a handful of distinct values (the level of confidence, the assessment number) is
# stored as one small unsigned code per row plus the table of its values; a column of
# identifiers that never exceeds a few hundred values is stored with a narrower integer.
# Both give the same values back to the code that reads them, so readers do not change.

"""
    narrow(T, x, what) -> T

Convert the identifier `x` to the unsigned integer type `T`, throwing an `ArgumentError`
that names `what` when it does not fit. Narrow identifier columns would otherwise fail
with an `InexactError` that says nothing about the cause.
"""
@inline function narrow(::Type{T}, x::Integer, what::AbstractString) where {T<:Unsigned}
    0 <= x <= typemax(T) && return x % T
    throw(
        ArgumentError(
            "$what $x does not fit in the $(sizeof(T) * 8)-bit column of the dataset " *
            "(the largest identifier is $(typemax(T)))",
        ),
    )
end

"""
    PooledFloats{I}()

A vector of `Float64` stored as codes of type `I` into a table of distinct values: code `0`
is `NaN`, code `c` is `pool[c]`. It behaves as an `AbstractVector{Float64}` (reading,
writing, `push!`, `append!`), so `NaN` and every number are returned exactly as written,
including `-0.0`. It saves memory when a column has few distinct values: the level of
confidence of 2.8 million measurements takes one byte each instead of eight. Adding more
than `typemax(I)` distinct values throws an `ArgumentError`.
"""
struct PooledFloats{I<:Unsigned} <: AbstractVector{Float64}
    codes::Vector{I}
    pool::Vector{Float64}
    lookup::Dict{UInt64,I}   # bit pattern of a value -> code; derived, rebuilt on load
end

PooledFloats{I}() where {I<:Unsigned} = PooledFloats{I}(I[], Float64[], Dict{UInt64,I}())

Base.size(v::PooledFloats) = size(v.codes)
Base.length(v::PooledFloats) = length(v.codes)
Base.IndexStyle(::Type{<:PooledFloats}) = IndexLinear()

@inline function Base.getindex(v::PooledFloats, i::Int)
    @boundscheck checkbounds(v.codes, i)
    code = @inbounds v.codes[i]
    return iszero(code) ? NaN : @inbounds v.pool[code]
end

function code_of!(v::PooledFloats{I}, x::Float64) where {I}
    isnan(x) && return zero(I)
    code = get(v.lookup, reinterpret(UInt64, x), zero(I))
    iszero(code) || return code
    length(v.pool) >= typemax(I) && throw(
        ArgumentError(
            "the column has more than $(Int(typemax(I))) distinct values; " *
            "it cannot be stored in compact form",
        ),
    )
    push!(v.pool, x)
    code = I(length(v.pool))
    v.lookup[reinterpret(UInt64, x)] = code
    return code
end

function Base.setindex!(v::PooledFloats, x::Real, i::Int)
    @boundscheck checkbounds(v.codes, i)
    code = code_of!(v, Float64(x))
    @inbounds v.codes[i] = code
    return x
end

function Base.push!(v::PooledFloats, x::Real)
    push!(v.codes, code_of!(v, Float64(x)))
    return v
end

function Base.append!(v::PooledFloats, xs::AbstractVector{<:Real})
    sizehint!(v.codes, length(v.codes) + length(xs))
    for x in xs
        push!(v, x)
    end
    return v
end

"Rebuild the derived lookup after the pool has been filled from disk."
function rebuild_lookup!(v::PooledFloats{I}) where {I}
    empty!(v.lookup)
    for (code, x) in enumerate(v.pool)
        v.lookup[reinterpret(UInt64, x)] = I(code)
    end
    return v
end

Base.sizehint!(v::PooledFloats, n::Integer) = (sizehint!(v.codes, n); v)
Base.empty!(v::PooledFloats) = (empty!(v.codes); empty!(v.pool); empty!(v.lookup); v)
