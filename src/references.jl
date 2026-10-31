# The references of the package, read from `CITATION.cff` when the package is precompiled.
#
# `CITATION.cff` is the one place where the works that the package credits are written: the
# dataset and the standard of the ThermoML Archive, the articles about it, the work of the
# group. The notice, the entries of every `.bib` and the bibliography of the documentation
# are all derived from it. The file is read once, while the package is precompiled, and the
# result is stored in the compiled package: nothing is read or parsed when the package is
# loaded, and the legal notice cannot go missing at run time. Editing the file makes Julia
# precompile the package again.

const CFF_FILE = "CITATION.cff"
const CFF_PATH = normpath(joinpath(@__DIR__, "..", CFF_FILE))
Base.include_dependency(CFF_PATH)

# The CFF file as a dictionary, or `nothing` when it is not there or cannot be read.
function read_cff(path::AbstractString)::Union{Nothing,Dict{String,Any}}
    isfile(path) || return nothing
    try
        data = YAML.load_file(path; dicttype = Dict{String,Any})
        return data isa AbstractDict ? Dict{String,Any}(data) : nothing
    catch err
        err isa InterruptException && rethrow()
        @debug "Could not read the citation file" path exception = err
        return nothing
    end
end

# Failing here, while precompiling, is intended: a package that cannot name the origin of
# its data must not load.
const CFF = let data = read_cff(CFF_PATH)
    data === nothing && error(
        "ThermophysicalDB.jl could not read ",
        CFF_PATH,
        ", which holds its references",
    )
    data
end

"The `keywords` of a CFF record as a vector of strings."
function cff_keywords(d::AbstractDict)
    keywords = get(d, "keywords", nothing)
    keywords isa AbstractVector || return String[]
    return String[string(k) for k in keywords]
end

"""
The `references` of a CFF record that carry the keyword `keyword` (all of them when it is
`nothing`).
"""
function cff_references(
    data::AbstractDict,
    keyword::Union{Nothing,AbstractString} = nothing,
)
    refs = get(data, "references", nothing)
    refs isa AbstractVector || return Dict{String,Any}[]
    return Dict{String,Any}[
        r for r in refs if
        r isa AbstractDict && (keyword === nothing || keyword in cff_keywords(r))
    ]
end

cff_year(d::AbstractDict) =
    if haskey(d, "date-released")
        x = d["date-released"]
        x isa Dates.TimeType ? string(Dates.year(x)) : first(string(x), 4)
    elseif haskey(d, "year")
        string(d["year"])
    else
        ""
    end

# The DOI of a CFF record: the `doi` key, or the first `identifiers` entry of type `doi`.
function cff_doi(d::AbstractDict)
    haskey(d, "doi") && return string(d["doi"])
    ids = get(d, "identifiers", nothing)
    if ids isa AbstractVector
        for id in ids
            id isa AbstractDict &&
                get(id, "type", "") == "doi" &&
                return string(get(id, "value", ""))
        end
    end
    return ""
end

# `Family, G. H.` for a person, the name for an entity.
function cff_short_name(a::AbstractDict)
    haskey(a, "family-names") || return string(get(a, "name", ""))
    given = string(get(a, "given-names", ""))
    parts = filter(!isempty, split(given, r"[\s-]+"))
    initials = join((string(first(p), '.') for p in parts), " ")
    return isempty(initials) ? string(a["family-names"]) :
           string(a["family-names"], ", ", initials)
end

"""
The full citation of a dataset in the form its publisher asks for: authors, title, version,
publisher, year and DOI.
"""
function cff_citation_text(d::AbstractDict)
    authors = join((cff_short_name(a) for a in d["authors"] if a isa AbstractDict), "; ")
    version = haskey(d, "version") ? string(", version ", d["version"]) : ""
    publisher = get(d, "publisher", nothing)
    publisher =
        publisher isa AbstractDict ? get(publisher, "name", "") :
        string(something(publisher, ""))
    doi = cff_doi(d)
    return string(
        authors,
        " ",
        d["title"],
        version,
        isempty(publisher) ? "" : string("; ", publisher),
        ", ",
        cff_year(d),
        ".",
        isempty(doi) ? "" : string(" https://doi.org/", doi),
    )
end

# The dataset that holds the points: the reference of type `data` marked `data-source`.
const ARCHIVE_REFERENCE =
    let found =
            filter(r -> get(r, "type", "") == "data", cff_references(CFF, "data-source"))
        length(found) == 1 || error(
            "CITATION.cff must have exactly one reference of type `data` with the keyword `data-source`",
        )
        only(found)
    end
