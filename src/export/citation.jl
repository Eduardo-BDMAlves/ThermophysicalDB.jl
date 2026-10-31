# The entries that credit this package and the sources of its data, built from
# `CITATION.cff` (read in references.jl) so that they never drift from the citation the
# repository announces. The software comes first, in the version that is installed; when
# the file gains the DOI of the release (Zenodo) or a `preferred-citation` (the article of
# the package) the exported `.bib` follows without a change of code.
#
# Citation keys have the form of the ones the reference manager generates: the surname of
# the first author, the year and the first word of the title, all lower case
# (`myers1999surfaces`). A record may state its key in `abbreviation`; `check_references`
# verifies that it is the key the pattern gives.

const PACKAGE_KEY_FIELD = "abbreviation"

# `Family, Given` for a person, `{Name}` for an entity, joined with `and`.
function cff_person(a::AbstractDict)
    haskey(a, "family-names") || return haskey(a, "name") ? string('{', a["name"], '}') : ""
    family = string(get(a, "name-particle", ""), " ", a["family-names"])
    family = strip(family)
    suffix = get(a, "name-suffix", nothing)
    suffix === nothing || (family = string(family, ", ", suffix))
    given = get(a, "given-names", nothing)
    return given === nothing ? family : string(family, ", ", given)
end

function cff_authors(authors)
    authors isa AbstractVector || return ""
    names = [cff_person(a) for a in authors if a isa AbstractDict]
    return join(filter(!isempty, names), " and ")
end

const CFF_BIBTYPES = Dict(
    "article" => "article",
    "conference-paper" => "inproceedings",
    "book" => "book",
    "data" => "misc",
    "software" => "misc",
)

# Words with two or more capitals (ThermoML, IUPAC, FAIRness) are put in braces, so that a
# bibliography style does not turn them into lower case.
protect_capitals(s::AbstractString) =
    replace(s, r"\b\w*[[:upper:]]\w*[[:upper:]]\w*\b" => m -> string('{', m, '}'))

"""
    cff_bibentry(d; software = false, accessed = false) -> BibEntry

The BibTeX entry of a CFF record. Its key is the `abbreviation` of the record when it has
one, and the key of the pattern otherwise. `accessed = true` adds the access date of a
dataset (`date-accessed`) to its note, as the documentation does; exported files do not
carry it.
"""
function cff_bibentry(d::AbstractDict; software::Bool = false, accessed::Bool = false)
    type_name = string(get(d, "type", software ? "software" : "article"))
    type = software ? "misc" : get(CFF_BIBTYPES, type_name, "misc")
    fields = Pair{String,String}[]
    function put(name, value; escape::Bool = true)
        text = strip(string(value))
        isempty(text) || push!(fields, name => (escape ? escape_bibtex(text) : text))
        return nothing
    end
    put("author", cff_authors(get(d, "authors", nothing)); escape = false)
    put("title", protect_capitals(string(get(d, "title", ""))))
    put("year", cff_year(d))
    if software
        version = get(d, "version", package_version_text())
        put("version", version)
        put("note", string("Julia package, version ", version))
    elseif type_name == "data"
        note = haskey(d, "version") ? string("Dataset, version ", d["version"]) : "Dataset"
        if accessed && haskey(d, "date-accessed")
            note = string(note, ", accessed ", d["date-accessed"])
        end
        put("note", note)
    end
    put("journal", get(d, "journal", ""))
    put("volume", get(d, "volume", ""))
    put("number", get(d, "issue", ""))
    if haskey(d, "start")
        pages = haskey(d, "end") ? string(d["start"], "--", d["end"]) : string(d["start"])
        put("pages", pages)
    end
    publisher = get(d, "publisher", "")
    put("publisher", publisher isa AbstractDict ? get(publisher, "name", "") : publisher)
    put("doi", cff_doi(d); escape = false)
    put(
        "url",
        software ? get(d, "repository-code", get(d, "url", "")) : get(d, "url", "");
        escape = false,
    )
    entry = BibEntry(type, "", fields)
    entry.key = string(get(d, PACKAGE_KEY_FIELD, mendeley_key(entry)))
    return entry
end

# The entries that credit the origin of the data: the references marked `data-source`.
source_entries(data::AbstractDict = CFF) =
    BibEntry[cff_bibentry(r) for r in cff_references(data, "data-source")]

# Every reference of the file, for the bibliography of the documentation.
documentation_entries(data::AbstractDict = CFF) =
    BibEntry[cff_bibentry(r; accessed = true) for r in cff_references(data)]

# Used when the CFF file given cannot be read.
fallback_package_entries() = BibEntry[BibEntry(
    "misc",
    "alves" * NO_YEAR_KEY * "thermophysicaldb",
    [
        "author" => "Alves, Eduardo Bader Dalfovo Mohr",
        "title" => "ThermophysicalDB.jl",
        "version" => package_version_text(),
        "note" => string("Julia package, version ", package_version_text()),
        "url" => "https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl",
    ],
)]

"""
    package_entries(path = nothing) -> Vector{BibEntry}

The BibTeX entries that credit this package, from its `CITATION.cff`: the software (with
the version, the DOI of the release when the file has one and the repository) and, when the
file has a `preferred-citation`, the article of the package. `path` names another CFF file;
by default the one of the package, which was read when the package was precompiled. A
minimal entry stands in when the file given cannot be read.
"""
function package_entries(path::Union{Nothing,AbstractString} = nothing)
    data = path === nothing ? CFF : read_cff(path)
    data === nothing && return fallback_package_entries()
    entries = BibEntry[cff_bibentry(data; software = true)]
    preferred = get(data, "preferred-citation", nothing)
    preferred isa AbstractDict && push!(entries, cff_bibentry(preferred))
    return entries
end

"""
    write_documentation_bibliography(path)

Write every reference of `CITATION.cff` (the sources of the data, the articles about
them, the work of the group) to `path` as a `.bib` file with the access dates, for the
bibliography of the documentation: `docs/make.jl` calls it, so a new reference is added in
one place only. `extra` names a hand-written `.bib` whose entries are appended, for the
literature that is not about the data.
"""
function write_documentation_bibliography(
    path::AbstractString;
    extra::Union{Nothing,AbstractString} = nothing,
)
    io = IOBuffer()
    println(
        io,
        "% Generated from CITATION.cff by ThermophysicalDB.write_documentation_bibliography.",
    )
    println(io, "% Do not edit: add the reference to CITATION.cff.\n")
    for entry in sort(documentation_entries(); by = e -> e.key)
        render_entry(io, entry)
    end
    if extra !== nothing
        println(io, "% --- ", basename(extra), " (written by hand) ---\n")
        write(io, read(extra))
    end
    write(path, take!(io))
    return path
end
