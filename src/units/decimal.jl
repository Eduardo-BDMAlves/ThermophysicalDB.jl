# Numbers as a person wrote them. A `Float64` cannot hold 0.273233 exactly, but it is the nearest
# `Float64` to it, and that is what must be stored and shown: `0.273233`, not `0.27323300000000004`.
# Binary arithmetic on such numbers (a percentage of a value, a change of unit) adds noise in the last
# digits, so the conversions of a number that was typed are made on its decimal value and rounded once,
# and the numbers that are derived by multiplying a column are cleaned of what is only noise.

const POW10 = ntuple(k -> parse(Float64, "1e$(k - 1)"), 23)   # 1e0 ... 1e22, all exact
const MAX_POW10 = 22

# `10^k` for |k| <= 22, correctly rounded.
@inline pow10(k::Int) = k >= 0 ? @inbounds(POW10[k+1]) : 1.0 / @inbounds(POW10[1-k])

"""
    exact_float(r::Rational) -> Float64

The `Float64` nearest to `r`, rounded once. (`Float64(r)` of a rational with a numerator beyond 2^53
rounds twice and can be one unit in the last place away.)
"""
function exact_float(r::Rational{<:Integer})
    n, d = numerator(r), denominator(r)
    limit = Int128(1) << 53
    (abs(n) <= limit && d <= limit) && return Float64(n) / Float64(d)
    return Float64(Rational{BigInt}(n, d))
end

"""
    decimal_value(x) -> Exact

The exact value of the decimal number that the shortest text of `x` writes: `decimal_value(0.1223)`
is `1223 // 10000`, while the binary value of the `Float64` is not. Used to convert a number that a
person typed. An integer or a rational is itself, and a number that does not fit goes by its binary
value.
"""
function decimal_value(x::Float64)::Exact
    isfinite(x) || throw(InexactError(:Exact, Exact, x))
    iszero(x) && return Exact(0)
    parts = split(string(abs(x)), 'e')
    exponent = length(parts) == 2 ? parse(Int, parts[2]) : 0
    point = findfirst('.', parts[1])
    whole = point === nothing ? parts[1] : parts[1][1:(point-1)]
    fraction = point === nothing ? "" : parts[1][(point+1):end]
    digits = parse(Int128, whole * fraction)
    exponent -= length(fraction)
    value = if exponent >= 0
        ndigits(digits) + exponent <= 37 || return exact_value(x)
        Exact(digits * Int128(10)^exponent)
    else
        -exponent <= 37 || return exact_value(x)
        digits // Int128(10)^(-exponent)
    end
    return signbit(x) ? -value : value
end
decimal_value(x::Float32) = decimal_value(parse(Float64, string(x)))
decimal_value(x::Real) = exact_value(x)

"""
    clean_float(x) -> Float64

`x` rounded to 15 significant digits, the digits that a `Float64` keeps from any decimal number
(`5.8704000000000006e-5` is `5.8704e-5`, `0.12229999999999999` is `0.1223`). A number that a person
typed has at most that many digits and does not change; what changes is the noise that binary
arithmetic leaves in the 16th and 17th digits of a product or a conversion, which no measurement
has. `NaN`, infinities and zero are returned as they are.
"""
function clean_float(x::Float64)
    (isfinite(x) && !iszero(x)) || return x
    return round_sigdigits(x, 15)
end

"""
    clean_floats!(v) -> v

[`clean_float`](@ref) of every element of `v`.
"""
function clean_floats!(v::AbstractVector{Float64})
    @inbounds for i in eachindex(v)
        v[i] = clean_float(v[i])
    end
    return v
end

# The exponent e of the leading digit of x > 0, so that 10^e <= x < 10^(e+1).
function leading_exponent(x::Float64)
    e = floor(Int, log10(x))
    if -MAX_POW10 <= e < MAX_POW10
        x < pow10(e) && (e -= 1)
        x >= pow10(e + 1) && (e += 1)
    end
    return e
end

# `x` rounded to a multiple of 10^place, halves away from zero. Binary arithmetic is only used
# where it is exact or correctly rounded (an integer below 2^53 divided or multiplied by a power
# of ten up to 1e22). For a few digits a half is recognised within the noise of the product, so
# that 0.15 to one digit is 0.2, as a person would write it; for many digits there is no such
# margin and the plain rounding is the nearest decimal anyway.
function round_to_place(x::Float64, place::Int)
    (isfinite(x) && !iszero(x)) || return x
    if abs(place) > MAX_POW10
        digits = leading_exponent(abs(x)) - place + 1
        digits < 1 && return copysign(0.0, x)
        return parse(Float64, string(round(BigFloat(x); sigdigits = digits)))
    end
    q = place <= 0 ? abs(x) * pow10(-place) : abs(x) / pow10(place)
    q >= 4.5e15 && return x
    base = floor(q)
    tolerance = q < 1.0e9 ? 8 * eps(q) : 0.0
    r = q - base >= 0.5 - tolerance ? base + 1.0 : base
    y = place <= 0 ? r / pow10(-place) : r * pow10(place)
    return copysign(y, x)
end

# `x` rounded to `n` significant digits.
round_sigdigits(x::Float64, n::Int) = round_to_place(x, leading_exponent(abs(x)) - n + 1)

"""
    uncertainty_place(u) -> Int

The position of the last digit that an uncertainty `u > 0` is reported with, as a power of ten: two
significant digits when the leading digit is 1 or 2, one otherwise (the rule of the GUM, 7.2.6), so
`6.115e-5` is `6e-5` (place `-5`) and `0.0187` is `0.019` (place `-3`).
"""
function uncertainty_place(u::Float64)
    e = leading_exponent(u)
    lead = abs(e) <= MAX_POW10 ? u / pow10(e) : u / 10.0^e
    return e - (lead < 3 ? 2 : 1) + 1
end
