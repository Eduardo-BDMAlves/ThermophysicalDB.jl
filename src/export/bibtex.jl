# BibTeX export of the articles behind a selection of points.
#
# For every article of a `DataView` there are two sources of metadata: the entry that the
# DOI resolver delivers (through DOI2BibTeX.jl) and the fields stored in the archive.
# They are compared field by field. The resolver wins wherever both have a field, a field
# that only the archive has is added, and every disagreement is reported. Citation keys
# are the surname of the first author and the year, with the suffixes a, b, c, ... when
# both repeat.

# ----------------------------------------------------------------------------------
# Entries
# ----------------------------------------------------------------------------------

"A BibTeX entry: its type, its key and its fields, in the order they were read."
mutable struct BibEntry
    type::String
    key::String
    fields::Vector{Pair{String,String}}
end

function field_value(entry::BibEntry, name::AbstractString)
    for (k, v) in entry.fields
        k == name && return v
    end
    return nothing
end

const SPACE_BYTES = (UInt8(' '), UInt8('\n'), UInt8('\t'), UInt8('\r'))

"""
    parse_bibtex(text) -> Union{Nothing,BibEntry}

Read the first entry of `text`. Field values may be delimited by braces or quotes, or be
bare tokens (`month = jan`); field names are lower-cased. The scan works on code units:
every delimiter is ASCII, so each slice starts and ends on a character boundary.
"""
function parse_bibtex(text::AbstractString)::Union{Nothing,BibEntry}
    s = String(text)
    n = ncodeunits(s)
    i = 1
    while i <= n && codeunit(s, i) != UInt8('@')
        i += 1
    end
    i > n && return nothing
    j = i + 1
    while j <= n && codeunit(s, j) != UInt8('{')
        j += 1
    end
    j > n && return nothing
    k = j + 1
    while k <= n && codeunit(s, k) != UInt8(',')
        k += 1
    end
    k > n && return nothing
    entry = BibEntry(
        lowercase(String(strip(SubString(s, i + 1, j - 1)))),
        String(strip(SubString(s, j + 1, k - 1))),
        Pair{String,String}[],
    )
    p = k + 1
    while p <= n
        while p <= n && (codeunit(s, p) in SPACE_BYTES || codeunit(s, p) == UInt8(','))
            p += 1
        end
        (p > n || codeunit(s, p) == UInt8('}')) && break
        q = p
        while q <= n && codeunit(s, q) != UInt8('=')
            q += 1
        end
        q > n && return nothing
        name = lowercase(String(strip(SubString(s, p, q - 1))))
        p = q + 1
        while p <= n && codeunit(s, p) in SPACE_BYTES
            p += 1
        end
        p > n && return nothing
        c = codeunit(s, p)
        if c == UInt8('{')
            depth = 1
            q = p + 1
            while q <= n && depth > 0
                b = codeunit(s, q)
                b == UInt8('{') && (depth += 1)
                b == UInt8('}') && (depth -= 1)
                q += 1
            end
            depth == 0 || return nothing
            value = SubString(s, p + 1, q - 2)
            p = q
        elseif c == UInt8('"')
            q = p + 1
            while q <= n &&
                  !(codeunit(s, q) == UInt8('"') && codeunit(s, q - 1) != UInt8('\\'))
                q += 1
            end
            q > n && return nothing
            value = SubString(s, p + 1, q - 1)
            p = q + 1
        else
            q = p
            while q <= n && codeunit(s, q) != UInt8(',') && codeunit(s, q) != UInt8('}')
                q += 1
            end
            value = SubString(s, p, q - 1)
            p = q
        end
        push!(entry.fields, name => String(strip(value)))
    end
    return entry
end

# The resolver escapes an ampersand as an HTML entity followed by a math command, which
# neither BibTeX nor the Markdown converters understand.
function clean_resolver_value(value::AbstractString)
    return replace(value, "&amp\$\\mathsemicolon\$" => "\\&", "&amp;" => "\\&")
end

function clean_resolver_entry!(entry::BibEntry)
    for (idx, (name, value)) in enumerate(entry.fields)
        entry.fields[idx] = name => clean_resolver_value(value)
    end
    return entry
