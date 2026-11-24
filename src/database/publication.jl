# The publication that the data of the user will be in: what the points of the databases of kind
# `:user` are called ("This work") in tables and figures, and the article they will be cited as.

# The label of everything that is not the user's data in the column `work` of a table.
const LITERATURE_LABEL = "Literature"
const DEFAULT_WORK_LABEL = "This work"

# How the data of the user are referred to in what is written (see `Publication`).
const WORK_CITES = (:label, :unpublished, :published)

"""
    Publication(; label = "This work", title = "", authors = String[], year = 0, journal = "",
        doi = "", note = "in preparation", cite = :label)

The article that the data of the user are going to be published in. Give it to the database with
[`set_publication!`](@ref): from then on every point of a database of kind `:user` is called
`label` ("This work", "Present study", ...) in the column `work` of [`table`](@ref) and in the
figures, and all of them make one group, whatever the number of databases of the user. The other
fields describe the article for the references; when it gets a DOI, set the publication again with
it.

`cite` says how the exports ([`export_points`](@ref), [`write_bibtex`](@ref),
[`write_references`](@ref), [`reference_summary`](@ref)) refer to the data of the user, and each of
them takes `cite = ...` to choose again:

| `cite` | The `reference` column and the references table | The `.bib` |
| :-- | :-- | :-- |
| `:label` (default) | the label ("This work") | no entry: the data are the article that is being written |
| `:unpublished` | the BibTeX key of the publication | an `@unpublished` entry with the fields above (for internal reports) |
| `:published` | the key of the article | the entry of the DOI, from the resolver and completed with the fields above (needs `doi`) |

`label` cannot be empty or be `"$(LITERATURE_LABEL)"` (the name of the other group). `authors` are
written as `"Family, Given"`.
"""
struct Publication
    label::String
    title::String
    authors::Vector{String}
    year::Int
    journal::String
    doi::String
    note::String
    cite::Symbol

    function Publication(label, title, authors, year, journal, doi, note, cite = :label)
        label = String(strip(label))
        isempty(label) &&
            throw(ArgumentError("a publication needs a label, such as \"This work\""))
        label == LITERATURE_LABEL && throw(
            ArgumentError(
                "the label \"$LITERATURE_LABEL\" is the name of the points that are not yours; choose another",
            ),
        )
        year == 0 ||
            1500 <= year <= 3000 ||
            throw(
                ArgumentError(
                    "the year of a publication is 0 (not known) or a year, got $year",
                ),
            )
        cite in WORK_CITES ||
            throw(ArgumentError("cite must be one of $(WORK_CITES), got $(repr(cite))"))
        cite === :published &&
            isempty(strip(doi)) &&
            throw(
                ArgumentError(
                    "cite = :published needs the DOI of the publication; use :unpublished until there is one",
                ),
            )
        return new(
            label,
            String(strip(title)),
            String[String(strip(a)) for a in authors if !isempty(strip(a))],
            Int(year),
            String(strip(journal)),
            String(strip(doi)),
            String(strip(note)),
            Symbol(cite),
        )
    end
end

function Publication(;
    label::AbstractString = DEFAULT_WORK_LABEL,
    title::AbstractString = "",
    authors::AbstractVector{<:AbstractString} = String[],
    year::Integer = 0,
    journal::AbstractString = "",
    doi::AbstractString = "",
    note::AbstractString = "in preparation",
    cite::Symbol = :label,
)
    return Publication(label, title, authors, year, journal, doi, note, cite)
end

Base.:(==)(a::Publication, b::Publication) =
    all(f -> getfield(a, f) == getfield(b, f), fieldnames(Publication))
Base.hash(p::Publication, h::UInt) =
    foldl((acc, f) -> hash(getfield(p, f), acc), fieldnames(Publication); init = h)

function Base.show(io::IO, p::Publication)
    print(io, "Publication(", repr(p.label))
    isempty(p.title) || print(io, ", ", repr(p.title))
    p.year == 0 || print(io, ", ", p.year)
    return print(io, ")")
end

# The description of a publication in the file of a database (TOML: empty fields are left out).
function publication_toml(p::Publication)
    d = Dict{String,Any}("label" => p.label)
    isempty(p.title) || (d["title"] = p.title)
    isempty(p.authors) || (d["authors"] = p.authors)
    p.year == 0 || (d["year"] = p.year)
    isempty(p.journal) || (d["journal"] = p.journal)
    isempty(p.doi) || (d["doi"] = p.doi)
    isempty(p.note) || (d["note"] = p.note)
    p.cite === :label || (d["cite"] = String(p.cite))
    return d
end

function publication_from_toml(d::AbstractDict)
    return Publication(;
        label = String(get(d, "label", DEFAULT_WORK_LABEL)),
        title = String(get(d, "title", "")),
        authors = String[String(a) for a in get(d, "authors", String[])],
        year = Int(get(d, "year", 0)),
        journal = String(get(d, "journal", "")),
        doi = String(get(d, "doi", "")),
        note = String(get(d, "note", "")),
        cite = Symbol(get(d, "cite", "label")),
    )
end
