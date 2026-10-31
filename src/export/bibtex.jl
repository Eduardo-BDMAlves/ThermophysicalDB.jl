# BibTeX export of the articles behind a selection of points.
#
# For every article of a `DataView` there are two sources of metadata: the entry that the
# DOI resolver delivers (through DOI2BibTeX.jl) and the fields stored in the archive.
# They are compared field by field. The resolver wins wherever both have a field, a field
# that only the archive has is added, and every disagreement is reported. Citation keys
# have the form of the reference manager's: surname of the first author, year and first
# word of the title, in lower case (`myers1999surfaces`), with the suffixes a, b, c, ...
# when all three repeat.

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
        value = clean_resolver_value(value)
        entry.fields[idx] = name => (name == "pages" ? normalize_pages(value) : value)
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

# Letters that do not decompose into a letter and a mark.
const FOLDED_LETTERS = Dict(
    'ß' => "ss",
    'ø' => "o",
    'Ø' => "O",
    'æ' => "ae",
    'Æ' => "AE",
    'œ' => "oe",
    'Œ' => "OE",
    'ł' => "l",
    'Ł' => "L",
    'đ' => "d",
    'Đ' => "D",
    'ı' => "i",
)

# TeX accent commands (`{\"o}`, `\'e`) as the plain letter.
const TEX_ACCENT = r"\\[`'^\"~=.uvHcdbkr]\s*\{?([A-Za-z])\}?"

"ASCII text: accents are dropped and the letters that do not decompose are spelled out."
function ascii_fold(s::AbstractString)
    text = replace(String(s), TEX_ACCENT => s"\1", "\\ss" => "ss")
    io = IOBuffer()
    for c in Unicode.normalize(text; stripmark = true)
        if haskey(FOLDED_LETTERS, c)
            write(io, FOLDED_LETTERS[c])
        elseif isascii(c)
            write(io, c)
        end
    end
    return String(take!(io))
end

# What stands for a missing year or author in a key.
const NO_YEAR_KEY = "sd"
const NO_AUTHOR_KEY = "anonymous"

"""
Surname of the first author as an ASCII, lower case stem: particles are joined to it
(`da Costa` gives `dacosta`) and hyphens and spaces vanish; `anonymous` when unknown.
"""
function key_stem(entry::BibEntry)
    authors = field_value(entry, "author")
    authors === nothing && return NO_AUTHOR_KEY
    stem = lowercase(filter(isletter, ascii_fold(first_author_surname(authors))))
    return isempty(stem) ? NO_AUTHOR_KEY : stem
end

"The year of an entry for its key; `sd` (no date) when it has none."
function key_year(entry::BibEntry)
    year = something(tryparse(Int, strip(something(field_value(entry, "year"), ""))), 0)
    return year > 0 ? string(year) : NO_YEAR_KEY
end

"""
The first word of the title, lower case and ASCII: the first run of letters and digits, so
`Particle-stabilized` gives `particle`, and `The` or `A` are words like any other.
"""
function key_word(entry::BibEntry)
    title = ascii_fold(something(field_value(entry, "title"), ""))
    m = match(r"[A-Za-z0-9]+", title)
    return m === nothing ? "" : lowercase(m.match)
end

"""
    mendeley_key(entry) -> String

The key of the pattern of the reference manager: the surname of the first author, the year
and the first word of the title, in lower case, as in `myers1999surfaces`.
"""
mendeley_key(entry::BibEntry) = string(key_stem(entry), key_year(entry), key_word(entry))

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

Set the key of every entry to [`mendeley_key`](@ref) (`myers1999surfaces`: surname, year
and first word of the title). When two or more entries give the same key, all of them get a
suffix (`smith2001thermala`, `smith2001thermalb`, ...) in the order of their DOI, so the
keys of one set do not depend on the order of the points. Keys in `reserved` are never used.
"""
function assign_keys!(entries::Vector{BibEntry}, reserved = Set{String}())
    groups = Dict{String,Vector{Int}}()
    for (idx, entry) in enumerate(entries)
        push!(get!(Vector{Int}, groups, mendeley_key(entry)), idx)
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

# DOI2BibTeX returns a `Citation`, which is not a string: its text is what it displays.
citation_text(reply::AbstractString) = String(reply)
citation_text(reply) = sprint(show, MIME"text/plain"(), reply)

default_fetcher(doi::AbstractString) = citation_text(DOI2BibTeX.doi2bib(String(doi)))

"""
    fetch_entry(doi; online, cache, refresh, fetcher) -> (text, reason)