end

"Escape the characters that BibTeX treats as special in plain text."
escape_bibtex(s::AbstractString) = replace(s, r"(?<!\\)([&%#_])" => s"\\\1")

"Turn a page range such as `541-612` into the BibTeX form `541--612`."
normalize_pages(s::AbstractString) = replace(s, r"(?<=\d)\s*[-–—]+\s*(?=\d)" => "--")

# ----------------------------------------------------------------------------------
# The archive side
# ----------------------------------------------------------------------------------

"""
    clean_archive_author(name) -> String

The archive writes some names as `Azizov, N. D.[Nazim D.]`, with the full given name in
brackets after the initials. Keep the full given name: `Azizov, Nazim D.`
"""
function clean_archive_author(name::AbstractString)
    m = match(r"^(.*?)\[(.*)\]\s*$", name)
    m === nothing && return String(name)
    family = strip(first(split(m[1], ',')))
    return string(family, ", ", strip(m[2]))
end

"The entry that the archive itself can write for reference number `r`."
function archive_entry(references::ReferenceTable, r::Integer)
    t = references
    fields = Pair{String,String}[]
    isempty(t.authors[r]) ||
        push!(fields, "author" => join(clean_archive_author.(t.authors[r]), " and "))
    isempty(t.title[r]) || push!(fields, "title" => escape_bibtex(t.title[r]))
    isempty(t.journal[r]) || push!(fields, "journal" => escape_bibtex(t.journal[r]))
    t.year[r] > 0 && push!(fields, "year" => string(t.year[r]))
    isempty(t.volume[r]) || push!(fields, "volume" => t.volume[r])
    isempty(t.pages[r]) || push!(fields, "pages" => normalize_pages(t.pages[r]))
    isempty(t.doi[r]) || push!(fields, "doi" => t.doi[r])
    return BibEntry(isempty(t.journal[r]) ? "misc" : "article", "", fields)
end

# ----------------------------------------------------------------------------------
# Comparing and merging
# ----------------------------------------------------------------------------------

# Fields whose values are compared; the journal is not, because the resolver abbreviates it.
const COMPARED_FIELDS = ("author", "title", "year", "volume", "pages")

"Letters and digits only, without accents or case: the form in which values are compared."
function squash(s::AbstractString)
    folded = Unicode.normalize(String(s); stripmark = true)
    return lowercase(filter(c -> isletter(c) || isdigit(c), folded))
end

function comparison_form(name::AbstractString, value::AbstractString)
    name == "author" && return squash(first_author_surname(value))
    return squash(value)
end

"Surname of the first author of a BibTeX `author` field (`Family, Given and ...`)."
function first_author_surname(authors::AbstractString)
    first_author = strip(first(split(authors, " and "; limit = 2)))
    isempty(first_author) && return ""
    if occursin(',', first_author)
        return String(strip(first(split(first_author, ','))))
    end
    return String(last(split(first_author)))
end

"""
    merge_entries(resolver, archive, doi, conflicts) -> BibEntry

The resolver entry, plus every field only the archive has. A field present in both with
different values (compared without case, accents or punctuation) is appended to
`conflicts`; the value of the resolver is kept.
"""
function merge_entries(
    resolver::BibEntry,
    archive::BibEntry,
    doi::AbstractString,
    conflicts,
)
    merged = BibEntry(resolver.type, "", copy(resolver.fields))
    for (name, archive_value) in archive.fields
        resolver_value = field_value(resolver, name)
        if resolver_value === nothing
            push!(merged.fields, name => archive_value)
        elseif name in COMPARED_FIELDS &&
               comparison_form(name, resolver_value) != comparison_form(name, archive_value)
            push!(
                conflicts,
                (;
                    doi = String(doi),
                    field = name,
                    resolver = resolver_value,
                    archive = archive_value,
                ),
            )
        end
    end
    return merged
end

# ----------------------------------------------------------------------------------
# Citation keys
# ----------------------------------------------------------------------------------

