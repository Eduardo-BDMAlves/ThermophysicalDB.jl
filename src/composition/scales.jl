# Conversions between the scales in which the amount of each component of a mixture is
# written. The kernels work on one point and on tuples, so they allocate nothing and are
# type stable; the conversion of a whole selection (`convert.jl`) only loops over them.
#
# Every conversion goes through the mole fractions. A scale is turned into the amounts
# `n_i` of each component in some basis (one kilogram of solvent, one cubic decimetre of
# solution, ...) and the amounts are normalised; the mole fractions are turned into the
# target scale the same way, backwards. Molar masses are in g/mol and the density of the
# solution is in kg/m3.

"""
    COMPOSITION_SCALES

The scales a composition can be converted to with [`convert_composition`](@ref):

| scale | what it is | needs |
|:--|:--|:--|
| `:mole_fraction` | `x_i = n_i / Σn` | - |
| `:mass_fraction` | `w_i = m_i / Σm` | molar masses |
| `:molality` | mol of `i` per kg of solvent (mol/kg) | solvent (and its molar mass) |
| `:amount_ratio` | `n_i / n_solvent` | solvent |
| `:mass_ratio` | `m_i / m_solvent` | solvent, molar masses |
| `:amount_per_solution_mass` | mol of `i` per kg of solution (mol/kg) | solvent, molar masses |
| `:molarity` | mol of `i` per dm3 of solution (mol/dm3) | density, molar masses |
| `:mass_concentration` | kg of `i` per m3 of solution (kg/m3) | density, molar masses |

The solvent scales give `NaN` for the solvent itself. A conversion that needs a molar mass, a
solvent or a density that was not given is never guessed: it fails with a message that says
what is missing.
"""
const COMPOSITION_SCALES = (
    :mole_fraction,
    :mass_fraction,
    :molality,
    :amount_ratio,
    :mass_ratio,
    :amount_per_solution_mass,
    :molarity,
    :mass_concentration,
)

"The text that ThermoML (and `xkind` in the tables) uses for each scale."
const SCALE_KINDS = Dict{Symbol,String}(
    :mole_fraction => "Mole fraction",
    :mass_fraction => "Mass fraction",
    :molality => "Molality, mol/kg",
    :amount_ratio => "Amount ratio of solute to solvent",
    :mass_ratio => "Mass ratio of solute to solvent",
    :amount_per_solution_mass => "Ratio of amount of solute to mass of solution, mol/kg",
    :molarity => "Amount concentration (molarity), mol/dm3",
    :mass_concentration => "Ratio of mass of solute to volume of solution, kg/m3",
)

const SCALE_OF_KIND = Dict{String,Symbol}(v => k for (k, v) in SCALE_KINDS)

"The unit written in the header of a composition column in each scale."
const SCALE_UNITS = Dict{Symbol,String}(
    :mole_fraction => "-",
    :mass_fraction => "-",
    :molality => "mol/kg",
    :amount_ratio => "-",
    :mass_ratio => "-",
    :amount_per_solution_mass => "mol/kg",
    :molarity => "mol/dm3",
    :mass_concentration => "kg/m3",
)

# Scales that need the density of the solution, and scales that need the solvent.
needs_density(scale::Symbol) = scale === :molarity || scale === :mass_concentration
needs_solvent(scale::Symbol) = !(
    scale === :mole_fraction ||
    scale === :mass_fraction ||
    scale === :molarity ||
    scale === :mass_concentration
)

# Fractions given by the source may not add up to one because of rounding; this is the largest
# departure that is accepted (and removed by dividing by the sum). A larger one is refused.
const COMPOSITION_SUM_TOLERANCE = 1.0e-3

