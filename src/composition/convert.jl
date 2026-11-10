# Conversion of the composition of a selection of the database to another scale. The data
# of the archive are never changed: the converted compositions are new columns.

"""
    CompositionConversion

What [`convert_composition`](@ref) returns for a selection: `x1`, `x2`, `x3` (the amounts of
the components in the new scale, `NaN` where the conversion was not possible), `xkind` (the
name of the scale for each point), `status` (`:ok` or the reason a point was not converted;
see `COMPOSITION_STATUS_TEXT`) and the `scale`. Printing it counts the points of each status.
"""
struct CompositionConversion
    scale::Symbol
    x1::Vector{Float64}
    x2::Vector{Float64}
    x3::Vector{Float64}
    xkind::Vector{String}
    status::Vector{Symbol}
end

Base.length(c::CompositionConversion) = length(c.status)

function status_counts(status::AbstractVector{Symbol})
    counts = Dict{Symbol,Int}()
    for s in status
        counts[s] = get(counts, s, 0) + 1
    end
    return sort!(collect(counts); by = last, rev = true)
end

function Base.show(io::IO, c::CompositionConversion)
    print(io, "CompositionConversion to :", c.scale, " of ", length(c), " points")
    for (status, count) in status_counts(c.status)
        print(io, "\n  ", rpad(status, 22), count, "  ", COMPOSITION_STATUS_TEXT[status])
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Density of the solution
# ----------------------------------------------------------------------------------

# The density (kg/m3) of the solution at point `i` of the selection, which is at the
# temperature `T` (K) and pressure `p` (kPa). A number is the same for every point and a
# vector has one value for each point. A function of the state is prepared for but not
# accepted yet, so that giving one later does not change the keyword.
density_at(::Nothing, i, T, p) = NaN
density_at(d::Real, i, T, p) = Float64(d)
density_at(d::AbstractVector{<:Real}, i, T, p) = Float64(d[i])
function density_at(::Function, i, T, p)
    throw(
        ArgumentError(
            "a density given as a function is not supported yet: give a number or a " *
            "vector with one value (kg/m3) for each point",
        ),
    )
end
density_at(d, i, T, p) = throw(
    ArgumentError("density must be a number or a vector of numbers, got $(typeof(d))"),
)

function check_density(density, n::Integer)
    density === nothing && return nothing
    if density isa Real
        (isfinite(density) && density > 0) ||
            throw(ArgumentError("density must be positive (kg/m3), got $density"))
    elseif density isa AbstractVector{<:Real}
        length(density) == n || throw(
            ArgumentError(
                "density has $(length(density)) values but the selection has $n points",
            ),
        )
    elseif !(density isa Function)
        throw(ArgumentError("density must be a number or a vector, got $(typeof(density))"))
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Solvent
# ----------------------------------------------------------------------------------

# The compounds of the dataset that the user means by `solvent`: a name or identifier that the
# search of the dataset finds exactly, or the identifier of a compound.
function solvent_compounds(ds::Dataset, solvent)
    solvent === nothing && return nothing
    ids = Set{Int32}()
    for item in (solvent isa AbstractVector ? solvent : (solvent,))
        if item isa Integer
            1 <= item <= length(ds.compounds) ||
                throw(ArgumentError("solvent $item is not a compound of the dataset"))
            push!(ids, Int32(item))
        elseif item isa AbstractString
            found = find_compounds(ds, item; limit = 25)
            before = length(ids)
            for (id, kind) in zip(found.id, found.match)
                kind === :exact && push!(ids, id)
            end
            length(ids) > before ||
                throw(ArgumentError("no compound of the dataset is called \"$item\""))
        else
            throw(ArgumentError("solvent must be a name or a compound identifier"))
        end
    end
    return ids
end

# ----------------------------------------------------------------------------------
# Molar masses
# ----------------------------------------------------------------------------------

# The molar mass the user gave for compound `c`: a dictionary whose keys are names, InChIKeys
# or identifiers of the dataset, with values in g/mol.
function user_molar_mass(t::CompoundTable, c::Integer, user)
    user === nothing && return nothing
    mine = nothing
    for (key, value) in user
        hit = if key isa Integer
            key == c
        elseif key isa AbstractString
            if mine === nothing
                mine = Set(normalize_name(name) for name in t.names[c])
                isempty(t.inchikey[c]) || push!(mine, normalize_name(t.inchikey[c]))
                isempty(t.key[c]) || push!(mine, normalize_name(t.key[c]))
            end
            normalize_name(key) in mine
        else
            false
        end
        if hit
            (value isa Real && isfinite(value) && value > 0) || throw(
                ArgumentError(
                    "the molar mass of $(repr(key)) must be positive (g/mol), got $value",
                ),
            )
            return Float64(value)
        end
    end
    return nothing
end

