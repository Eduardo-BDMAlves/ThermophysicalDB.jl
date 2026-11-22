# Axis labels in LaTeX: the symbol of a property, its unit and the way they are put together. The
# functions return the text between the dollar signs; the plotting extensions wrap it.

const USER_SYMBOLS = Dict{String,String}()

# The TeX of a unit that has a symbol of its own (the rest are written in roman type).
const UNIT_TEX = Dict{String,String}(
    "degC" => raw"{}^{\circ}\mathrm{C}",
    "°C" => raw"{}^{\circ}\mathrm{C}",
    "degF" => raw"{}^{\circ}\mathrm{F}",
    "°F" => raw"{}^{\circ}\mathrm{F}",
    "degR" => raw"{}^{\circ}\mathrm{R}",
    "ohm" => raw"\Omega",
    "Ohm" => raw"\Omega",
    "-" => "-",
)

const LABEL_FORMATS = (:square, :round, :slash, :slashsquare)

"""
    register_symbol!(property, tex)

Give a property the LaTeX symbol that its axis labels use (`register_symbol!("Viscosity", raw"\\mu")`).
The properties of the ThermoML schema have one already ([`property_symbol`](@ref)); this
replaces it or adds a property that the schema does not have.
"""
function register_symbol!(property::AbstractString, tex::AbstractString)
    USER_SYMBOLS[String(strip(property))] = String(tex)
    return nothing
end

"""
    property_symbol(property) -> Union{String,Nothing}

The LaTeX symbol that axis labels use for a property (`"Mass density"` gives `"\\rho"`,
`"Specific heat capacity at constant pressure"` gives `"c_p"`), or `nothing` when it has none
(the label then uses the name of the property). Symbols that you registered with
[`register_symbol!`](@ref) come first.
"""
function property_symbol(property::AbstractString)
    name = String(strip(property))
    return get(USER_SYMBOLS, name, get(PROPERTY_SYMBOLS, name, nothing))
end

# A name with spaces and signs as TeX in roman type.
function roman_text(text::AbstractString)
    clean = replace(String(text), r"[{}_^\\$%&#~]" => "")
    return string(raw"\mathrm{", replace(strip(clean), ' ' => raw"\ "), "}")
end

# One term of a unit: a name and an exponent, "m3" -> m^{3}, "K" -> K.
function unit_term(token::AbstractString, sign::Int)
    m = match(r"^([^\d^\-]+)\^?(-?\d+)?$", token)
    m === nothing && return nothing
    name = String(m[1]::SubString{String})
    exponent = m[2]
    power = exponent === nothing ? 1 : parse(Int, exponent)
    power *= sign
    base = get(UNIT_TEX, name, string(raw"\mathrm{", name, "}"))
    power == 1 && return base
    return string(base, "^{", power, "}")
end

"""
    tex_unit(unit) -> String

A unit written like the archive does (`"kg/m3"`, `"J/K/mol"`, `"kPa*kg/mol"`) as TeX in roman
type with negative powers (`\\mathrm{kg}\\,\\mathrm{m}^{-3}`). In `a/b/c` everything after a slash
is in the denominator, as the archive writes it. A unit with parentheses or a form that is not
recognised is written as it is, in roman type; `""` gives `""`.
"""
function tex_unit(unit::AbstractString)
    text = String(strip(unit))
    isempty(text) && return ""
    haskey(UNIT_TEX, text) && return UNIT_TEX[text]
    (occursin('(', text) || occursin(')', text)) && return roman_text(text)
    terms = String[]
    buffer = IOBuffer()
    sign = 1
    ok = true
    flush_term!(next_sign) = begin
        token = String(take!(buffer))
        if !isempty(token) && token != "1"
            term = unit_term(token, sign)
            term === nothing ? (ok = false) : push!(terms, term)
        end
        sign = next_sign
    end
    for c in text
        if c == '/'
            flush_term!(-1)
        elseif c == '*' || c == '·' || c == ' ' || c == '⋅'
            flush_term!(1)
        else
            print(buffer, c)
        end
    end
    flush_term!(1)
    (ok && !isempty(terms)) || return roman_text(text)
    return join(terms, raw"\,")
end

"""
    axis_label(symbol, unit; format = :square) -> String

The LaTeX of an axis label: the `symbol` and the `unit` written as the archive gives it, put
together as `format` says: `:square` (`\\rho\\;[\\mathrm{kg}\\,\\mathrm{m}^{-3}]`, the default),
`:round` (`(...)`), `:slash` (`\\rho\\;/\\;\\mathrm{kg}\\,\\mathrm{m}^{-3}`) or a function of the
symbol and of the TeX of the unit that returns the text. A property without a unit has the
symbol alone; `"-"` is written as `[-]`.
"""
function axis_label(symbol::AbstractString, unit::AbstractString; format = :square)
    return join_label(symbol, tex_unit(unit), format)
end

# The symbol and the TeX of a unit, put together as the format says.
function join_label(symbol::AbstractString, u::AbstractString, format)
    isempty(u) && return String(symbol)
    format isa Function && return String(format(String(symbol), u))
    format === :square && return string(symbol, raw"\;[", u, "]")
    format === :round && return string(symbol, raw"\;(", u, ")")
    format === :slash && return string(symbol, raw"\;/\;", u)
    format === :slashsquare && return string(symbol, raw"\;/\;[", u, "]")
    throw(
        ArgumentError(
            "unitformat must be one of $(LABEL_FORMATS) or a function, got $(repr(format))",
        ),
    )
end

"""
    property_label(property, unit; format = :square) -> String

The axis label of a property: its symbol ([`property_symbol`](@ref)) or, when it has none, its
name in roman type, followed by the unit as [`axis_label`](@ref) puts it.
"""
function property_label(property::AbstractString, unit::AbstractString; format = :square)
    symbol = property_symbol(property)
    return axis_label(symbol === nothing ? roman_text(property) : symbol, unit; format)
end
