# Unitful as a backend of the units protocol (see `src/units/backend.jl`).
module ThermophysicalDBUnitfulExt

using Unitful: Unitful, @u_str
using ThermophysicalDB: ThermophysicalDB
const T = ThermophysicalDB

struct UnitfulBackend end

function __init__()
    return T.register_unit_backend!(Unitful, UnitfulBackend())
end

# output
T.parse_unit(::UnitfulBackend, text::AbstractString) = Unitful.uparse(text)
T.attach_unit(::UnitfulBackend, column::AbstractVector{Float64}, unit) = column .* unit

# input. The package reads the unit as text and converts exactly (`quantity_parts`); Unitful
# converts only the units whose symbol the exact parser does not know.
function T.quantity_parts(backend::UnitfulBackend, x::Unitful.AbstractQuantity)
    return (Unitful.ustrip(x), T.unit_text(backend, Unitful.unit(x)))
end

# a value (degC is converted with its offset) ...
T.package_native_value(
    ::UnitfulBackend,
    x::Unitful.AbstractQuantity,
    ::T.NativeTemperature,
) = Float64(Unitful.ustrip(u"K", x))
T.package_native_value(::UnitfulBackend, x::Unitful.AbstractQuantity, ::T.NativePressure) =
    Float64(Unitful.ustrip(u"kPa", x))
T.package_native_value(::UnitfulBackend, x::Unitful.AbstractQuantity, spec::T.UnitSpec) =
    Float64(Unitful.ustrip(Unitful.uparse(spec.unitful), x))

# ... and a difference (an uncertainty): the scale only, so 0.01 degC is 0.01 K
function difference(x::Unitful.AbstractQuantity, native)
    absolute = Unitful.absoluteunit(Unitful.unit(x))
    return Float64(Unitful.ustrip(native, Unitful.ustrip(x) * absolute))
end
T.package_native_difference(
    ::UnitfulBackend,
    x::Unitful.AbstractQuantity,
    ::T.NativeTemperature,
) = difference(x, u"K")
T.package_native_difference(
    ::UnitfulBackend,
    x::Unitful.AbstractQuantity,
    ::T.NativePressure,
) = difference(x, u"kPa")
T.package_native_difference(
    ::UnitfulBackend,
    x::Unitful.AbstractQuantity,
    spec::T.UnitSpec,
) = difference(x, Unitful.uparse(spec.unitful))

# reference_summary(...; temperature_unit = u"K")
function T.package_convert_native(::UnitfulBackend, x::Float64, ::T.NativeTemperature, to)
    return isfinite(x) ? Float64(Unitful.ustrip(to, x * u"K")) : NaN
end
function T.package_convert_native(::UnitfulBackend, x::Float64, ::T.NativePressure, to)
    return isfinite(x) ? Float64(Unitful.ustrip(to, x * u"kPa")) : NaN
end

# The factor between two units of a property: a Rational when both units are exact.
function T.unit_factor(::UnitfulBackend, from, to)
    factor = Unitful.ustrip(Unitful.uconvert(to, (1 // 1) * from))
    iszero(Unitful.ustrip(Unitful.uconvert(to, (0 // 1) * from))) || throw(
        ArgumentError("the unit $(to) has an offset, so it cannot convert a property"),
    )
    return factor
end


# Unitful prints a unit as "mW m^-1 K^-1", which the exact parser of the package reads.
function T.unit_text(::UnitfulBackend, unit::Unitful.Units)
    text = string(unit)
    return isempty(text) ? nothing : text
end

end
