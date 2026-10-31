# Maintenance check of the references in `CITATION.cff`.
#
# Two kinds of check. The structural ones need nothing but the file: every reference has the
# fields the package relies on, a valid keyword, and a key (`abbreviation`) that is the one
# the pattern of the reference manager gives, so a key never has to be chosen by hand. The
# second kind asks the DOI resolver (through DOI2BibTeX.jl, with the cache of `bibtex`) for
# the record of each article and compares it field by field with the file, a second,
# independent source for authors, title, year, journal, volume and pages.

const REFERENCE_KEYWORDS = ("data-source", "group", "background")

"""
    ReferenceCheck

The result of [`check_references`](@ref): `problems` (what is wrong in the file itself),
`conflicts` (fields on which the resolver disagrees with the file), `unresolved` (the key,
DOI and reason of every article whose record could not be fetched), `skipped` (keys of types
that are not compared, such as datasets) and `compared` (how many articles were compared).
`notes` are differences that are not errors: a year that differs by one while volume and
pages agree (the DOI record gives the date of online publication, the citation the one of the
issue). `strict` tells whether an unresolved article counts as a failure, which it does when the
network was used: a check that could not ask the resolver has not checked anything.
"""
struct ReferenceCheck
    problems::Vector{String}
    conflicts::Vector{
        @NamedTuple{key::String,doi::String,field::String,file::String,resolver::String}
    }
    unresolved::Vector{@NamedTuple{key::String,doi::String,reason::String}}
    skipped::Vector{String}
    compared::Int
    strict::Bool
    notes::Vector{
        @NamedTuple{key::String,doi::String,field::String,file::String,resolver::String}
    }
end

"Whether the references passed every check that could be made."
Base.isempty(c::ReferenceCheck) =
    isempty(c.problems) && isempty(c.conflicts) && !(c.strict && !isempty(c.unresolved))

function Base.show(io::IO, c::ReferenceCheck)
    print(
        io,
        "ReferenceCheck: ",
        c.compared,
        " compared with the DOI resolver, ",
        length(c.skipped),
        " skipped, ",
        length(c.unresolved),
        " unresolved, ",
        length(c.problems),
        " problems, ",
        length(c.conflicts),
        " conflicts",
    )
    for p in c.problems
        print(io, "\n  problem: ", p)
    end
    for u in c.unresolved
        print(io, "\n  unresolved: ", u.key, " (", u.doi, "): ", u.reason)
    end
    for x in c.notes
        print(
            io,
            "\n  note: ",
            x.key,
            " (",
            x.doi,
            "), ",
            x.field,
            ": file `",
            x.file,
            "`, resolver `",
            x.resolver,
            "` (online and issue dates differ)",
        )
    end
    for x in c.conflicts
        print(
            io,
            "\n  ",
            x.key,
            " (",
            x.doi,
            "), ",
            x.field,
            ": file `",
            x.file,
            "`, resolver `",
            x.resolver,
            "`",
        )
    end
    return nothing
end

# The surnames of all the authors of a BibTeX `author` field, as they are compared.
author_surnames(value::AbstractString) =
    [squash(first_author_surname(a)) for a in split(value, " and ")]

function compare_with_resolver!(
    conflicts,
    key,
    doi,
    entry::BibEntry,
    resolver::BibEntry,
    notes = conflicts,
)
    same_issue = all(
        n ->
            field_value(entry, n) !== nothing &&
            field_value(resolver, n) !== nothing &&
            squash(field_value(entry, n)) == squash(field_value(resolver, n)),
        ("volume", "pages"),
    )
    for name in COMPARED_FIELDS
        mine, theirs = field_value(entry, name), field_value(resolver, name)
        (mine === nothing || theirs === nothing) && continue
        same = if name == "author"
            author_surnames(mine) == author_surnames(theirs)
        else
            squash(mine) == squash(theirs)
        end
        same && continue
        item = (; key, doi, field = name, file = mine, resolver = theirs)
        year_apart =
            name == "year" &&
            abs(something(tryparse(Int, mine), 0) - something(tryparse(Int, theirs), 0)) ==
            1
        push!(year_apart && same_issue ? notes : conflicts, item)
    end
    return conflicts
end