"What each status of a conversion means; `:ok` is the only one that gives numbers."
const COMPOSITION_STATUS_TEXT = Dict{Symbol,String}(
    :ok => "converted",
    :no_composition => "the source does not say how the amounts of the components are expressed",
    :mixed_kinds => "the components are expressed in different scales",
    :unsupported_scale => "the scale of the source (a volume fraction or ratio) cannot be converted",
    :solvent_not_given => "the conversion needs a solvent and none was given (`solvent = ...`)",
    :solvent_not_found => "the solvent is not a component of this system",
    :missing_molar_mass => "a molar mass that the conversion needs is not known (`molar_mass = ...` or `compounds = ...`)",
    :ambiguous_molar_mass => "the compound database has more than one molar mass for a component",
    :missing_density => "the conversion needs the density of the solution (`density = ...`)",
    :incomplete => "an amount is missing and cannot be deduced",
    :sum_mismatch => "the fractions do not add up to one",
    :invalid => "the amounts are not physical (negative, infinite or no solvent left)",
    :single_component => "a pure compound has no such composition",
)

@inline nan_tuple(::Val{N}) where {N} = ntuple(_ -> NaN, Val(N))

@inline masses_known(M::NTuple{N,Float64}, n::Int) where {N} =
    all(j -> isfinite(M[j]) && M[j] > 0, 1:n)

# The amounts of the components given as fractions (they must add up to one); a single missing
# amount is the rest. Returns the fractions and a status.
@inline function closed_fractions(v::NTuple{N,Float64}, n::Int) where {N}
    total = 0.0
    absent = 0
    hole = 0
    for j = 1:n
        a = v[j]
        if isnan(a)
            absent += 1
            hole = j
        elseif !(a >= 0.0) || isinf(a)
            return nan_tuple(Val(N)), :invalid
        else
            total += a
        end
    end
    if absent == 0
        abs(total - 1) <= COMPOSITION_SUM_TOLERANCE ||
            return (nan_tuple(Val(N)), :sum_mismatch)
        return ntuple(j -> j <= n ? v[j] / total : NaN, Val(N)), :ok
    elseif absent == 1
        rest = 1.0 - total
        rest >= -COMPOSITION_SUM_TOLERANCE || return (nan_tuple(Val(N)), :sum_mismatch)
        return ntuple(j -> j <= n ? (j == hole ? max(rest, 0.0) : v[j]) : NaN, Val(N)), :ok
    end
    return nan_tuple(Val(N)), :incomplete
end

@inline function normalized_amounts(a::NTuple{N,Float64}, n::Int) where {N}
    total = 0.0
    for j = 1:n
        (isfinite(a[j]) && a[j] >= 0.0) || return (nan_tuple(Val(N)), :invalid)
        total += a[j]
    end
    total > 0 || return (nan_tuple(Val(N)), :invalid)
    return ntuple(j -> j <= n ? a[j] / total : NaN, Val(N)), :ok
end

# Whether the solute amounts (all components but the solvent `s`) are usable.
@inline function solutes_given(v::NTuple{N,Float64}, n::Int, s::Int) where {N}
    for j = 1:n
        j == s && continue
        (isfinite(v[j]) && v[j] >= 0.0) || return false
    end
    return true
end

