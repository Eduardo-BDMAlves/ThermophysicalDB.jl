# DynamicQuantities as a backend of the units protocol (see `src/units/backend.jl`).
#
# DynamicQuantities converts to SI when a quantity is made (`5u"kPa"` holds 5000 Pa), and
# it has no affine units. A column of quantities is a `QuantityArray`: one array of
# numbers and one set of dimensions for the whole column.
module ThermophysicalDBDynamicQuantitiesExt

using DynamicQuantities: DynamicQuantities as DQ, @u_str
using ThermophysicalDB: ThermophysicalDB
const T = ThermophysicalDB

struct DynamicQuantitiesBackend end

function __init__()
    return T.register_unit_backend!(DQ, DynamicQuantitiesBackend())
end

# output
T.parse_unit(::DynamicQuantitiesBackend, text::AbstractString) = DQ.uparse(text)
function T.attach_unit(::DynamicQuantitiesBackend, column::AbstractVector{Float64}, unit)
    return DQ.QuantityArray(column .* DQ.ustrip(unit), DQ.dimension(unit))
end

# input: SI numbers divided by the factor of the native unit, after the dimension check
function strip_to(x::DQ.AbstractQuantity, unit)
    DQ.dimension(x) == DQ.dimension(unit) || throw(DQ.DimensionError(x, unit))
    return Float64(DQ.ustrip(x) / DQ.ustrip(unit))
end
const KELVIN = u"K"
const KILOPASCAL = u"kPa"

T.package_native_value(
    ::DynamicQuantitiesBackend,
    x::DQ.AbstractQuantity,
    ::T.NativeTemperature,
) = strip_to(x, KELVIN)
T.package_native_value(
    ::DynamicQuantitiesBackend,
    x::DQ.AbstractQuantity,
    ::T.NativePressure,
) = strip_to(x, KILOPASCAL)
T.package_native_value(
    ::DynamicQuantitiesBackend,
    x::DQ.AbstractQuantity,
    spec::T.UnitSpec,
) = strip_to(x, DQ.uparse(spec.unitful))

# there are no affine units, so a difference converts like a value
T.package_native_difference(
    b::DynamicQuantitiesBackend,
    x::DQ.AbstractQuantity,
    kind::T.QuantityKind,
) = T.package_native_value(b, x, kind)

# reference_summary(...; temperature_unit = u"K")
function T.package_convert_native(
    ::DynamicQuantitiesBackend,
    x::Float64,
    ::T.NativeTemperature,
    to,
)
    return isfinite(x) ? Float64(x * DQ.ustrip(KELVIN) / DQ.ustrip(checked(to, KELVIN))) :
           NaN
end
function T.package_convert_native(
    ::DynamicQuantitiesBackend,
    x::Float64,
    ::T.NativePressure,
    to,
)
    return isfinite(x) ?
           Float64(x * DQ.ustrip(KILOPASCAL) / DQ.ustrip(checked(to, KILOPASCAL))) : NaN
end
function checked(to, native)
    DQ.dimension(to) == DQ.dimension(native) || throw(DQ.DimensionError(to, native))
    return to
end


# DynamicQuantities keeps every quantity in SI, so the factor is a ratio of two Float64.
function T.unit_factor(::DynamicQuantitiesBackend, from, to)
    DQ.dimension(from) == DQ.dimension(to) ||
        throw(ArgumentError("the two units are not of the same quantity"))
    return DQ.ustrip(from) / DQ.ustrip(to)
end

end
