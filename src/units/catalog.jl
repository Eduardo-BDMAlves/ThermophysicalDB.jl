"""
    UnitSpec(native, unitful, si)

One entry of the closed unit catalog used by the ThermoML archive.

- `native`: unit string exactly as written in the property name (`"kPa*kg/mol"`).
- `unitful`: the same unit as a string that `Unitful.uparse` understands.
- `si`: the coherent SI unit with the same dimension (`"Pa*kg/mol"`).
- `exact`: the exact factor that converts a value in `native` into `si`, as a rational.
- `to_si`: `exact` rounded once to `Float64`.

The factor is not typed in: it is derived from the two strings with exact rational
arithmetic (`parse_exact_unit`), and the constructor throws if the two units do not have the
same dimension. Only multiplicative conversions occur in the archive (all temperatures are
kelvin), so no offset is needed.
"""
struct UnitSpec
    native::String
    unitful::String
    si::String
    to_si::Float64
    exact::Exact
end

function UnitSpec(native::String, unitful::String, si::String)
    from, to = parse_exact_unit(native), parse_exact_unit(si)
    from.dim == to.dim ||
        throw(ArgumentError("\"$native\" and \"$si\" do not have the same dimension"))
    ratio = from.scale / to.scale
    return UnitSpec(native, unitful, si, Float64(ratio), ratio)
end

# Every unit found in the 11,923 archive files (census of 2026-10). Dimensionless
# properties carry no suffix and are therefore absent from this table.
const UNIT_SPECS = UnitSpec[
    UnitSpec("K", "K", "K"),
    UnitSpec("kPa", "kPa", "Pa"),
    UnitSpec("kg/m3", "kg/m^3", "kg/m^3"),
    UnitSpec("Pa*s", "Pa*s", "Pa*s"),
    UnitSpec("m/s", "m/s", "m/s"),
    UnitSpec("N/m", "N/m", "N/m"),
    UnitSpec("S/m", "S/m", "S/m"),
    UnitSpec("m2/s", "m^2/s", "m^2/s"),
    UnitSpec("W/m/K", "W/m/K", "W/m/K"),
    UnitSpec("kJ/mol", "kJ/mol", "J/mol"),
    UnitSpec("J/K/mol", "J/K/mol", "J/K/mol"),
    UnitSpec("J/K/kg", "J/K/kg", "J/K/kg"),
    UnitSpec("J/K/m3", "J/K/m^3", "J/K/m^3"),
    UnitSpec("m3/mol", "m^3/mol", "m^3/mol"),
    UnitSpec("m3/kg", "m^3/kg", "m^3/kg"),
    UnitSpec("m6/mol2", "m^6/mol^2", "m^6/mol^2"),
    UnitSpec("mol/kg", "mol/kg", "mol/kg"),
    UnitSpec("mol/m3", "mol/m^3", "mol/m^3"),
    UnitSpec("mol/dm3", "mol/dm^3", "mol/m^3"),
    UnitSpec("S*m2/mol", "S*m^2/mol", "S*m^2/mol"),
    UnitSpec("1/K", "K^-1", "K^-1"),
    UnitSpec("1/kPa", "kPa^-1", "Pa^-1"),
    UnitSpec("kPa/K", "kPa/K", "Pa/K"),
    UnitSpec("K/kPa", "K/kPa", "K/Pa"),
    UnitSpec("kPa*kg/mol", "kPa*kg/mol", "Pa*kg/mol"),
    UnitSpec("kPa*dm3/mol", "kPa*dm^3/mol", "Pa*m^3/mol"),
]

const UNIT_CATALOG = Dict{String,UnitSpec}(spec.native => spec for spec in UNIT_SPECS)

"""
    unit_spec(native) -> Union{UnitSpec, Nothing}

Look up a unit string of the archive. Returns `nothing` when it is not catalogued.
"""
unit_spec(native::AbstractString) = get(UNIT_CATALOG, native, nothing)

"""
    split_property_name(name) -> (label, spec)

Split an archive property name such as `"Mass density, kg/m3"` into its label and its
[`UnitSpec`](@ref). The unit is the text after the last `", "`, and it is accepted only
when it is in the catalog. Otherwise (`"Mole fraction"`, `"Refractive index (Na D-line)"`)
the whole name is the label and `spec` is `nothing`, meaning dimensionless.

Callers that must detect uncatalogued units can check whether `spec === nothing` while
`occursin(", ", label)`.
"""
function split_property_name(name::AbstractString)
    range = findlast(", ", name)
    range === nothing && return (name, nothing)
    spec = unit_spec(SubString(name, last(range) + 1))
    spec === nothing && return (name, nothing)
    return (SubString(name, 1, first(range) - 1), spec)
end