"Surname of the first author as an ASCII citation-key stem; `Anonymous` when unknown."
function key_stem(entry::BibEntry)
    authors = field_value(entry, "author")
    authors === nothing && return "Anonymous"
    surname = Unicode.normalize(first_author_surname(authors); stripmark = true)
    stem = filter(c -> isascii(c) && isletter(c), surname)
    return isempty(stem) ? "Anonymous" : stem
end

"The `n`-th suffix of the sequence a, b, ..., z, aa, ab, ..."
function letter_suffix(n::Integer)
    chars = Char[]
    while n > 0
        n -= 1
        pushfirst!(chars, 'a' + n % 26)
        n = n ÷ 26
    end
    return String(chars)
end

"""
    assign_keys!(entries, reserved)

Set the key of every entry to the surname of its first author followed by the year
(`Chirico2003`; the surname alone when the year is unknown). When two or more entries
share a surname and a year, all of them get a suffix (`Chirico2003a`, `Chirico2003b`, ...)
in the order of their DOI, so the keys of one set do not depend on the order of the
points. Keys in `reserved` are never used.
"""
function assign_keys!(entries::Vector{BibEntry}, reserved = Set{String}())
    groups = Dict{String,Vector{Int}}()
    for (idx, entry) in enumerate(entries)
        year = something(tryparse(Int, something(field_value(entry, "year"), "")), 0)
        base = year > 0 ? string(key_stem(entry), year) : key_stem(entry)
        push!(get!(Vector{Int}, groups, base), idx)
    end
    used = Set{String}(reserved)
    for base in sort!(collect(keys(groups)))
        members = groups[base]
        if length(members) > 1
            sort!(
                members;
                by = idx -> (something(field_value(entries[idx], "doi"), ""), idx),
            )
        end
        for (rank, idx) in enumerate(members)
            key = length(members) == 1 ? base : base * letter_suffix(rank)
            while key in used
                key *= "x"
            end
            entries[idx].key = key
            push!(used, key)
        end
    end
    return entries
end

# ----------------------------------------------------------------------------------
# Fetching, with a cache on disk
# ----------------------------------------------------------------------------------

"File name of a DOI in the cache: everything but letters, digits, `.`, `-` and `_` is percent-encoded."
function cache_name(doi::AbstractString)
    io = IOBuffer()
    for b in codeunits(doi)
        c = Char(b)
        if isascii(c) && (isletter(c) || isdigit(c) || c in ('.', '-', '_'))
            write(io, c)
        else
            write(io, '%', uppercase(string(b; base = 16, pad = 2)))
        end
    end
    return String(take!(io)) * ".bib"
end

bibtex_cache_dir(; create::Bool = false) = subdir("bibtex", create)

default_fetcher(doi::AbstractString) = DOI2BibTeX.doi2bib(String(doi))

"""
    fetch_entry_text(doi; online, cache, refresh, fetcher) -> Union{Nothing,String}

The BibTeX text for `doi`: from the cache if it is there (unless `refresh`), otherwise
from the resolver (unless `online` is false). A reply that is not a BibTeX entry counts
as a failure and is never cached.
"""
function fetch_entry_text(
    doi::AbstractString;
    online::Bool,
    cache::Bool,
    refresh::Bool,
    fetcher,
)::Union{Nothing,String}
    file = joinpath(bibtex_cache_dir(), cache_name(doi))
    if cache && !refresh && isfile(file)
        text = read(file, String)
        parse_bibtex(text) === nothing || return text
    end
    online || return nothing
    for attempt = 1:2
        try
            text = String(fetcher(doi))
            if parse_bibtex(text) !== nothing
                if cache
                    mkpath(bibtex_cache_dir(; create = true))
                    write(file, text)
                end
                return text
            end
        catch err
            attempt == 2 && @debug "No BibTeX entry for DOI" doi exception = err
        end
        attempt == 1 && sleep(0.5)
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# The source of the data, always credited
# ----------------------------------------------------------------------------------

