# Plain-data intermediate representation of one ThermoML article. Parsing produces these
# without touching shared state, so it can run on any thread; merging them into the
# global `Dataset` (which interns strings and deduplicates) is a separate, sequential step.

"A value an extra field can hold."
const ExtraValue = Union{String,Float64}
const ExtraPairs = Vector{Pair{String,ExtraValue}}

struct ParsedCompound
    org_num::Int            # number local to the article
    inchikey::String
    inchi::String
    formula::String
    names::Vector{String}
end

struct ParsedProperty
    number::Int
    label::String           # without unit; presentation qualifiers are appended
    unit::String            # native unit, "" when dimensionless
    group::String
    method::String
    phase::String
    level::Float64          # level of confidence as a fraction, NaN when not given
    extras::ExtraPairs      # constant for every point of this property
end

struct ParsedMeasurement
    property::Int32         # position in `ParsedExperiment.properties`
    value::Float64
    unc::Float64
    temperature::Float64
    pressure::Float64
    composition::NTuple{MAX_COMPONENTS,Float64}
    extras::Union{Nothing,ExtraPairs}
end

struct ParsedExperiment
    number::Int
    orgnums::Vector{Int}    # components, in the order of the article
    kinds::Vector{String}   # composition kind per component, "" when not given
    properties::Vector{ParsedProperty}
    measurements::Vector{ParsedMeasurement}
    extras::ExtraPairs
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
