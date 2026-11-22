# The phase of a point and what ThermoML calls it.
#
# The package keeps the phase of a point as the text that the user gave. ThermoML, in
# contrast, has a closed list of names (`ePhaseName` of ThermoML.xsd) and no way to say that a
# state is on the saturation curve: the archive says it with the phases that coexist in the
# block of data (`PhaseID`: Liquid and Gas) and the phase of the property (`PropPhaseID`: the
# one the value belongs to), and by leaving the pressure out. The user writes the saturation in
# the name of the phase ("Liquid (saturated)") and the ThermoML export translates it.

# The phases of the standard, in the order of the schema.
const THERMOML_PHASE_NAMES = (
    "Crystal 5",
    "Crystal 4",
    "Crystal 3",
    "Crystal 2",
    "Crystal 1",
    "Crystal",
    "Crystal of unknown type",
    "Crystal of intercomponent compound 1",
    "Crystal of intercomponent compound 2",
    "Crystal of intercomponent compound 3",
    "Metastable crystal",
    "Glass",
    "Smectic liquid crystal",
    "Smectic liquid crystal 1",
    "Smectic liquid crystal 2",
    "Nematic liquid crystal",
    "Nematic liquid crystal 1",
    "Nematic liquid crystal 2",
    "Cholesteric liquid crystal",
    "Liquid crystal of unknown type",
    "Liquid",
    "Liquid mixture 1",
    "Liquid mixture 2",
    "Liquid mixture 3",
    "Solution",
    "Solution 1",
    "Solution 2",
    "Solution 3",
    "Solution 4",
    "Fluid (supercritical or subcritical phases)",
    "Ideal gas",
    "Gas",
    "Air at 1 atmosphere",
)

# Written by the archive although the schema does not list it (the 2020 archive has it in 169
# properties); it is passed on as it is.
const ARCHIVE_PHASE_NAMES = ("Metastable liquid",)

# The names of the saturation states that the package understands, as the menus show them.
const SATURATION_PHASE_NAMES =
    ("Liquid (saturated)", "Vapor (saturated)", "Liquid + Vapor (saturated)")

"""
    thermoml_phases() -> Vector{String}

The names of phases that the ThermoML standard accepts (`ePhaseName` of `ThermoML.xsd`). The
phase of a point is free text; [`thermoml_phase`](@ref) says what ThermoML calls it, and the
ThermoML formats of [`export_points`](@ref) refuse a phase that has no equivalent.
"""
thermoml_phases() = collect(THERMOML_PHASE_NAMES)

"""
    PhaseMeaning

What the text of a phase means in ThermoML (see [`thermoml_phase`](@ref)): `name` is the phase
of the property, `system` the phases of the block of data (the phases that coexist, for a
saturation state), `saturated` whether the text says so, and `description` the text of the user
when it is not a ThermoML name (it is written as `sPhaseDescription`; empty otherwise).
"""
struct PhaseMeaning
    name::String
    system::Vector{String}
    saturated::Bool
    description::String
end

function Base.show(io::IO, m::PhaseMeaning)
    return print(
        io,
        "PhaseMeaning(",
        repr(m.name),
        ", system = ",
        m.system,
        m.saturated ? ", saturated" : "",
        m.description == "" ? "" : ", description = " * repr(m.description),
        ")",
    )
end

const PHASE_BY_LOWER = Dict{String,String}(
    lowercase(name) => name for name in (THERMOML_PHASE_NAMES..., ARCHIVE_PHASE_NAMES...)
)

# Words, spaces and case do not matter: "liquid  (Saturated)" is "Liquid (saturated)".
normalized_phase(text::AbstractString) = lowercase(join(split(text), ' '))

const SATURATION_PATTERN =
    r"^(liquid|vapou?r|gas)(?: ?\+ ?(liquid|vapou?r|gas))?( ?\(saturated\))?$"

# The meaning of a text that is not the name of a phase of the standard, or `nothing`.
function saturation_meaning(text::AbstractString, written::AbstractString)
    m = match(SATURATION_PATTERN, text)
    m === nothing && return nothing
    liquid(word) = word == "liquid"
    saturated = m[3] !== nothing
    if m[2] === nothing
        if liquid(m[1])
            saturated || return nothing                  # "liquid" is a name of the standard
            return PhaseMeaning("Liquid", ["Liquid", "Gas"], true, written)
        end
        system = saturated ? ["Gas", "Liquid"] : ["Gas"]
        return PhaseMeaning("Gas", system, saturated, written)
    end
    # "Liquid + Vapor": a property of the two phases in equilibrium, taken as the liquid's
    liquid(m[1]) == liquid(m[2]) && return nothing
    return PhaseMeaning("Liquid", ["Liquid", "Gas"], true, written)