const SOURCE_ENTRIES = (
    """
    @misc{ThermoMLArchive,
      author = {{NIST Thermodynamics Research Center (TRC)}},
      title  = {{ThermoML}/Data Archive},
      year   = {2020},
      note   = {Dataset, National Institute of Standards and Technology},
      doi    = {10.18434/mds2-2422},
      url    = {https://data.nist.gov/od/id/mds2-2422},
    }
    """,
    """
    @article{ThermoMLStandard,
      author  = {Frenkel, Michael and Chirico, Robert D. and Diky, Vladimir and Dong, Qian and Marsh, Kenneth N. and Dymond, John H. and Wakeham, William A. and Stein, Stephen E. and K{\\"o}nigsberger, Erich and Goodwin, Anthony R. H.},
      title   = {{XML}-based {IUPAC} standard for experimental, predicted, and critically evaluated thermodynamic property data storage and capture ({ThermoML}) ({IUPAC} Recommendations 2006)},
      journal = {Pure and Applied Chemistry},
      volume  = {78},
      number  = {3},
      pages   = {541--612},
      year    = {2006},
      doi     = {10.1351/pac200678030541},
    }
    """,
)

source_entries() = [parse_bibtex(text) for text in SOURCE_ENTRIES]

# ----------------------------------------------------------------------------------
# Writing
# ----------------------------------------------------------------------------------

const FIELD_ORDER =
    ("author", "title", "journal", "year", "volume", "number", "pages", "doi")

function render_entry(io::IO, entry::BibEntry)
    print(io, '@', entry.type, '{', entry.key, ",\n")
    written = Set{String}()
    for name in FIELD_ORDER
        value = field_value(entry, name)
        value === nothing && continue
        print(io, "  ", rpad(name, 8), " = {", value, "},\n")
        push!(written, name)
    end
    for (name, value) in entry.fields
        name in written && continue
        print(io, "  ", rpad(name, 8), " = {", value, "},\n")
    end
    print(io, "}\n\n")
    return nothing
end

"""
    BibtexReport

What happened while a bibliography was built: `entries` (articles of the selection),
`resolved` (those whose entry came from the DOI resolver), `archive_only` (DOIs, or titles
when there is no DOI, written from the archive alone) and `conflicts` (fields on which the
resolver and the archive disagree; the value of the resolver is the one written).
"""
struct BibtexReport
    entries::Int
    resolved::Int
    archive_only::Vector{String}
    conflicts::Vector{
        @NamedTuple{doi::String,field::String,resolver::String,archive::String}
    }
end

function Base.show(io::IO, ::MIME"text/plain", r::BibtexReport)
    println(
        io,
        "BibtexReport: ",
        r.entries,
        " articles, ",
        r.resolved,
        " from the DOI resolver",
    )
    println(io, "  written from the archive alone: ", length(r.archive_only))
    print(io, "  fields on which the sources disagree: ", length(r.conflicts))
    return nothing
end

Base.show(io::IO, r::BibtexReport) =
    print(io, "BibtexReport(", r.entries, " articles, ", length(r.conflicts), " conflicts)")

# ----------------------------------------------------------------------------------
# Public interface
# ----------------------------------------------------------------------------------

"""
    Bibliography

The entries behind a selection, ready to be written or summarised: `ids` are the numbers of
the references in the dataset (ascending), `entries[k]` is the entry of `ids[k]` with its key
assigned, `sources` are the entries that credit the ThermoML Archive and its standard, and
`report` tells where each entry came from.
"""
struct Bibliography
    ids::Vector{Int}
    entries::Vector{BibEntry}
    sources::Vector{BibEntry}
    report::BibtexReport
end