"""
    to_mole_fractions(scale, v, M, n, s, rho) -> (x, status)

The mole fractions of the first `n` components of a point whose amounts `v` are written in
`scale`, with molar masses `M` (g/mol), the solvent in position `s` (`0` for none) and the
density `rho` of the solution (kg/m3). `v`, `M` and the result are tuples; the positions after
`n` are ignored and come back `NaN`. `status` is `:ok` or the reason there is no result (see
`COMPOSITION_STATUS_TEXT`).
"""
function to_mole_fractions(
    scale::Symbol,
    v::NTuple{N,Float64},
    M::NTuple{N,Float64},
    n::Int,
    s::Int,
    rho::Float64,
) where {N}
    n == 1 && return (ntuple(j -> j == 1 ? 1.0 : NaN, Val(N)), :ok)
    if scale === :mole_fraction
        return closed_fractions(v, n)
    elseif scale === :mass_fraction
        w, status = closed_fractions(v, n)
        status === :ok || return (w, status)
        masses_known(M, n) || return (nan_tuple(Val(N)), :missing_molar_mass)
        return normalized_amounts(ntuple(j -> j <= n ? w[j] / M[j] : NaN, Val(N)), n)
    end
    needs_density(scale) &&
        !(isfinite(rho) && rho > 0) &&
        return (nan_tuple(Val(N)), :missing_density)
    if needs_solvent(scale)
        (1 <= s <= n) || return (nan_tuple(Val(N)), :solvent_not_found)
        solutes_given(v, n, s) || return (nan_tuple(Val(N)), :incomplete)
    end
    if scale === :molality
        (isfinite(M[s]) && M[s] > 0) || return (nan_tuple(Val(N)), :missing_molar_mass)
        return normalized_amounts(
            ntuple(j -> j <= n ? (j == s ? 1000.0 / M[s] : v[j]) : NaN, Val(N)),
            n,
        )
    elseif scale === :amount_ratio
        return normalized_amounts(
            ntuple(j -> j <= n ? (j == s ? 1.0 : v[j]) : NaN, Val(N)),
            n,
        )
    end
    masses_known(M, n) || return (nan_tuple(Val(N)), :missing_molar_mass)
    if scale === :mass_ratio
        return normalized_amounts(
            ntuple(j -> j <= n ? (j == s ? 1.0 : v[j]) / M[j] : NaN, Val(N)),
            n,
        )
    end
    # Amounts per mass of solution (1000 g) or per volume of solution (1 dm3, whose mass is
    # `rho` g): a component without a value is what is left of the mass of the basis.
    basis = scale === :amount_per_solution_mass ? 1000.0 : rho
    rest = 0
    given = 0.0
    for j = 1:n
        if isfinite(v[j])
            given += scale === :mass_concentration ? v[j] : v[j] * M[j]
        elseif rest == 0
            rest = j
        else
            return (nan_tuple(Val(N)), :incomplete)
        end
    end
    left = basis - given
    if rest != 0
        left > 0 || return (nan_tuple(Val(N)), :invalid)
    elseif !isapprox(given, basis; rtol = COMPOSITION_SUM_TOLERANCE)
        return (nan_tuple(Val(N)), :sum_mismatch)
    end
    return normalized_amounts(
        ntuple(
            j ->
                j > n ? NaN :
                j == rest ? left / M[j] :
                scale === :mass_concentration ? v[j] / M[j] : v[j],
            Val(N),
        ),
        n,
    )
end

