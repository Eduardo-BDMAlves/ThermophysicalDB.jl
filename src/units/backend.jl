# The protocol between the package and the packages of units (Unitful, DynamicQuantities,
# FlexUnits, ...).
#
# The package never stores a quantity. A table holds `Float64` in the native units of the
# catalog (`src/units/catalog.jl`): temperature in K, pressure in kPa, each property in the
# unit written in its name. Quantities exist only at the boundary:
#
#   input   a bound of `points`, a term of `set_uncertainty!`: dispatch on the type of the
#           argument, so a quantity of any loaded package is recognised without a keyword;
#   output  `table(view; quantities = Unitful)` and similar: a backend chosen by the user.
#
# A backend is added by a package extension (a file in `ext/`) that implements the
# functions below. Nothing here is exported and nothing of it appears in the interface of
# the package: the user only loads the units package they prefer.
#
#   register_unit_backend!(Module, backend)   once, in the `__init__` of the extension
#   parse_unit(backend, text)                 a unit from a string such as "kPa" or "kg/m^3"
#   attach_unit(backend, column, unit)        a `Vector{Float64}` and a unit become a column
#                                             of quantities (one conversion per column)
#   quantity_parts(backend, x)                (optional) `(number, unit_text)` of a quantity,
#                                             with the unit as text the exact parser reads; the
#                                             package then converts the input by itself,
#                                             exactly (a limit of `points`, a term of
#                                             `set_uncertainty!`)
#   package_native_value(backend, x, kind)    what the package itself converts, when its unit is
#   package_native_difference(...)            not understood by the exact parser (or when the
#                                             package keeps no text, as the ones that store SI)
#   unit_factor(backend, from, to)            the number that turns a value in the unit `from`
#                                             into a value in the unit `to` (both parsed by
#                                             the backend): a `Rational` when the package
#                                             is exact, a `Float64` otherwise; it throws if
#                                             the dimensions differ or if `to` has an offset
#   unit_text(backend, unit)                  (optional) the unit as text that the exact parser
#                                             of the package can read ("mW m^-1 K^-1"), or
#                                             `nothing`; when the text is understood the
#                                             package converts by itself, exactly, and the
#                                             backend only receives the result
#   package_convert_native(backend, x, kind, to)   (optional) a native number in a unit object of
#                                             the backend, for `reference_summary`, when the
#                                             unit is not understood by the exact parser
#
# `kind` is `NativeTemperature()`, `NativePressure()` or a `UnitSpec` of the catalog. The
# first two are singletons, so the native unit is known to the compiler.

"A temperature, whose native unit is kelvin."
struct NativeTemperature end

"A pressure, whose native unit is kilopascal."
struct NativePressure end

"The kinds a quantity of the user can be a measure of (the property uses a `UnitSpec`)."
const QuantityKind = Union{NativeTemperature,NativePressure,UnitSpec}

# ----------------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------------

"""
    native_value(x, kind) -> Float64

`x` as a `Float64` in the native unit of `kind`. A plain number is taken to be in that unit
already; a quantity is converted, and its dimension is checked by the units package.
"""
native_value(x::Real, ::Any) = Float64(x)

# A quantity of a units package. The conversion is done here, exactly, when the package
# gives the unit as text that the exact parser reads; otherwise the package converts.
function native_value(x, kind)
    backend = backend_of(x)
    value = exact_native(backend, x, kind, false)
    return value === nothing ? package_native_value(backend, x, kind) : value
end

"""
    native_difference(x, kind) -> Float64

The same as [`native_value`](@ref) for a difference of two values, such as an uncertainty.
It converts the scale only: an uncertainty of 0.01 °C is 0.01 K, whereas the temperature
0.01 °C is 273.16 K.
"""
native_difference(x::Real, ::Any) = Float64(x)

function native_difference(x, kind)
    backend = backend_of(x)
    value = exact_native(backend, x, kind, true)
    return value === nothing ? package_native_difference(backend, x, kind) : value
