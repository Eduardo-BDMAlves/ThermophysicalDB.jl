# Samples and purity: parsing of the `Sample` elements of a ThermoML `Compound` and the
# summary stored next to the purification steps.

const SUPPLIER_STATED = "Stated by supplier"
const COMPILER_ESTIMATE = "Estimated by the compiler"

"""
    analysis_basis(method) -> Int

Where a purity comes from, judging by one analysis method: `1` for a value stated by the
supplier, `3` for an estimate (by the compiler of the data, or `"Estimation"`), `0` when the
method says nothing (`""`, `"Not known"`, `"Other"`) and `2` for any real analysis (gas
chromatography, Karl Fischer titration, ...), that is, a purity measured by the authors or
the supplier's laboratory.
"""
function analysis_basis(method::AbstractString)
    (isempty(method) || method == "Not known" || method == "Other") && return 0
    method == SUPPLIER_STATED && return 1
    (method == COMPILER_ESTIMATE || method == "Estimation") && return 3
    return 2
end

"""
    purity_basis_code(methods) -> Int

Combine the analysis methods of one step: a measurement wins over the supplier's statement,
which wins over an estimate. `0` when no method is informative.
"""
function purity_basis_code(methods)
    best = 0
    rank(b) = b == 2 ? 3 : b == 1 ? 2 : b == 3 ? 1 : 0
    for m in methods
        b = analysis_basis(m)
        rank(b) > rank(best) && (best = b)
    end
    return best
end

# The purity a step states, with its kind (position in `PURITY_KINDS`); mass fraction is
# preferred because it is what suppliers quote.
function step_purity(step::ParsedPurityStep)
    isnan(step.mass) || return (step.mass, 1)
    isnan(step.mole) || return (step.mole, 2)
    isnan(step.volume) || return (step.volume, 3)
    isnan(step.unknown) || return (step.unknown, 4)
    return (NaN, 0)
end

"""
    PuritySummary

What the sample table keeps of the steps: the final purity and its kind, the first purity
(only when two steps state one), the water content of the final step, the basis of the final
purity and the methods of every step.
"""
struct PuritySummary
    purity::Float64
    kind::Int
    initial::Float64
    initial_kind::Int
    water::Float64
    basis::Int
    analysis::Vector{String}
    purification::Vector{String}
end

function summarize_purity(steps::AbstractVector{ParsedPurityStep})
    order = sortperm(steps; by = s -> s.step)
    first_p, first_kind = NaN, 0
    last_p, last_kind, last_step = NaN, 0, 0
    nstated = 0
    water = NaN
    analysis, purification = String[], String[]
    for i in order
        s = steps[i]
        p, k = step_purity(s)
        if k != 0
            nstated += 1
            nstated == 1 && ((first_p, first_kind) = (p, k))
            last_p, last_kind, last_step = p, k, i
        end
        isnan(s.water_mass) || (water = s.water_mass)
        merge_unique!(analysis, s.analysis)
        merge_unique!(purification, s.purification)
    end
    basis = last_step == 0 ? 0 : purity_basis_code(steps[last_step].analysis)
    return PuritySummary(
        last_p,
        last_kind,
        nstated >= 2 ? first_p : NaN,
        nstated >= 2 ? first_kind : 0,
        water,
        basis,
        analysis,
        purification,
    )
end

function merge_unique!(into::Vector{String}, from::Vector{String})
    for x in from
        x in into || push!(into, x)
    end
    return into
end

# ----------------------------------------------------------------------------------
# JSON
# ----------------------------------------------------------------------------------

# Percent -> fraction; the digits element sits next to the value.
percent(obj, key) = jnum(obj, key) / 100

function digits_code(obj, key)
    v = jint(obj, key)
    return (jfield(obj, key) === nothing || v < 0 || v >= NO_DIGITS) ? NO_DIGITS : UInt8(v)
end

function parse_purity_step(p)::ParsedPurityStep
    digits = NO_DIGITS
    for (value, d) in (
        ("nPurityMass", "nPurityMassDigits"),
        ("nPurityMol", "nPurityMolDigits"),
        ("nPurityVol", "nPurityVolDigits"),
        ("nUnknownPerCent", "nUnknownPerCentDigits"),
    )
        if !isnan(jnum(p, value))
            digits = digits_code(p, d)
            break
        end
    end
    return ParsedPurityStep(
        jint(p, "nStep"),
        percent(p, "nPurityMass"),
        percent(p, "nPurityMol"),
        percent(p, "nPurityVol"),
        percent(p, "nUnknownPerCent"),
        digits,
        percent(p, "nWaterMassPerCent"),
        percent(p, "nWaterMolPerCent"),
        percent(p, "nHalideMassPerCent"),
        percent(p, "nHalideMolPerCent"),
        jstrings(jfield(p, "eAnalMeth")),
        join(jstrings(jfield(p, "sAnalMeth")), "; "),
        jstrings(jfield(p, "ePurifMethod")),
        join(jstrings(jfield(p, "sPurifMethod")), "; "),
    )
end

function parse_sample(s)::ParsedSample
    return ParsedSample(
        jint(s, "nSampleNm"),
        jstr(s, "eSource"),
        jstr(s, "eStatus"),
        ParsedPurityStep[parse_purity_step(p) for p in jitems(jfield(s, "purity"))],
    )
end

parse_samples(compound) =
    ParsedSample[parse_sample(s) for s in jitems(jfield(compound, "Sample"))]