"""
    from_mole_fractions(scale, x, M, n, s, rho) -> (v, status)

The amounts in `scale` of the components with mole fractions `x`; the arguments are those of
`to_mole_fractions`. The scales that are per amount of solvent give `NaN` for the solvent.
"""
function from_mole_fractions(
    scale::Symbol,
    x::NTuple{N,Float64},
    M::NTuple{N,Float64},
    n::Int,
    s::Int,
    rho::Float64,
) where {N}
    if n == 1
        (scale === :mole_fraction || scale === :mass_fraction) &&
            return ntuple(j -> j == 1 ? 1.0 : NaN, Val(N)), :ok
        return nan_tuple(Val(N)), :single_component
    end
    scale === :mole_fraction && return (ntuple(j -> j <= n ? x[j] : NaN, Val(N)), :ok)
    needs_density(scale) &&
        !(isfinite(rho) && rho > 0) &&
        return (nan_tuple(Val(N)), :missing_density)
    if needs_solvent(scale)
        (1 <= s <= n) || return (nan_tuple(Val(N)), :solvent_not_found)
        x[s] > 0 || return (nan_tuple(Val(N)), :invalid)
    end
    if scale === :molality
        (isfinite(M[s]) && M[s] > 0) || return (nan_tuple(Val(N)), :missing_molar_mass)
        return ntuple(j -> j <= n && j != s ? 1000.0 * x[j] / (x[s] * M[s]) : NaN, Val(N)),
        :ok
    elseif scale === :amount_ratio
        return ntuple(j -> j <= n && j != s ? x[j] / x[s] : NaN, Val(N)), :ok
    end
    masses_known(M, n) || return (nan_tuple(Val(N)), :missing_molar_mass)
    mean_mass = 0.0
    for j = 1:n
        mean_mass += x[j] * M[j]
    end
    if scale === :mass_fraction
        return ntuple(j -> j <= n ? x[j] * M[j] / mean_mass : NaN, Val(N)), :ok
    elseif scale === :mass_ratio
        return ntuple(j -> j <= n && j != s ? x[j] * M[j] / (x[s] * M[s]) : NaN, Val(N)),
        :ok
    elseif scale === :amount_per_solution_mass
        return ntuple(j -> j <= n && j != s ? 1000.0 * x[j] / mean_mass : NaN, Val(N)), :ok
    elseif scale === :molarity
        return ntuple(j -> j <= n ? rho * x[j] / mean_mass : NaN, Val(N)), :ok
    end
    # :mass_concentration
    return ntuple(j -> j <= n ? rho * x[j] * M[j] / mean_mass : NaN, Val(N)), :ok
end

function check_scale(scale::Symbol, role::AbstractString)
    scale in COMPOSITION_SCALES || throw(
        ArgumentError(
            "$role must be one of $(join(repr.(COMPOSITION_SCALES), ", ")), got $(repr(scale))",
        ),
    )
    return scale
end

"""
    convert_composition(values, from, to; molar_mass, solvent = 0, density = NaN) -> Vector{Float64}

Convert the amounts of the components of **one** mixture from the scale `from` to the scale
`to` (see [`COMPOSITION_SCALES`](@ref)). `values` has one entry per component; the entry of the
solvent (for the scales that are per amount of solvent) and of a component that is the rest of
a set of fractions can be `NaN`. `molar_mass` gives the molar mass of each component in g/mol,
`solvent` the position of the solvent in `values`, and `density` the density of the solution in
kg/m3 (needed by `:molarity` and `:mass_concentration` only).

```julia
convert_composition([0.1, NaN], :molality, :mole_fraction; molar_mass = [58.44, 18.015], solvent = 2)
```

Nothing is guessed: what the conversion needs and was not given is an `ArgumentError` that says
what it is. To convert the points of a selection of the database, use the method that takes a
[`DataView`](@ref).

**Physics.** Mole and mass fractions, molality and the ratios do not depend on the temperature
or the pressure; they differ only by the molar masses. The molarity is moles per volume of
*solution*, so it depends on the density of the solution, which depends on the temperature, the
pressure and the composition itself: the density of that state has to be given.
"""
function convert_composition(
    values::AbstractVector{<:Real},
    from::Symbol,
    to::Symbol;
    molar_mass::AbstractVector{<:Real} = fill(NaN, length(values)),
    solvent::Integer = 0,
    density::Real = NaN,
)
    check_scale(from, "from")
    check_scale(to, "to")
    n = length(values)
    n >= 1 || throw(ArgumentError("values is empty"))
    length(molar_mass) == n ||
        throw(ArgumentError("molar_mass must have one entry per component ($n)"))
    v = Tuple(Float64.(values))
    M = Tuple(Float64.(molar_mass))
    rho = Float64(density)
    x, status = to_mole_fractions(from, v, M, n, Int(solvent), rho)
    status === :ok || throw(ArgumentError(composition_message(status)))
    out, status = from_mole_fractions(to, x, M, n, Int(solvent), rho)
    status === :ok || throw(ArgumentError(composition_message(status)))
    return collect(out)
end

composition_message(status::Symbol) =
    string("cannot convert the composition: ", COMPOSITION_STATUS_TEXT[status])