compound_source(compounds::CompoundDB) = compounds
compound_source(compounds::LinkedDatabase) = compounds.compounds
compound_source(::Nothing) = nothing
compound_source(x) = throw(
    ArgumentError(
        "compounds must be a compound database or a linked database, got $(typeof(x))",
    ),
)

# The molar mass of `c` according to the rows of the compound database that describe it: the
# rows whose formula does not contradict the dataset's, with a molar mass; they must agree.
function database_molar_mass(links::CompoundLinks, rows)
    values = Float64[]
    for r in rows
        links.record[r] == 0 && continue
        links.formula_check[r] === :different && continue
        mass = links.molar_mass[r]
        (isfinite(mass) && mass > 0) && push!(values, mass)
    end
    isempty(values) && return (NaN, :missing_molar_mass)
    lo, hi = extrema(values)
    hi - lo <= 1.0e-6 * hi || return (NaN, :ambiguous_molar_mass)
    return (lo, :ok)
end

"""
    resolve_molar_masses(ds, ids, molar_mass, compounds, fetch) -> (masses, reasons)

The molar mass (g/mol) of each compound of `ids`. What the user gave in `molar_mass` comes first;
then the compound database (`compounds`), through its link to the compound of the dataset; with
`fetch = true` a compound that the database does not know is asked from PubChem, by InChIKey.
`reasons` says why a compound has no mass (`:missing_molar_mass` or `:ambiguous_molar_mass`).
"""
function resolve_molar_masses(
    ds::Dataset,
    ids::AbstractVector{<:Integer},
    molar_mass,
    compounds,
    fetch::Bool,
)
    t = ds.compounds
    masses = Dict{Int32,Float64}()
    reasons = Dict{Int32,Symbol}()
    pending = Int32[]
    for c in ids
        mass = user_molar_mass(t, c, molar_mass)
        mass === nothing ? push!(pending, c) : (masses[c] = mass)
    end
    db = compound_source(compounds)
    if db === nothing
        for c in pending
            reasons[c] = :missing_molar_mass
        end
        return masses, reasons
    end
    links = compound_links(ds, db; only = pending)
    rows = Dict{Int32,Vector{Int}}()
    for r in eachindex(links.compound)
        push!(get!(Vector{Int}, rows, links.compound[r]), r)
    end
    for c in pending
        mass, reason = database_molar_mass(links, get(rows, c, Int[]))
        if reason === :missing_molar_mass && fetch && !isempty(t.inchikey[c])
            fetch_pubchem!(db, t.inchikey[c]; force = true)
            fresh = compound_links(ds, db; only = [c])
            mass, reason = database_molar_mass(fresh, eachindex(fresh.compound))
        end
        reason === :ok ? (masses[c] = mass) : (reasons[c] = reason)
    end
    return masses, reasons
end

# ----------------------------------------------------------------------------------
# A selection
# ----------------------------------------------------------------------------------

# What is the same for every point of an experiment.
struct SystemPlan
    status::Symbol         # :ok, or why no point of the system can be converted
    n::Int                 # number of components
    from::Symbol           # the scale of the source
    M::NTuple{3,Float64}   # molar masses, g/mol
    solvent::Int           # position of the solvent, 0 when none
    mass_reason::Symbol    # why a molar mass is missing
end

const NO_PLAN = SystemPlan(:no_composition, 0, :mole_fraction, (NaN, NaN, NaN), 0, :ok)

function plan_system(
    ds::Dataset,
    e::Integer,
    solvents,
    masses::Dict{Int32,Float64},
    reasons::Dict{Int32,Symbol},
)
    ex = ds.experiments
    n = Int(ex.ncomp[e])
    M = ntuple(j -> j <= n ? get(masses, ex.components[j][e], NaN) : NaN, 3)
    reason = :missing_molar_mass
    for j = 1:n
        r = get(reasons, ex.components[j][e], :ok)
        r === :ok || (reason = r; break)
    end
    solvent = 0
    if solvents !== nothing
        for j = 1:n
            ex.components[j][e] in solvents && (solvent = j; break)
        end
    end
    kinds = unique(pool_string(ds.kinds, ex.kinds[j][e]) for j = 1:n)
    filter!(!isempty, kinds)
    if n == 1
        return SystemPlan(:ok, 1, :mole_fraction, M, 1, reason)
    elseif isempty(kinds)
        return SystemPlan(:no_composition, n, :mole_fraction, M, solvent, reason)
    elseif length(kinds) > 1
        return SystemPlan(:mixed_kinds, n, :mole_fraction, M, solvent, reason)
    end
    scale = get(SCALE_OF_KIND, kinds[1], :unknown)
    scale === :unknown &&
        return SystemPlan(:unsupported_scale, n, :mole_fraction, M, solvent, reason)
    return SystemPlan(:ok, n, scale, M, solvent, reason)