end

quantity_parts(backend, x) = nothing

function package_native_value(backend, x, kind)
    throw(ArgumentError("the backend $(typeof(backend)) cannot convert $(typeof(x))"))
end
package_native_difference(backend, x, kind) = package_native_value(backend, x, kind)
function package_convert_native(backend, x, kind, to)
    throw(ArgumentError("the backend $(typeof(backend)) cannot convert to $(typeof(to))"))
end

# `unit -> native` of the unit written as `text`, for a quantity of the given kind; `nothing`
# when the text has a symbol the exact parser does not know. A temperature scale written
# alone (degC) is affine, also for a property that is a temperature.
quantity_affine(kind::Union{NativeTemperature,NativePressure}, text) =
    try_named_unit(kind, text)
function quantity_affine(spec::UnitSpec, text::AbstractString)
    native = parse_exact_unit(spec.native)
    named = get(TEMPERATURE_UNITS, strip(text), nothing)
    if named !== nothing && native.dim == KELVIN_UNIT.dim
        return ExactAffine(inv(native.scale)) ∘ named
    end
    unit = try
        parse_exact_unit(text)
    catch err
        err isa ArgumentError ? (return nothing) : rethrow()
    end
    unit.dim == native.dim || throw(
        ArgumentError(
            "\"$text\" and the unit of the property (\"$(spec.native)\") are not units " *
            "of the same quantity",
        ),
    )
    return ExactAffine(unit.scale / native.scale)
end

function exact_native(backend, x, kind, difference::Bool)
    parts = quantity_parts(backend, x)
    parts === nothing && return nothing
    number, text = parts
    text === nothing && return nothing
    affine = quantity_affine(kind, text)
    affine === nothing && return nothing
    return apply_exact(difference ? difference_of(affine) : affine, number)
end
difference_of(a::ExactAffine) = ExactAffine(a.scale, Exact(0))

is_quantity(x) = !(x isa Real) && x !== nothing

# ----------------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------------

const UNIT_BACKENDS = Dict{Module,Any}()

"""
    register_unit_backend!(mod, backend)

Called by the extension of a units package, in its `__init__`: `mod` is the module the
user names in `quantities = mod`.
"""
function register_unit_backend!(mod::Module, backend)
    UNIT_BACKENDS[mod] = backend
    return nothing
end

"The backend named by the user: a module (`Unitful`), its name as a `Symbol`, or `nothing`."
unit_backend(::Nothing) = nothing
function unit_backend(mod::Module)
    backend = get(UNIT_BACKENDS, mod, nothing)
    backend === nothing && throw(
        ArgumentError(
            "there is no extension for $(nameof(mod)) in this session; the packages with " *
            "one are: " *
            (
                isempty(UNIT_BACKENDS) ? "none loaded" :
                join(nameof.(keys(UNIT_BACKENDS)), ", ")
            ),
        ),
    )
    return backend
end
function unit_backend(name::Symbol)
    for (mod, backend) in UNIT_BACKENDS
        nameof(mod) === name && return backend
    end
    throw(
        ArgumentError(
            "the units package $name is not loaded (or has no extension); load it with " *
            "`using $name` first",
        ),
    )
end

function parse_unit(backend, text::AbstractString)
    throw(ArgumentError("the backend $(typeof(backend)) does not implement parse_unit"))
end

unit_text(backend, unit) = nothing

function unit_factor(backend, from, to)
    throw(ArgumentError("the backend $(typeof(backend)) does not implement unit_factor"))
end

function attach_unit(backend, column::AbstractVector{Float64}, unit)
    throw(ArgumentError("the backend $(typeof(backend)) does not implement attach_unit"))
end

# ----------------------------------------------------------------------------------
# Units written by name (reference_summary), without any units package
# ----------------------------------------------------------------------------------

