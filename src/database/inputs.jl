# Numbers that a user gives to the databases. A table stores plain `Float64` (temperature in K,
# pressure in kPa, a property in its unit), so the conversion happens once, where a number enters:
# the constructors and the functions that add points. A number can be

# - a plain number: it is already in the unit of the database (or, for the value of a point, in the
#   unit that the point declares);
# - a text with a unit: `"20 degC"`, `"0.01 bar"`, `"2 %"`;
# - a quantity of a units package (Unitful, DynamicQuantities, FlexUnits), when it is loaded.
#
# Nothing here is stored in a struct: the structs keep `Float64`.

# The text of the coherent SI unit of a dimension: a derived unit when there is a name for it.
const SI_NAMES = ("m", "kg", "s", "K", "mol", "A")
const SI_DERIVED =
    (("N", NEWTON.dim), ("Pa", PASCAL.dim), ("J", JOULE.dim), ("W", WATT.dim))

function si_text(dim::DimVector)
    all(iszero, dim) && return ""
    for (name, d) in SI_DERIVED
        d == dim && return name
    end
    up, down = String[], String[]
    for (i, e) in enumerate(dim)
        e > 0 && push!(up, e == 1 ? SI_NAMES[i] : "$(SI_NAMES[i])^$e")
        e < 0 && push!(down, e == -1 ? SI_NAMES[i] : "$(SI_NAMES[i])^$(-e)")
    end
    head = isempty(up) ? "1" : join(up, "*")
    return isempty(down) ? head : head * "/" * join(down, "/")
end

# The unit that a property of this dimension is given in when no database has it: the unit of the
# archive that is already in the SI (`"Pa*s"`, `"kg/m3"`), or the SI unit of one that is not
# (`"kPa"` -> `"Pa"`), or else composed from the base units.
function si_unit_text(dim::DimVector)
    all(iszero, dim) && return ""
    for spec in UNIT_SPECS
        unit = parse_exact_unit(spec.native)
        unit.dim == dim && replace(spec.si, "^" => "") == spec.native && return spec.native
    end
    for spec in UNIT_SPECS
        parse_exact_unit(spec.native).dim == dim && return spec.si
    end
    return si_text(dim)
end

# The unit written as text, or `nothing` when the exact parser does not read it.
function readable_unit(text::AbstractString)
    try
        return parse_exact_unit(text)
    catch err
        err isa ArgumentError ? (return nothing) : rethrow()
    end
end

# A temperature or a pressure (`difference = false`) or a difference of them, such as a tolerance
# (`difference = true`: the scale is converted, never the offset), as a `Float64` in K or kPa.
function input_number(x::Real, kind, difference::Bool)
    return Float64(x)
end
function input_number(x::AbstractString, kind, difference::Bool)
    number, text = split_number_unit(x)
    isempty(text) && return number
    affine = quantity_affine(kind, text)
    affine === nothing && throw(
        ArgumentError(
            "cannot read \"$text\" as a unit of $(quantity_name(kind)); a gauge pressure is " *
            "not accepted, only an absolute one",
        ),
    )
    return apply_exact(difference ? difference_of(affine) : affine, number)
end
function input_number(x, kind, difference::Bool)
    return difference ? native_difference(x, kind) : native_value(x, kind)
end

# The same, with the name of the quantity in the error.
function input_named(name::AbstractString, x, kind, difference::Bool)
    try
        return input_number(x, kind, difference)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("$name: $(err.msg)"))
    end
end

# A relative tolerance: a fraction (`1e-3`), or a text/quantity with a relative unit (`"0.1 %"`).
relative_input(x::Real) = Float64(x)
function relative_input(x::AbstractString)
    number, text = split_number_unit(x)
    isempty(text) && return number
    fraction = get(RELATIVE_UNITS, text, nothing)
    fraction === nothing && throw(
        ArgumentError(
            "cannot read \"$text\" as a relative unit; use a fraction or one of " *
            join(sort!(collect(keys(RELATIVE_UNITS))), ", "),
        ),
    )
    return number * fraction
end
function relative_input(x)
    parts = quantity_parts(backend_of(x), x)
    (parts !== nothing && parts[2] !== nothing && haskey(RELATIVE_UNITS, parts[2])) ||
        throw(
            ArgumentError(
                "a relative tolerance is a fraction or a percentage, got $(repr(x))",
            ),
        )
    return Float64(parts[1]) * RELATIVE_UNITS[parts[2]]
end

function relative_named(name::AbstractString, x)
    try
        return relative_input(x)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("$name: $(err.msg)"))
    end
end