function collect_bibliography(
    view::DataView;
    online::Bool = true,
    cache::Bool = true,
    refresh::Bool = false,
    include_source::Bool = true,
    progress::Bool = true,
    fetcher = default_fetcher,
)
    ds = view.dataset
    references = ds.references
    m, ex = ds.measurements, ds.experiments

    # the articles of the selection, each once
    used = falses(length(references))
    for r in view.rows
        ref = ex.reference[m.experiment[r]]
        ref == NO_ID || (used[ref] = true)
    end
    ids = findall(used)

    # the resolver entries, a few requests at a time
    dois = String[references.doi[i] for i in ids if !isempty(references.doi[i])]
    done = Ref(0)
    texts = asyncmap(dois; ntasks = 8) do doi
        text = fetch_entry_text(doi; online, cache, refresh, fetcher)
        done[] += 1
        if progress && online && (done[] % 10 == 0 || done[] == length(dois))
            print(stderr, "\rFetching references: ", done[], "/", length(dois))
            done[] == length(dois) && println(stderr)
        end
        text
    end
    resolver_text = Dict{String,Union{Nothing,String}}(zip(dois, texts))

    entries = BibEntry[]
    archive_only = String[]
    conflicts = @NamedTuple{doi::String, field::String, resolver::String, archive::String}[]
    resolved = 0
    for i in ids
        archive = archive_entry(references, i)
        doi = references.doi[i]
        text = isempty(doi) ? nothing : resolver_text[doi]
        parsed = text === nothing ? nothing : parse_bibtex(text)
        if parsed === nothing
            push!(archive_only, isempty(doi) ? references.title[i] : doi)
            push!(entries, archive)
        else
            resolved += 1
            push!(
                entries,
                merge_entries(clean_resolver_entry!(parsed), archive, doi, conflicts),
            )
        end
    end

    sources = include_source ? source_entries() : BibEntry[]
    assign_keys!(entries, Set{String}(e.key for e in sources))
    report = BibtexReport(length(ids), resolved, archive_only, conflicts)
    return Bibliography(ids, entries, sources, report)
end

function render_bibliography(b::Bibliography)
    io = IOBuffer()
    for entry in b.sources
        render_entry(io, entry)
    end
    for entry in sort(b.entries; by = e -> lowercase(e.key))
        render_entry(io, entry)
    end
    return String(take!(io))
end

build_bibliography(view::DataView; kwargs...) =
    (b = collect_bibliography(view; kwargs...); (render_bibliography(b), b.report))

build_bibliography(ds::Dataset; kwargs...) = build_bibliography(DataView(ds); kwargs...)

"""
    bibtex(view; online = true, cache = true, refresh = false, include_source = true,
           progress = true) -> String

BibTeX entries of every article behind the points of `view` (a [`DataView`](@ref), or a
[`Dataset`](@ref) for all of them), one entry per article.

For each article the entry delivered by the DOI resolver is compared with the metadata
stored in the archive. The resolver is used wherever both have a field, a field that only
the archive has is added, and the fields on which they disagree are listed by
[`write_bibtex`](@ref). An article whose DOI cannot be resolved is written from the
archive alone.

The key of an entry is the surname of its first author followed by the year, for example
`Chirico2003`. When two entries share a surname and a year, both get the suffixes `a`,
`b`, `c`, ... in the order of their DOI (`Chirico2003a`, `Chirico2003b`).

# Keywords
- `online`: contact the resolver. With `false` only the cache and the archive are used.
- `cache`: keep the entries delivered by the resolver in `database_dir()/bibtex`, so each
  DOI is requested once.
- `refresh`: ignore the cache and request every DOI again.
- `include_source`: add the entries for the ThermoML Archive and for the ThermoML
  standard, which credit the origin of the data.
- `progress`: print the number of DOIs fetched.

# Examples
```julia
db = database()
v = points(db; component = "water", exact = true, property = "Mass density")
print(bibtex(v))
```
"""
bibtex(view::DataView; kwargs...) = first(build_bibliography(view; kwargs...))

bibtex(ds::Dataset; kwargs...) = bibtex(DataView(ds); kwargs...)

"""
    write_bibtex(path, view; kwargs...) -> BibtexReport

Write [`bibtex`](@ref)`(view; kwargs...)` to `path` and return a report: how many entries
came from the DOI resolver, which were written from the archive alone, and the fields on
which the two disagree.
"""
function write_bibtex(path::AbstractString, view::DataView; kwargs...)
    text, report = build_bibliography(view; kwargs...)
    write(path, text)
    return report
end

write_bibtex(path::AbstractString, ds::Dataset; kwargs...) =
    write_bibtex(path, DataView(ds); kwargs...)