# Each unit maps to the native unit of its kind: kelvin = scale * value + offset, and
# kilopascal = scale * value. The constants are exact rationals built from the definitions
# (see `src/units/exact.jl`): the rankine is 5/9 K, the fahrenheit scale is the rankine scale
# shifted by 459.67 degR, the psi is the pound-force per square inch with the pound and the
# standard gravity exact, and so on.
const TEMPERATURE_UNITS = Dict{String,ExactAffine}(
    name => scale.to_kelvin for scale in TEMPERATURE_SCALES for name in scale.names
)

function pressure_affine(name::String)
    unit = parse_exact_unit(name)
    unit.dim == PASCAL.dim || throw(ArgumentError("\"$name\" is not a pressure"))
    return ExactAffine(unit.scale / 1000)
end

const PRESSURE_UNITS = Dict{String,ExactAffine}(
    name => pressure_affine(name) for name in
    ("Pa", "kPa", "MPa", "GPa", "mbar", "bar", "atm", "psi", "torr", "Torr", "mmHg")
)

named_units(::NativeTemperature) = TEMPERATURE_UNITS
named_units(::NativePressure) = PRESSURE_UNITS

"""
    convert_native(x, kind, to) -> Float64

`x`, in the native unit of `kind`, expressed in `to`. `to` is a name written as text or as a
`Symbol` (`"MPa"`, `:bar`, `"°C"`; see `TEMPERATURE_UNITS` and `PRESSURE_UNITS`), or a unit
object of a units package whose extension defines the method. Non-finite values follow
IEEE arithmetic (`NaN` stays `NaN`).
"""
function convert_native(x::Float64, kind::Union{NativeTemperature,NativePressure}, to)
    backend = backend_of(to)
    text = unit_text(backend, to)
    affine = text === nothing ? nothing : try_named_unit(kind, text)
    affine === nothing && return package_convert_native(backend, x, kind, to)
    return FloatAffine(inv(affine))(x)
end
convert_native(x::Float64, kind, to::Symbol) = convert_native(x, kind, String(to))
function convert_native(
    x::Float64,
    kind::Union{NativeTemperature,NativePressure},
    to::AbstractString,
)
    return unit_affine(kind, native_name(kind), to)(x)
end

native_name(::NativeTemperature) = "K"
native_name(::NativePressure) = "kPa"

native_dimension(::NativeTemperature) = KELVIN_UNIT.dim
native_dimension(::NativePressure) = PASCAL.dim
quantity_name(::NativeTemperature) = "temperature"
quantity_name(::NativePressure) = "pressure"
native_scale(::NativeTemperature) = Exact(1)
native_scale(::NativePressure) = Exact(1000)

# The conversion `unit -> native` of a unit written as text, or `nothing` when the text is
# not a unit the package can read. The names with an offset (degC, degF) come from the
# table; anything else is read by the exact parser, so every prefix and every compound unit
# of the right dimension is accepted (mK, mbar, N/m2, lbf/in2, ...).
function try_named_unit(kind, name::AbstractString)
    table = named_units(kind)
    haskey(table, name) && return table[name]
    unit = try
        parse_exact_unit(name)
    catch err
        err isa ArgumentError ? (return nothing) : rethrow()
    end
    unit.dim == native_dimension(kind) ||
        throw(ArgumentError("\"$name\" is not a unit of $(quantity_name(kind))"))
    return ExactAffine(unit.scale / native_scale(kind))
end

function named_unit(kind, name::AbstractString)
    unit = try_named_unit(kind, name)
    unit === nothing && throw(
        ArgumentError(
            "unknown unit \"$name\"; the names with an offset are: " *
            join(sort!(collect(keys(named_units(kind)))), ", ") *
            ", and any prefixed or compound unit of the same quantity is read as well",
        ),
    )
    return unit
end

"""
    unit_affine(kind, from, to) -> FloatAffine

The conversion from the unit named `from` to the one named `to`, both of the same `kind`.
It is composed in exact rationals (`to` after `from`) and rounded once to `Float64`, so a
chain such as degR -> degF -> degC -> K has the same constants as the direct conversion.
"""
function unit_affine(kind::Union{NativeTemperature,NativePressure}, from, to)
    return FloatAffine(inv(named_unit(kind, to)) ∘ named_unit(kind, from))