# What every reference must have, and the key it must carry.
function check_structure!(problems, d::AbstractDict, label::AbstractString, keys_seen)
    isempty(string(get(d, "title", ""))) && push!(problems, "$label has no title")
    authors = get(d, "authors", nothing)
    (authors isa AbstractVector && !isempty(authors)) ||
        push!(problems, "$label has no authors")
    isempty(cff_year(d)) && push!(problems, "$label has no year")
    type_name = string(get(d, "type", "article"))
    type_name == "article" &&
        isempty(cff_doi(d)) &&
        push!(problems, "$label is an article without a DOI")
    keywords = cff_keywords(d)
    if isempty(keywords) || !all(in(REFERENCE_KEYWORDS), keywords)
        push!(
            problems,
            "$label needs keywords from $(join(REFERENCE_KEYWORDS, ", ")), has $keywords",
        )
    end
    key = get(d, PACKAGE_KEY_FIELD, nothing)
    if key === nothing
        push!(problems, "$label has no `abbreviation` (the citation key)")
    else
        wanted = mendeley_key(cff_bibentry(delete!(copy(d), PACKAGE_KEY_FIELD)))
        string(key) == wanted || push!(
            problems,
            "$label: the key `$key` should be `$wanted` (surname, year, first word of the title)",
        )
        string(key) in keys_seen && push!(problems, "$label: the key `$key` is used twice")
        push!(keys_seen, string(key))
    end
    return problems
end

"""
    check_references(path = nothing; online = true, cache = true, refresh = false,
                     skip_types = ("data", "software"), fetcher = default_fetcher,
                     require_resolver = online)
        -> ReferenceCheck

Check the references of `CITATION.cff` (the file of the package by default).

Structure, always: every reference has a title, authors, a year, a DOI when it is an article,
keywords among `data-source`, `group` and `background`, and an `abbreviation` that is the
key of the pattern of the reference manager (`riccardi2021thermoml`); keys are unique;
there is exactly one dataset marked `data-source`.

Two-factor check, for the articles: the record of each DOI is requested from the DOI resolver
(DOI2BibTeX.jl, the cache of [`bibtex`](@ref) is used) and its authors, title, year, volume
and pages are compared with the file. Types in `skip_types` are not compared: a dataset has
no authors in its DOI record. With `online = false` only the cache answers; the DOIs that it
does not hold are listed as `unresolved` with the reason, and count as a failure only if
`require_resolver` is true, which is the default whenever the network is used.

```julia
using ThermophysicalDB
ThermophysicalDB.check_references()
```
"""
function check_references(
    path::Union{Nothing,AbstractString} = nothing;
    online::Bool = true,
    cache::Bool = true,
    refresh::Bool = false,
    skip_types = ("data", "software"),
    fetcher = default_fetcher,
    require_resolver::Bool = online,
)
    data = path === nothing ? CFF : read_cff(path)
    data === nothing && throw(ArgumentError("cannot read the citation file $path"))
    problems = String[]
    conflicts = @NamedTuple{
        key::String,
        doi::String,
        field::String,
        file::String,
        resolver::String,
    }[]
    notes = @NamedTuple{
        key::String,
        doi::String,
        field::String,
        file::String,
        resolver::String,
    }[]
    unresolved = @NamedTuple{key::String, doi::String, reason::String}[]
    skipped = String[]
    compared = 0
    keys_seen = Set{String}()

    sources = filter(r -> get(r, "type", "") == "data", cff_references(data, "data-source"))
    length(sources) == 1 || push!(
        problems,
        "exactly one reference of type `data` must have the keyword `data-source`, found $(length(sources))",
    )

    records = Tuple{String,Dict{String,Any}}[]
    preferred = get(data, "preferred-citation", nothing)
    preferred isa AbstractDict &&
        push!(records, ("preferred-citation", Dict{String,Any}(preferred)))
    for r in cff_references(data)
        push!(records, (string(get(r, PACKAGE_KEY_FIELD, get(r, "title", "?"))), r))
    end
    for (label, r) in records
        label == "preferred-citation" ||
            check_structure!(problems, r, "reference `$label`", keys_seen)
    end

    for (label, r) in records
        doi = cff_doi(r)
        isempty(doi) && continue
        if string(get(r, "type", "article")) in skip_types
            push!(skipped, label)
            continue
        end
        text, reason = fetch_entry(doi; online, cache, refresh, fetcher)
        resolver = text === nothing ? nothing : parse_bibtex(text)
        if resolver === nothing
            push!(unresolved, (; key = label, doi, reason))
            continue
        end
        compared += 1
        compare_with_resolver!(
            conflicts,
            label,
            doi,
            cff_bibentry(r),
            clean_resolver_entry!(resolver),
            notes,
        )
    end
    return ReferenceCheck(
        problems,
        conflicts,
        unresolved,
        skipped,
        compared,
        require_resolver,
        notes,
    )
end
