# Exact unit arithmetic, with no units package.
#
# Every factor and offset of a conversion is a `Rational{Int128}` written from the legal
# definition of the unit (the inch is 0.0254 m, the pound is 0.45359237 kg, the standard
# gravity is 9.80665 m/s^2, ...). Rational arithmetic is checked: a product that does not
# fit in `Int128` throws `OverflowError` and is never wrong in silence. A chain of
# conversions (degR -> degF -> degC -> K) is composed in rationals and rounded to `Float64`
# once, at the end, so the constants used on a column are the correctly rounded values and
# no error accumulates along the chain.
#
# Two kinds of objects:
#   ExactUnit    a scale to the coherent SI unit and the exponents of the six base
#                dimensions (m, kg, s, K, mol, A); used to build and to check the catalog
#   ExactAffine  y = scale * x + offset, for the scales with an offset (degC, degF)
#
# At run time only `FloatAffine` (two `Float64`) and the kernels `apply!` are used.

"The exact number type of all definitions."
const Exact = Rational{Int128}

const DimVector = NTuple{6,Int8}

const NO_DIMENSION = ntuple(_ -> Int8(0), 6)

"A scale to the coherent SI unit and the exponents of (m, kg, s, K, mol, A)."
struct ExactUnit
    scale::Exact
    dim::DimVector
end

ExactUnit(scale::Real) = ExactUnit(Exact(scale), NO_DIMENSION)

Base.:*(a::ExactUnit, b::ExactUnit) = ExactUnit(a.scale * b.scale, map(+, a.dim, b.dim))
Base.:*(k::Rational, a::ExactUnit) = ExactUnit(Exact(k) * a.scale, a.dim)
Base.:*(k::Integer, a::ExactUnit) = ExactUnit(Exact(k) * a.scale, a.dim)
Base.inv(a::ExactUnit) = ExactUnit(inv(a.scale), map(-, a.dim))
Base.:/(a::ExactUnit, b::ExactUnit) = a * inv(b)
Base.:/(a::ExactUnit, k::Integer) = ExactUnit(a.scale / k, a.dim)

# Integer power by repeated checked multiplication (`^` of integers wraps around).
function Base.:^(a::ExactUnit, n::Integer)
    scale = Exact(1)
    base = n >= 0 ? a.scale : inv(a.scale)
    for _ = 1:abs(n)
        scale *= base
    end
    return ExactUnit(scale, map(d -> Int8(d * n), a.dim))
end

# ----------------------------------------------------------------------------------
# Definitions
# ----------------------------------------------------------------------------------

function base_unit(i::Int)
    return ExactUnit(Exact(1), ntuple(j -> Int8(j == i), 6))
end

const METRE = base_unit(1)
const KILOGRAM = base_unit(2)
const SECOND = base_unit(3)
const KELVIN_UNIT = base_unit(4)
const MOLE = base_unit(5)
const AMPERE = base_unit(6)

const GRAM = KILOGRAM / 1000
const NEWTON = KILOGRAM * METRE / SECOND^2
const PASCAL = NEWTON / METRE^2
const JOULE = NEWTON * METRE
const WATT = JOULE / SECOND
const SIEMENS = AMPERE^2 * SECOND^3 / (KILOGRAM * METRE^2)

