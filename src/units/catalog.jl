"""
    UnitSpec(native, unitful, si, to_si)

One entry of the closed unit catalog used by the ThermoML archive.

- `native`: unit string exactly as written in the property name (`"kPa*kg/mol"`).
- `unitful`: the same unit as a string that `Unitful.uparse` understands.
- `si`: the coherent SI unit with the same dimension (`"Pa*kg/mol"`).
- `to_si`: factor that converts a value in `native` into `si`.

Only multiplicative conversions occur in the archive (all temperatures are kelvin), so
no offset is needed.
"""
struct UnitSpec
    native::String
    unitful::String
    si::String
    to_si::Float64
end

# Every unit found in the 11,923 archive files (census of 2026-10). Dimensionless
# properties carry no suffix and are therefore absent from this table.
const UNIT_SPECS = UnitSpec[
    UnitSpec("K", "K", "K", 1.0),
    UnitSpec("kPa", "kPa", "Pa", 1.0e3),
    UnitSpec("kg/m3", "kg/m^3", "kg/m^3", 1.0),
    UnitSpec("Pa*s", "Pa*s", "Pa*s", 1.0),
    UnitSpec("m/s", "m/s", "m/s", 1.0),
    UnitSpec("N/m", "N/m", "N/m", 1.0),
    UnitSpec("S/m", "S/m", "S/m", 1.0),
    UnitSpec("m2/s", "m^2/s", "m^2/s", 1.0),
    UnitSpec("W/m/K", "W/m/K", "W/m/K", 1.0),
    UnitSpec("kJ/mol", "kJ/mol", "J/mol", 1.0e3),
    UnitSpec("J/K/mol", "J/K/mol", "J/K/mol", 1.0),
    UnitSpec("J/K/kg", "J/K/kg", "J/K/kg", 1.0),
    UnitSpec("J/K/m3", "J/K/m^3", "J/K/m^3", 1.0),
    UnitSpec("m3/mol", "m^3/mol", "m^3/mol", 1.0),
    UnitSpec("m3/kg", "m^3/kg", "m^3/kg", 1.0),
    UnitSpec("m6/mol2", "m^6/mol^2", "m^6/mol^2", 1.0),
    UnitSpec("mol/kg", "mol/kg", "mol/kg", 1.0),
    UnitSpec("mol/m3", "mol/m^3", "mol/m^3", 1.0),
    UnitSpec("mol/dm3", "mol/dm^3", "mol/m^3", 1.0e3),
    UnitSpec("S*m2/mol", "S*m^2/mol", "S*m^2/mol", 1.0),
    UnitSpec("1/K", "K^-1", "K^-1", 1.0),
    UnitSpec("1/kPa", "kPa^-1", "Pa^-1", 1.0e-3),
    UnitSpec("kPa/K", "kPa/K", "Pa/K", 1.0e3),
    UnitSpec("K/kPa", "K/kPa", "K/Pa", 1.0e-3),
    UnitSpec("kPa*kg/mol", "kPa*kg/mol", "Pa*kg/mol", 1.0e3),
    UnitSpec("kPa*dm3/mol", "kPa*dm^3/mol", "Pa*m^3/mol", 1.0),
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