The BibTeX text for `doi`: from the cache if it is there (unless `refresh`), otherwise
from the resolver (unless `online` is false). A reply that is not a BibTeX entry counts
as a failure and is never cached. When there is no text, `reason` says why: that the
cache does not hold it and the network is off, the error the resolver raised, or what its
reply looked like.
"""
function fetch_entry(
    doi::AbstractString;
    online::Bool,
    cache::Bool,
    refresh::Bool,
    fetcher,
)::Tuple{Union{Nothing,String},String}
    file = joinpath(bibtex_cache_dir(), cache_name(doi))
    if cache && !refresh && isfile(file)
        text = read(file, String)
        parse_bibtex(text) === nothing || return text, ""
    end
    online || return nothing, "not in the cache, and online = false"
    reason = ""
    for attempt = 1:2
        try
            reply = fetcher(doi)
            text = citation_text(reply)
            if parse_bibtex(text) !== nothing
                if cache
                    mkpath(bibtex_cache_dir(; create = true))
                    write(file, text)
                end
                return text, ""
            end
            reason = string(
                "the reply (a ",
                typeof(reply),
                ") is not a BibTeX entry: ",
                repr(first(text, 80)),
            )
        catch err
            err isa InterruptException && rethrow()
            reason = string("the resolver raised ", sprint(showerror, err))
            attempt == 2 && @debug "No BibTeX entry for DOI" doi exception = err
        end
        attempt == 1 && sleep(0.5)
    end
    return nothing, reason
end

"The text of [`fetch_entry`](@ref) alone: `nothing` when there is none."
fetch_entry_text(doi::AbstractString; kwargs...) = first(fetch_entry(doi; kwargs...))

# ----------------------------------------------------------------------------------
# The source of the data, always credited
# ----------------------------------------------------------------------------------

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
assigned, `sources` are the entries that credit the ThermoML Archive and its standard,
`package` the entries of this package, and
`report` tells where each entry came from; `from_archive` tells whether the points come
from the ThermoML Archive, in which case the file starts with its notice.
"""
struct Bibliography
    ids::Vector{Int}
    entries::Vector{BibEntry}
    sources::Vector{BibEntry}
    package::Vector{BibEntry}
    report::BibtexReport
    from_archive::Bool
end

function collect_bibliography(
    view::DataView;
    online::Bool = true,
    cache::Bool = true,
    refresh::Bool = false,
    include_source::Bool = true,
    include_package::Bool = true,
    package_cff::Union{Nothing,AbstractString} = nothing,
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
    package = include_package ? package_entries(package_cff) : BibEntry[]
    assign_keys!(entries, Set{String}(e.key for e in Iterators.flatten((sources, package))))
    report = BibtexReport(length(ids), resolved, archive_only, conflicts)
    return Bibliography(ids, entries, sources, package, report, from_archive(view))
end

# The notice as a BibTeX `@comment`, which BibTeX and biber ignore.
function render_notice(io::IO)
    println(io, "@comment{")
    for line in notice_lines()
        println(io, "  ", line)
    end
    println(io, "}\n")
    return nothing
end

# The request to cite this package, as a BibTeX `@comment`, in front of its entries.
function render_package_request(io::IO, package::Vector{BibEntry})
    keys = join((e.key for e in package), ", ")
    println(io, "@comment{")
    println(
        io,
        "  This file was written by ThermophysicalDB.jl. If the package was useful to your",
    )
    println(io, "  work, please consider citing it: the entries that follow (", keys, ").")
    println(io, "}\n")
    return nothing
end

function render_bibliography(b::Bibliography)
    io = IOBuffer()
    b.from_archive && render_notice(io)
    for entry in b.sources
        render_entry(io, entry)
    end
    if !isempty(b.package)
        render_package_request(io, b.package)
        for entry in b.package
            render_entry(io, entry)
        end
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
           include_package = true, progress = true) -> String

BibTeX entries of every article behind the points of `view` (a [`DataView`](@ref), or a
[`Dataset`](@ref) for all of them), one entry per article.

For each article the entry delivered by the DOI resolver is compared with the metadata
stored in the archive. The resolver is used wherever both have a field, a field that only
the archive has is added, and the fields on which they disagree are listed by
[`write_bibtex`](@ref). An article whose DOI cannot be resolved is written from the
archive alone.

The key of an entry has the form of the reference manager's: the surname of the first
author, the year and the first word of the title, in lower case and without accents, for
example `chirico2003thermoml`. When two entries give the same key, both get the suffixes
`a`, `b`, `c`, ... in the order of their DOI.

# Keywords
- `online`: contact the resolver. With `false` only the cache and the archive are used.
- `cache`: keep the entries delivered by the resolver in `database_dir()/bibtex`, so each
  DOI is requested once.
- `refresh`: ignore the cache and request every DOI again.
- `include_source`: add the entries for the ThermoML Archive and for the ThermoML
  standard, which credit the origin of the data.
- `include_package`: add the entry of this package, read from its `CITATION.cff` (the
  version in use, its DOI when the file has one and the article of the package when the
  file lists it), preceded by a comment asking you to cite it. Nothing in the tables refers
  to it.
- `package_cff`: another file to read it from; by default the `CITATION.cff` of the package.
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