# Customary units, each from its legal definition (international yard and pound agreement
# of 1959; the standard gravity of the 3rd CGPM, 1901).
const INCH = Exact(254 // 10000) * METRE
const FOOT = 12 * INCH
const POUND_MASS = Exact(45359237 // 10^8) * KILOGRAM
const STANDARD_GRAVITY = Exact(980665 // 10^5) * METRE / SECOND^2
const POUND_FORCE = POUND_MASS * STANDARD_GRAVITY
const PSI = POUND_FORCE / INCH^2
const BAR = 10^5 * PASCAL
const ATMOSPHERE = 101325 * PASCAL
const TORR = ATMOSPHERE / 760
# Conventional millimetre of mercury: 13595.1 kg/m^3 times the standard gravity times 1 mm.
const MMHG = Exact(135951 // 10) * KILOGRAM / METRE^3 * STANDARD_GRAVITY * (METRE / 1000)

# Time, volume and the other customary units.
const MINUTE = 60 * SECOND
const HOUR = 3600 * SECOND
const DAY = 86400 * SECOND
const LITRE = METRE^3 / 1000
const YARD = 3 * FOOT
const GALLON_US = 231 * INCH^3
const POISE = PASCAL * SECOND / 10
const STOKES = METRE^2 / SECOND / 10^4

# The degree of the rankine and fahrenheit scales is 5/9 of a kelvin. In a compound unit
# (W/m/K, Btu/hr/ft/degF) a degree is an interval, so there is no offset; the offset of a
# temperature written alone is handled by `ExactAffine` (see `TEMPERATURE_UNITS`).
const RANKINE_DEGREE = Exact(5 // 9) * KELVIN_UNIT

# Heat. The thermochemical calorie is 4.184 J and the International Table calorie is
# 4.1868 J, both exact. The Btu is the heat that raises one pound of water by one rankine
# degree at the specific heat of 1 cal/(g K) of its calorie, so each Btu follows from its
# calorie, the pound and the rankine degree (the International Table Btu is 1055.05585262 J).
const CALORIE = Exact(4184 // 1000) * JOULE
const CALORIE_IT = Exact(41868 // 10000) * JOULE
const BTU_IT = CALORIE_IT / (GRAM * KELVIN_UNIT) * POUND_MASS * RANKINE_DEGREE
const BTU_TH = CALORIE / (GRAM * KELVIN_UNIT) * POUND_MASS * RANKINE_DEGREE

const SYMBOLS = Dict{String,ExactUnit}(
    "m" => METRE,
    "g" => GRAM,
    "s" => SECOND,
    "K" => KELVIN_UNIT,
    "mol" => MOLE,
    "A" => AMPERE,
    "N" => NEWTON,
    "Pa" => PASCAL,
    "J" => JOULE,
    "W" => WATT,
    "S" => SIEMENS,
    "bar" => BAR,
    "atm" => ATMOSPHERE,
    "psi" => PSI,
    "torr" => TORR,
    "Torr" => TORR,
    "mmHg" => MMHG,
    "inch" => INCH,
    "ft" => FOOT,
    "in" => INCH,
    "yd" => YARD,
    "lb" => POUND_MASS,
    "lbf" => POUND_FORCE,
    "min" => MINUTE,
    "h" => HOUR,
    "hr" => HOUR,
    "day" => DAY,
    "L" => LITRE,
    "l" => LITRE,
    "gal" => GALLON_US,
    "P" => POISE,
    "St" => STOKES,
    "cal" => CALORIE,
    "cal_th" => CALORIE,
    "cal_IT" => CALORIE_IT,
    "Btu" => BTU_IT,
    "BTU" => BTU_IT,
    "btu" => BTU_IT,
    "Btu_IT" => BTU_IT,
    "Btu_th" => BTU_TH,
)

const PREFIXES = Dict{Char,Exact}(
    'G' => Exact(10^9),
    'M' => Exact(10^6),
    'k' => Exact(10^3),
    'c' => Exact(1 // 100),
    'd' => Exact(1 // 10),
    'm' => Exact(1 // 1000),
    'u' => Exact(1 // 10^6),
    'µ' => Exact(1 // 10^6),
)

# ----------------------------------------------------------------------------------
# Text -> ExactUnit
# ----------------------------------------------------------------------------------

function lookup_symbol(name::AbstractString)
    unit = get(SYMBOLS, name, nothing)
    unit === nothing || return unit
    if !isempty(name)
        prefix = get(PREFIXES, first(name), nothing)
        rest = SubString(name, nextind(name, 1))
        unit = prefix === nothing ? nothing : get(SYMBOLS, rest, nothing)
        unit === nothing || return prefix * unit
    end
    throw(ArgumentError("unknown unit symbol \"$name\""))
end

function token_unit(token::AbstractString)
    token == "1" && return ExactUnit(1)
    last_letter = findlast(!isdigit, token)
    last_letter === nothing && throw(ArgumentError("cannot read \"$token\" as a unit"))
    cut = nextind(token, last_letter)
    name = SubString(token, 1, last_letter)
    power = cut > ncodeunits(token) ? 1 : parse(Int, SubString(token, cut))
    return lookup_symbol(name)^power
end

# A small recursive-descent reader for unit expressions:
#   expr := term { ('*' | '/' | space) term }       left to right, so W/m/K is W/(m K)
#   term := ('(' expr ')' | symbol) [ '^' [sign] digits ]
mutable struct UnitReader
    text::String
    i::Int
end

const UNIT_SEPARATORS = (' ', '\t', '*', '/', '(', ')', '^', '·', '⋅')

function peek_char(r::UnitReader)
    return r.i > ncodeunits(r.text) ? nothing : r.text[r.i]
end

function skip_space!(r::UnitReader)
    while (c = peek_char(r)) !== nothing && isspace(c)
        r.i = nextind(r.text, r.i)
    end
    return nothing
end

function read_term!(r::UnitReader)
    skip_space!(r)
    c = peek_char(r)
    if c == '('
        r.i = nextind(r.text, r.i)
        unit = read_expr!(r)
        skip_space!(r)
        peek_char(r) == ')' ||
            throw(ArgumentError("unbalanced parentheses in \"$(r.text)\""))
        r.i = nextind(r.text, r.i)
    else
        start = r.i
        while (d = peek_char(r)) !== nothing && !(d in UNIT_SEPARATORS)
            r.i = nextind(r.text, r.i)
        end
        unit = token_unit(SubString(r.text, start, prevind(r.text, r.i)))
    end
    if peek_char(r) == '^'
        r.i = nextind(r.text, r.i)
        start = r.i
        peek_char(r) in ('-', '+') && (r.i = nextind(r.text, r.i))
        while (d = peek_char(r)) !== nothing && isdigit(d)
            r.i = nextind(r.text, r.i)
        end
        digits = SubString(r.text, start, prevind(r.text, r.i))
        power = tryparse(Int, digits)
        power === nothing &&
            throw(ArgumentError("cannot read the exponent in \"$(r.text)\""))
        unit = unit^power
    end
    return unit
end

function read_expr!(r::UnitReader)
    result = read_term!(r)
    while true
        skip_space!(r)
        c = peek_char(r)
        (c === nothing || c == ')') && return result
        if c == '/'
            r.i = nextind(r.text, r.i)
            result = result / read_term!(r)
        else
            c in ('*', '·', '⋅') && (r.i = nextind(r.text, r.i))
            result = result * read_term!(r)
        end
    end
end

"""
    parse_exact_unit(text) -> ExactUnit

Read a unit written as in the catalog or as the units packages print it: symbols (with an
SI prefix or without) joined by `*`, `/`, `·` or a space, with integer exponents written
`m3`, `m^3` or `m^-1`, and parentheses (`"kPa*dm3/mol"`, `"mW m^-1 K^-1"`, `"W/(m*K)"`,
`"1/K"`). The operators associate to the left, so `"W/m/K"` is W/(m K).
"""
function parse_exact_unit(text::AbstractString)
    reader = UnitReader(String(text), 1)
    result = read_expr!(reader)
    skip_space!(reader)
    reader.i > ncodeunits(reader.text) ||
        throw(ArgumentError("cannot read \"$text\" as a unit"))
    return result
end

# ----------------------------------------------------------------------------------
# Affine conversions
# ----------------------------------------------------------------------------------

"`y = scale * x + offset`, exact."
struct ExactAffine
    scale::Exact
    offset::Exact
end

ExactAffine(scale::Real) = ExactAffine(Exact(scale), Exact(0))

(a::ExactAffine)(x::Real) = a.scale * x + a.offset

"First `g`, then `f`."
Base.:∘(f::ExactAffine, g::ExactAffine) =
    ExactAffine(f.scale * g.scale, f.scale * g.offset + f.offset)

Base.inv(a::ExactAffine) = ExactAffine(inv(a.scale), -a.offset / a.scale)

"The same conversion for a difference of two values: only the scale, never the offset."
difference(a::ExactAffine) = ExactAffine(a.scale, Exact(0))

"The same conversion with `Float64` constants, each rounded once from the exact value."
struct FloatAffine
    scale::Float64
    offset::Float64
end

FloatAffine(a::ExactAffine) = FloatAffine(Float64(a.scale), Float64(a.offset))

@inline (a::FloatAffine)(x::Float64) = muladd(x, a.scale, a.offset)

# ----------------------------------------------------------------------------------
# Temperature scales
# ----------------------------------------------------------------------------------

# One definition per scale; the names of a scale are aliases and nothing else. A scale is
# an affine map to kelvin when it is written alone (a temperature) and a degree, an
# interval without offset, inside a compound unit (W/m/K, Btu/hr/ft/degF). The fahrenheit
# scale is the rankine scale shifted by 459.67 degrees, and 0 degC is 273.15 K.
const TEMPERATURE_SCALES = (
    (names = ("K",), to_kelvin = ExactAffine(1), degree = KELVIN_UNIT),
    (
        names = ("°C", "degC", "℃"),
        to_kelvin = ExactAffine(Exact(1), Exact(27315 // 100)),
        degree = KELVIN_UNIT,
    ),
    (
        names = ("°F", "degF", "℉"),
        to_kelvin = ExactAffine(
            RANKINE_DEGREE.scale,
            RANKINE_DEGREE.scale * Exact(45967 // 100),
        ),
        degree = RANKINE_DEGREE,
    ),
    (
        names = ("°R", "degR", "°Ra", "Ra"),
        to_kelvin = ExactAffine(RANKINE_DEGREE.scale),
        degree = RANKINE_DEGREE,
    ),
)

for scale in TEMPERATURE_SCALES, name in scale.names
    SYMBOLS[name] = scale.degree
end

# ----------------------------------------------------------------------------------
# Exact application to a number
# ----------------------------------------------------------------------------------

# A finite float as the exact rational it is (a float is an integer times a power of two).
function exact_value(x::Real)
    x isa Integer && return Exact(x)
    x isa Rational && return Exact(x)
    isfinite(x) || throw(InexactError(:Exact, Exact, x))
    iszero(x) && return Exact(0)
    mantissa = Int128(ldexp(significand(x), 52))
    power = exponent(x) - 52
    if power >= 0
        power <= 73 || throw(OverflowError("the number is too large for Exact"))
        return Exact(mantissa << power)
    end
    -power <= 126 || throw(OverflowError("the number is too small for Exact"))
    return mantissa // (Int128(1) << -power)
end

"""
    apply_exact(a::ExactAffine, x::Real) -> Float64

`a(x)` computed in rational arithmetic on the exact value of `x` and rounded once to
`Float64`. It is the conversion of a single number given by the user (a limit, a value with
a unit); if the number does not fit in `Exact`, the `Float64` constants of `a` are used.
"""
function apply_exact(a::ExactAffine, x::Real)
    isfinite(x) || return Float64(x)
    try
        return Float64(a(exact_value(x)))
    catch err
        (err isa OverflowError || err isa InexactError) || rethrow()
        return FloatAffine(a)(Float64(x))
    end
end

# ----------------------------------------------------------------------------------
# Kernels on columns
# ----------------------------------------------------------------------------------

"""
    apply!(dest, src, a::FloatAffine) -> dest

`dest[i] = a.scale * src[i] + a.offset`. The identity is a copy, a pure scale is a single
multiplication and only a scale with an offset uses the fused multiply-add; `dest` may be
`src`. `NaN` stays `NaN`.
"""
function apply!(dest::AbstractVector{Float64}, src::AbstractVector{Float64}, a::FloatAffine)
    axes(dest) == axes(src) ||
        throw(DimensionMismatch("the destination and the source must have the same axes"))
    s, o = a.scale, a.offset
    if o == 0.0
        if s == 1.0
            dest === src || copyto!(dest, src)
        else
            @inbounds @simd for i in eachindex(dest, src)
                dest[i] = src[i] * s
            end
        end
    else
        @inbounds @simd for i in eachindex(dest, src)
            dest[i] = muladd(src[i], s, o)
        end
    end
    return dest
end

apply(src::AbstractVector{Float64}, a::FloatAffine) = apply!(similar(src), src, a)
apply(x::Float64, a::FloatAffine) = a(x)