end

"""
    convert_unit(x, kind, from, to)
    convert_unit!(dest, x, kind, from, to)

`x` (a number or a `Vector{Float64}`) in the unit named `from`, expressed in the unit named
`to`. On a vector the constants are computed once and the loop is a single pass.
"""
convert_unit(x::Float64, kind, from, to) = unit_affine(kind, from, to)(x)
function convert_unit(x::AbstractVector{Float64}, kind, from, to)
    return apply(x, unit_affine(kind, from, to))
end
function convert_unit!(
    dest::AbstractVector{Float64},
    x::AbstractVector{Float64},
    kind,
    from,
    to,
)
    return apply!(dest, x, unit_affine(kind, from, to))
end

"`x`, in the unit named `from`, as a number in the native unit of `kind`."
to_native(x, kind, from) = convert_unit(x, kind, from, native_name(kind))

"The native values `x` in the unit named `to`; a vector is converted in one pass."
function convert_native(
    x::AbstractVector{Float64},
    kind::Union{NativeTemperature,NativePressure},
    to::Union{AbstractString,Symbol},
)
    return convert_unit(x, kind, native_name(kind), String(to))
end

# ----------------------------------------------------------------------------------
# Units of a property: any unit, by name or as an object of a units package
# ----------------------------------------------------------------------------------

"""
    text_factor(from, to) -> Rational{Int128}

The exact number that turns a value written in the unit `from` into a value in the unit `to`,
both given as text (`"W/m/K"`, `"mW/m/K"`, `"Btu/hr/ft/degF"`). The units are composed from
symbols with SI prefixes, so `"mbar"`, `"kJ/mol"` and `"cP"` are understood, and the
dimensions are compared before anything is converted. A temperature scale with an offset
(`"degC"`, `"degF"`) is only accepted inside a compound unit, where it is a degree
(an interval), never as the unit of a temperature itself.
"""
function text_factor(from::AbstractString, to::AbstractString)
    a, b = parse_exact_unit(from), parse_exact_unit(to)
    a.dim == b.dim || throw(
        ArgumentError(
            "cannot express \"$from\" in \"$to\": they are not units of the same quantity",
        ),
    )
    named = get(TEMPERATURE_UNITS, strip(to), nothing)
    named !== nothing &&
        !iszero(named.offset) &&
        throw(
            ArgumentError(
                "\"$to\" has an offset, so it cannot convert a property; use it only inside " *
                "a compound unit, or ask for a temperature in it through the temperature unit",
            ),
        )
    return a.scale / b.scale
end

# `nothing` when the text has a symbol the package does not know (then the units package
# converts); an error when it is a unit of another quantity.
function try_text_factor(from::AbstractString, to::AbstractString)
    try
        parse_exact_unit(to)
    catch err
        err isa ArgumentError ? (return nothing) : rethrow()
    end
    return text_factor(from, to)
end

"""
    backend_of(unit)

The backend that owns a unit object, found by the module the type of the object comes from.
"""
function backend_of(unit)
    mod = parentmodule(typeof(unit))
    backend = get(UNIT_BACKENDS, mod, nothing)
    backend === nothing && throw(
        ArgumentError(
            "cannot use a value of type $(typeof(unit)) here; load the package of units that " *
            "it comes from (Unitful, DynamicQuantities or FlexUnits) so that its extension " *
            "is available, or give a plain number in the native unit (or the unit as text)",
        ),
    )
    return backend
end

# The backend may throw its own errors (DimensionError, ...); the user sees one kind.
function backend_factor(backend, from, to)
    try
        return unit_factor(backend, from, to)
    catch err
        err isa ArgumentError && rethrow()
        throw(
            ArgumentError(
                "cannot express the unit of the property in $(to): " *
                sprint(showerror, err),
            ),
        )
    end
end
