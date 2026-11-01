# FlexUnits as a backend of the units protocol (see `src/units/backend.jl`).
#
# FlexUnits converts to SI when a quantity is made. Its affine units (degC) are applied at
# that moment, so a difference written in degC cannot be told from a temperature: give an
# uncertainty of temperature in kelvin.
module ThermophysicalDBFlexUnitsExt

using FlexUnits: FlexUnits
using ThermophysicalDB: ThermophysicalDB
const T = ThermophysicalDB
const Registry = FlexUnits.UnitRegistry
using FlexUnits.UnitRegistry: @u_str

struct FlexUnitsBackend end

function __init__()
    return T.register_unit_backend!(FlexUnits, FlexUnitsBackend())
end

# output
T.parse_unit(::FlexUnitsBackend, text::AbstractString) = Registry.uparse(text)
T.attach_unit(::FlexUnitsBackend, column::AbstractVector{Float64}, unit) = column .* unit

# input: `ustrip(unit, x)` checks the dimension and applies the scale and the offset
const KELVIN = u"K"
const KILOPASCAL = u"kPa"

T.package_native_value(::FlexUnitsBackend, x::FlexUnits.Quantity, ::T.NativeTemperature) =
    Float64(FlexUnits.ustrip(KELVIN, x))
T.package_native_value(::FlexUnitsBackend, x::FlexUnits.Quantity, ::T.NativePressure) =
    Float64(FlexUnits.ustrip(KILOPASCAL, x))
T.package_native_value(::FlexUnitsBackend, x::FlexUnits.Quantity, spec::T.UnitSpec) =
    Float64(FlexUnits.ustrip(Registry.uparse(spec.unitful), x))

T.package_native_difference(
    b::FlexUnitsBackend,
    x::FlexUnits.Quantity,
    kind::T.QuantityKind,
) = T.package_native_value(b, x, kind)

# reference_summary(...; temperature_unit = FlexUnits.UnitRegistry.uparse("MPa"))
function T.package_convert_native(::FlexUnitsBackend, x::Float64, ::T.NativeTemperature, to)
    return isfinite(x) ? Float64(FlexUnits.ustrip(to, x * KELVIN)) : NaN
end
function T.package_convert_native(::FlexUnitsBackend, x::Float64, ::T.NativePressure, to)
    return isfinite(x) ? Float64(FlexUnits.ustrip(to, x * KILOPASCAL)) : NaN
end


# FlexUnits strips to a unit with the dimension checked; the offset test excludes degC.
function T.unit_factor(::FlexUnitsBackend, from, to)
    factor = Float64(FlexUnits.ustrip(to, 1.0 * from))
    iszero(Float64(FlexUnits.ustrip(to, 0.0 * from))) || throw(
        ArgumentError("the unit $(to) has an offset, so it cannot convert a property"),
    )
    return factor
end

end