end

"""
    convert_composition(view, to; solvent = nothing, molar_mass = nothing, compounds = nothing,
                        density = nothing, fetch_molar_mass = false, strict = false) -> CompositionConversion

Express the composition of every point of a [`DataView`](@ref) in the scale `to` (one of
[`COMPOSITION_SCALES`](@ref)), whatever scale the sources used. The data of the archive are not
changed. A point that cannot be converted gets `NaN` and a `status` that says why; with
`strict = true` the first such point is an `ArgumentError` instead.

- `solvent`: the component that is the solvent, by name, identifier (CAS number, InChIKey, ...) or
  identifier of the dataset; a list is accepted. It is needed when the source or the target scale is
  per amount of solvent (molality, ratios). It is never guessed.
- `molar_mass`: a dictionary from names (or InChIKeys, or identifiers of the dataset) to molar
  masses in g/mol, e.g. `Dict("water" => 18.01528)`. What you give wins over everything else.
- `compounds`: the compound database ([`compound_database`](@ref)) or a [`LinkedDatabase`](@ref), where
  the molar masses that you did not give are looked for (they include what was fetched from PubChem).
  With `fetch_molar_mass = true` a compound that the database does not know is asked from PubChem by its
  InChIKey; the network is not used otherwise.
- `density`: the density of the solution in kg/m3, needed to convert from or to the molarity or the
  mass concentration: a number for every point or a vector with one value for each point. It is never
  estimated. A function of the state is not accepted yet.

Fractions that the source gave with all components must add up to one within
`COMPOSITION_SUM_TOLERANCE`; a single missing fraction is the rest. See
[`convert_composition`](@ref) for one mixture.
"""
function convert_composition(
    view::DataView,
    to::Symbol;
    solvent = nothing,
    molar_mass = nothing,
    compounds = nothing,
    density = nothing,
    fetch_molar_mass::Bool = false,
    strict::Bool = false,
)
    check_scale(to, "to")
    ds = view.dataset
    m, ex = ds.measurements, ds.experiments
    rows = view.rows
    n = length(rows)
    check_density(density, n)
    solvents = solvent_compounds(ds, solvent)

    used = unique!(Int32[m.experiment[r] for r in rows])
    wanted = Set{Int32}()
    for e in used, j = 1:Int(ex.ncomp[e])
        push!(wanted, ex.components[j][e])
    end
    masses, reasons = resolve_molar_masses(
        ds,
        sort!(collect(wanted)),
        molar_mass,
        compounds,
        fetch_molar_mass,
    )

    plans = fill(NO_PLAN, length(ex))
    for e in used
        plans[e] = plan_system(ds, e, solvents, masses, reasons)
    end

    x = ntuple(_ -> fill(NaN, n), 3)
    kind = fill(SCALE_KINDS[to], n)
    status = Vector{Symbol}(undef, n)
    for (i, r) in enumerate(rows)
        plan = plans[m.experiment[r]]
        status[i] = plan.status
        plan.status === :ok || continue
        T, p = m.temperature[r], m.pressure[r]
        rho = density_at(density, i, T, p)
        v = (m.composition[1][r], m.composition[2][r], m.composition[3][r])
        s = plan.solvent
        if plan.n > 1 && needs_solvent(plan.from) && solvents === nothing
            status[i] = :solvent_not_given
            continue
        end
        if plan.n > 1 && needs_solvent(to) && solvents === nothing
            status[i] = :solvent_not_given
            continue
        end
        mole, st = to_mole_fractions(plan.from, v, plan.M, plan.n, s, rho)
        if st === :ok
            out, st = from_mole_fractions(to, mole, plan.M, plan.n, s, rho)
            if st === :ok
                x[1][i], x[2][i], x[3][i] = out
            end
        end
        st === :missing_molar_mass && (st = plan.mass_reason)
        status[i] = st
    end
    result = CompositionConversion(to, x[1], x[2], x[3], kind, status)
    strict && require_converted(result)
    return result
end

function require_converted(c::CompositionConversion)
    for (status, count) in status_counts(c.status)
        status === :ok && continue
        throw(
            ArgumentError(
                "$count of $(length(c)) points cannot be converted to :$(c.scale): " *
                COMPOSITION_STATUS_TEXT[status] *
                " (use strict = false to get NaN for them)",
            ),
        )
    end
    return nothing
end

# A warning that counts the points that were not converted (the table keeps NaN for them).
function warn_unconverted(c::CompositionConversion)
    failed = [(s, k) for (s, k) in status_counts(c.status) if s !== :ok]
    isempty(failed) && return nothing
    text = join(("$k points: $(COMPOSITION_STATUS_TEXT[s])" for (s, k) in failed), "; ")
    @warn "composition not converted to :$(c.scale) (NaN in x1..x3): $text"
    return nothing
end