end

"""
    thermoml_phase(text) -> PhaseMeaning

What ThermoML calls the phase `text`, or an `ArgumentError` that names the closest phases of the
standard. The text is a name of [`thermoml_phases`](@ref) (any case), or a state on the
saturation curve written as

| text | phase of the property | phases of the system |
| :-- | :-- | :-- |
| `Liquid (saturated)` | `Liquid` | `Liquid`, `Gas` |
| `Vapor (saturated)` | `Gas` | `Gas`, `Liquid` |
| `Liquid + Vapor (saturated)` | `Liquid` | `Liquid`, `Gas` |

(`Vapour` and `Gas` mean the same as `Vapor`; `(saturated)` can be left out after a `+`, and a
bare `Vapor` is `Gas`). A property of the two phases in equilibrium is written for the liquid, as
the archive does for the vapor pressure. The text is kept in the file as `sPhaseDescription`, so a
reader sees that a point without a pressure is on the saturation curve and not at atmospheric
pressure.

```julia
thermoml_phase("Liquid (saturated)")   # PhaseMeaning("Liquid", ["Liquid", "Gas"], saturated, ...)
```
"""
function thermoml_phase(text::AbstractString)
    meaning = phase_meaning(text)
    meaning === nothing && throw(ArgumentError(unknown_phase_message(text)))
    return meaning
end

# `nothing` when there is no equivalent; an empty text is not a phase.
function phase_meaning(text::AbstractString)
    written = String(strip(text))
    isempty(written) && return nothing
    key = normalized_phase(written)
    name = get(PHASE_BY_LOWER, key, nothing)
    name === nothing || return PhaseMeaning(name, [name], false, "")
    return saturation_meaning(key, written)
end

# The phases that the text is closest to: those that contain it or that it contains first, then the
# fewest edits.
function closest_phases(text::AbstractString, n::Integer = 3)
    key = normalized_phase(text)
    candidates = String[THERMOML_PHASE_NAMES..., SATURATION_PHASE_NAMES...]
    ranked = map(candidates) do name
        low = lowercase(name)
        near = occursin(key, low) || occursin(low, key)
        (near ? 0 : edit_distance(key, low, 64), length(name), name)
    end
    return String[last(r) for r in first(sort!(ranked), n)]
end

function unknown_phase_message(text::AbstractString)
    return string(
        "the phase \"",
        text,
        "\" has no equivalent in ThermoML; the closest phases are ",
        join(("\"" * p * "\"" for p in closest_phases(text)), ", "),
        ". For a state on the saturation curve write \"Liquid (saturated)\", ",
        "\"Vapor (saturated)\" or \"Liquid + Vapor (saturated)\"; `thermoml_phases()` ",
        "lists the phases of the standard",
    )
end

# The meaning of every phase that the points of `view` have, by its code in the pool of phases. A
# phase without an equivalent is refused, with the number of points that have it.
function phase_meanings(view::DataView)
    ds = view.dataset
    m = ds.measurements
    counts = Dict{Int32,Int}()
    previous, run = Int32(-1), 0          # consecutive points mostly share the phase
    for r in view.rows
        code = m.phase[r]
        if code == previous
            run += 1
        else
            run > 0 && (counts[previous] = get(counts, previous, 0) + run)
            previous, run = code, 1
        end
    end
    run > 0 && (counts[previous] = get(counts, previous, 0) + run)
    meanings = Dict{Int32,PhaseMeaning}()
    refused = Tuple{Int,String}[]
    for (code, count) in counts
        code == NO_ID && continue
        text = pool_string(ds.phases, code)
        isempty(text) && continue
        meaning = phase_meaning(text)
        if meaning === nothing
            push!(refused, (count, text))
        else
            meanings[code] = meaning
        end
    end
    isempty(refused) && return meanings
    sort!(refused; by = x -> (-x[1], x[2]))
    lines = String[
        string(
            "  \"",
            text,
            "\" (",
            count,
            count == 1 ? " point" : " points",
            "): the closest phases of ThermoML are ",
            join(("\"" * p * "\"" for p in closest_phases(text)), ", "),
        ) for (count, text) in refused
    ]
    throw(
        ArgumentError(
            string(
                "the ThermoML formats need the phase of a point to have a ThermoML name; ",
                "these have none:\n",
                join(lines, "\n"),
                "\nFor a state on the saturation curve write \"Liquid (saturated)\", ",
                "\"Vapor (saturated)\" or \"Liquid + Vapor (saturated)\"; change the phase of ",
                "points that are in a database of yours with `update_points!(db, selection; ",
                "phase = \"...\")`",
            ),
        ),
    )
end
