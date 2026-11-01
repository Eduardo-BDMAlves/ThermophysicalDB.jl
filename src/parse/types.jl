# Plain-data intermediate representation of one ThermoML article. Parsing produces these
# without touching shared state, so it can run on any thread; merging them into the
# global `Dataset` (which interns strings and deduplicates) is a separate, sequential step.

"A value an extra field can hold."
const ExtraValue = Union{String,Float64}
const ExtraPairs = Vector{Pair{String,ExtraValue}}

"One purification step of a sample; amounts are fractions, `NaN` when not stated."
struct ParsedPurityStep
    step::Int
    mass::Float64
    mole::Float64
    volume::Float64
    unknown::Float64        # purity without a stated basis
    digits::UInt8           # significant digits of the stated purity, `NO_DIGITS` if none
    water_mass::Float64
    water_mole::Float64
    halide_mass::Float64
    halide_mole::Float64
    analysis::Vector{String}
    analysis_text::String
    purification::Vector{String}
    purification_text::String
end

struct ParsedSample
    number::Int             # number local to the article, within the compound
    origin::String          # eSource
    status::String          # eStatus
    steps::Vector{ParsedPurityStep}
end

struct ParsedCompound
    org_num::Int            # number local to the article
    inchikey::String
    inchi::String
    formula::String
    names::Vector{String}
    samples::Vector{ParsedSample}
end

"""
A condition with no column of its own (see `ConditionTable`): `group` is the element of the
schema that names its kind, `label` the exact name with its unit, `org` the component of
the article it refers to (`0` for the whole system).
"""
struct ParsedCondition
    group::String
    label::String
    value::Float64
    digits::UInt8
    phase::String
    org::Int
    phase_org::Int      # component the phase is stated for, `0` for none
end

"A phase of the system and the components of the article it is stated for (may be empty)."
struct ParsedPhase
    phase::String
    orgs::Vector{Int}
end

struct ParsedProperty
    number::Int
    label::String           # without unit; presentation qualifiers are appended
    unit::String            # native unit, "" when dimensionless
    group::String
    method::String
    method_text::Bool       # the method is free text (`sMethodName`), not an enumerated name
    phase::String
    level::Float64          # level of confidence as a fraction, NaN when not given
    coverage::Float64       # coverage factor, NaN when not given
    unc_method::String      # how the uncertainty was evaluated, "" when not given
    extras::ExtraPairs      # constant for every point of this property
    solvent_orgs::Vector{Int}           # components of the solvent, as numbered in the article
    phase_orgs::Vector{Int}             # components the phase of the property is stated for
    reference_phase_orgs::Vector{Int}   # the same for the reference phase
end

struct ParsedMeasurement
    property::Int32         # position in `ParsedExperiment.properties`
    value::Float64
    unc::Float64
    temperature::Float64
    pressure::Float64
    composition::NTuple{MAX_COMPONENTS,Float64}
    digits::UInt8           # significant digits of value, temperature and pressure
    temperature_digits::UInt8
    pressure_digits::UInt8
    composition_digits::NTuple{MAX_COMPONENTS,UInt8}
    conditions::Union{Nothing,Vector{ParsedCondition}}   # variables without a column
end

struct ParsedExperiment
    number::Int
    orgnums::Vector{Int}    # components, in the order of the article
    kinds::Vector{String}   # composition kind per component, "" when not given
    samples::Vector{Int}    # sample number per component, 0 when not given
    purpose::String         # eExpPurpose, "" when not given
    properties::Vector{ParsedProperty}
    measurements::Vector{ParsedMeasurement}
    extras::ExtraPairs
    constraints::Vector{ParsedCondition}   # every constraint of the experiment
    phases::Vector{ParsedPhase}
end

struct ParsedArticle
    path::String
    doi::String
    title::String
    journal::String
    year::Int
    volume::String
    pages::String
    authors::Vector{String}
    extras::ExtraPairs
    compounds::Vector{ParsedCompound}
    experiments::Vector{ParsedExperiment}
    reaction_blocks::Int    # ReactionData blocks, not supported yet
    skipped::Vector{String} # experiments dropped while parsing, with the reason
    error::String           # "" when the article parsed
end

function failed_article(path::AbstractString, message::AbstractString)
    return ParsedArticle(
        path,
        "",
        "",
        "",
        0,
        "",
        "",
        String[],
        ExtraPairs(),
        ParsedCompound[],
        ParsedExperiment[],
        0,
        String[],
        message,
    )
end
