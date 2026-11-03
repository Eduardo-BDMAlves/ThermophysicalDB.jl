# Looking compounds up in PubChem, on request.
#
# Nothing here runs unless the user asks for it (`fetch_pubchem!`, `online = true`): the
# package never reaches PubChem by itself. What PubChem answers is kept as one JSON file per
# compound in `compounds/pubchem/` (the raw answer, with the date and the question), which is
# the separate table of what came from PubChem. Every time the compound database loads, those
# files are read and laid over the list, and the compounds the user registered go on top of
# both. A question that PubChem could not answer is remembered for 180 days, so that a name
# that does not exist is not asked again and again.

const PUBCHEM_BASE = "https://pubchem.ncbi.nlm.nih.gov/rest/pug"

# The old names of the SMILES properties are asked for, and the answer is read under any of
# the names PubChem has used for them (see `PUBCHEM_SMILES_KEYS`).
const PUBCHEM_PROPERTIES = "MolecularFormula,MolecularWeight,InChI,InChIKey,IUPACName,IsomericSMILES,CanonicalSMILES"
const PUBCHEM_SMILES_KEYS =
    ("SMILES", "IsomericSMILES", "ConnectivitySMILES", "CanonicalSMILES")

"Days for which a question that PubChem could not answer is not asked again."
const PUBCHEM_MISSING_DAYS = 180

# Most synonyms of a compound are registry numbers of little use; the first ones are names.
const PUBCHEM_MAX_NAMES = 25

# PubChem allows at most 5 requests per second and 400 per minute (its usage policy; check it
# at https://pubchem.ncbi.nlm.nih.gov/docs/programmatic-access). The default stays below.
const PUBCHEM_RATE = Ref(3.0)
const PUBCHEM_LAST = Ref(0.0)
const PUBCHEM_PAUSE = Ref{Any}(sleep)

"""
    pubchem_rate!(requests_per_second) -> Float64

Set how many requests per second the package sends to PubChem (default 3). PubChem allows at
most 5 per second and 400 per minute; the package waits between requests so as not to
exceed what you set.
"""
function pubchem_rate!(rate::Real)
    rate > 0 || throw(ArgumentError("the rate must be positive, got $rate"))
    rate > 5 &&
        @warn "PubChem allows at most 5 requests per second; a higher rate may get you blocked" rate
    PUBCHEM_RATE[] = Float64(rate)
    return PUBCHEM_RATE[]
end

function pubchem_wait()
    gap = 1 / PUBCHEM_RATE[]
    pause = PUBCHEM_LAST[] + gap - time()
    pause > 0 && sleep(pause)
    PUBCHEM_LAST[] = time()
    return nothing
end

"""
    PubChemError

Thrown when PubChem cannot be reached or refuses a request, with the address, the HTTP status
(`0` when there was no answer) and what to do about it. Nothing is changed in the database
when it is thrown.
"""
struct PubChemError <: Exception
    url::String
    status::Int
    message::String
end

function Base.showerror(io::IO, e::PubChemError)
    print(io, "PubChemError: ", e.message, "\n  address: ", e.url)
    return print(
        io,
        "\n  The service may be busy or unreachable from here. Try again later, or ",
        "work without the network (online = false). Nothing was changed.",
    )
end

# The transport: returns (HTTP status, body); status 0 when there was no answer.
function pubchem_fetch(method::AbstractString, url::AbstractString, body)
    pubchem_wait()
    out = IOBuffer()
    headers = Pair{String,String}[
        "User-Agent"=>"ThermophysicalDB.jl",
        "Accept"=>"application/json",
    ]
    input = nothing
    if body !== nothing
        push!(headers, "Content-Type" => "application/x-www-form-urlencoded")
        input = IOBuffer(String(body))
    end
    result = Downloads.request(
        String(url);
        method = String(method),
        headers,
        input,
        output = out,
        timeout = 60,
        throw = false,
    )
    result isa Downloads.Response || return 0, brief_error(result)
    return Int(result.status), String(take!(out))
end

const PUBCHEM_FETCH = Ref{Any}(pubchem_fetch)

function percent_encode(text::AbstractString)
    io = IOBuffer()
    for byte in codeunits(text)
        c = Char(byte)
        if isascii(c) && (isletter(c) || isdigit(c) || c in "-._~")
            write(io, byte)
        else
            write(io, '%', uppercase(string(byte; base = 16, pad = 2)))
        end
    end
    return String(take!(io))
end

# Characters that cannot travel safely in the address: the question goes in the body.
needs_post(value::AbstractString) = any(c -> c in "/\\#?%", value)

# One request; the text of the answer, or `nothing` when PubChem says it has nothing (404).
function pubchem_request(
    path::AbstractString;
    body = nothing,
    attempts::Int = 4,
    delays = (2, 5, 10),
)
    url = string(PUBCHEM_BASE, '/', path)
    method = body === nothing ? "GET" : "POST"
    status = 0
    text = ""
    for attempt = 1:attempts
        status, text = PUBCHEM_FETCH[](method, url, body)
        status == 200 && return text
        status == 404 && return nothing
        if status in (0, 429, 500, 502, 503, 504)       # busy or unreachable: try again
            attempt < attempts && PUBCHEM_PAUSE[](delays[min(attempt, length(delays))])
        else
            throw(
                PubChemError(
                    url,
                    status,
                    "PubChem did not accept the request (HTTP $status): $(first(strip(text), 160))",
                ),
            )
        end
    end
    reason =
        status == 0 ? "PubChem did not answer: $(first(strip(text), 160))" :
        "PubChem is busy (HTTP $status)"
    throw(PubChemError(url, status, reason))
end

# ----------------------------------------------------------------------------------
# What a question is
# ----------------------------------------------------------------------------------

function pubchem_kind(text::AbstractString, by::Symbol)
    by in (:auto, :name, :cas, :cid, :inchikey, :inchi, :smiles) || throw(
        ArgumentError(
            "PubChem is searched by :name, :cas, :cid, :inchikey, :inchi or :smiles, got :$by",
        ),
    )
    by == :cas && return :name
    by != :auto && return by
    s = strip(text)
    kind = identifier_kind(s)
    kind == :cas && return :name
    kind == :name && !isempty(s) && all(isdigit, s) && return :cid
    return kind
end

function pubchem_value(text::AbstractString, kind::Symbol)
    s = String(strip(text))
    kind == :smiles && return String(strip(replace(s, r"^(?i:smiles)\s*=\s*" => "")))
    kind == :inchikey && return uppercase(s)
    kind == :cid && return replace(s, r"^(?i:cid)\s*:?\s*" => "")
    return s
end

# ----------------------------------------------------------------------------------
# What PubChem answers
# ----------------------------------------------------------------------------------

jlist(obj, keys...) = begin
    for key in keys
        obj isa AbstractDict || return Any[]
        obj = get(obj, key, nothing)
    end
    return obj isa AbstractVector ? obj : Any[]
end

function pubchem_cids(text::AbstractString)
    doc = JSON.parse(text)
    return Int64[
        Int64(c) for c in jlist(doc, "IdentifierList", "CID") if c isa Real && c > 0
    ]
end

# CID => the properties PubChem gave, as one dictionary per compound.
function parse_pubchem_properties(text::AbstractString)
    out = Dict{Int64,Dict{String,Any}}()
    for entry in jlist(JSON.parse(text), "PropertyTable", "Properties")
        entry isa AbstractDict && haskey(entry, "CID") || continue
        out[Int64(entry["CID"])] = Dict{String,Any}(String(k) => v for (k, v) in entry)
    end
    return out
end

function parse_pubchem_synonyms(text::AbstractString)
    out = Dict{Int64,Vector{String}}()
    for entry in jlist(JSON.parse(text), "InformationList", "Information")
        entry isa AbstractDict && haskey(entry, "CID") || continue
        out[Int64(entry["CID"])] =
            String[String(s) for s in jlist(entry, "Synonym") if s isa AbstractString]
    end
    return out
end

# The check digit of a CAS number: the digits, from the right, weighted 1, 2, 3, ...
function valid_cas(text::AbstractString)
    occursin(CAS_REGEX, text) || return false
    digits = [c - '0' for c in replace(text, '-' => "")]
    check = pop!(digits)
    total = sum(i * d for (i, d) in enumerate(reverse(digits)))
    return total % 10 == check
end

function pubchem_number(value)
    value isa Real && return Float64(value)
    value isa AbstractString || return NaN
    parsed = tryparse(Float64, strip(value))
    return parsed === nothing ? NaN : parsed
end

"""
The keywords of `insert_record!` that one PubChem answer gives: `props` is the dictionary of
properties and `synonyms` the list of synonyms of a compound.
"""
function pubchem_record(props::AbstractDict, synonyms::AbstractVector{<:AbstractString})
    text(key) = (v = get(props, key, ""); v isa AbstractString ? String(strip(v)) : "")
    smiles = ""
    for key in PUBCHEM_SMILES_KEYS
        smiles = text(key)
        isempty(smiles) || break
    end
    cas = ""
    names = String[]
    seen = Set{String}()
    for synonym in synonyms
        s = String(strip(synonym))
        isempty(s) && continue
        if valid_cas(s)
            isempty(cas) && (cas = s)
        elseif length(s) <= 100 && length(names) < PUBCHEM_MAX_NAMES
            lowercase(s) in seen || (push!(seen, lowercase(s)); push!(names, s))
        end
    end
    return (;
        cid = Int64(props["CID"]),
        formula = text("MolecularFormula"),
        molar_mass = pubchem_number(get(props, "MolecularWeight", nothing)),
        inchi = text("InChI"),
        inchikey = text("InChIKey"),
        iupac = text("IUPACName"),
        smiles,
        cas,
        names,
    )
end

# ----------------------------------------------------------------------------------
# The separate table: one JSON file for each compound
# ----------------------------------------------------------------------------------

pubchem_dir(dir::AbstractString) = joinpath(dir, "pubchem")
pubchem_file(dir::AbstractString, cid::Integer) =
    joinpath(pubchem_dir(dir), "CID-$cid.json")
pubchem_missing_path(dir::AbstractString) = joinpath(dir, "pubchem_missing.toml")

function write_pubchem_file(dir, cid, props, synonyms, query)
    path = pubchem_file(dir, cid)
    mkpath(dirname(path))
    document = Dict{String,Any}(
        "cid" => Int64(cid),
        "retrieved" => string(Dates.today()),
        "query" => String(query),
        "properties" => props,
        "synonyms" => synonyms,
    )
    temporary = path * ".part"
    open(io -> write(io, JSON.json(document)), temporary, "w")
    mv(temporary, path; force = true)
    return path
end

function read_pubchem_file(path::AbstractString)
    document = JSON.parse(read(path, String))
    document isa AbstractDict && haskey(document, "properties") ||
        throw(ArgumentError("not a PubChem file of this package"))
    props = Dict{String,Any}(String(k) => v for (k, v) in document["properties"])
    synonyms =
        String[String(s) for s in jlist(document, "synonyms") if s isa AbstractString]
    return props,
    synonyms,
    String(get(document, "retrieved", "")),
    String(get(document, "query", ""))
end

# The text that PubChem matched with a compound is one of its names, even when PubChem
# spells it differently (the case, a hyphen); an identifier is not a name.
function query_name(query::AbstractString)
    q = String(strip(query))
    isempty(q) && return ""
    identifier_kind(q) == :name || return ""
    all(isdigit, q) && return ""
    return q
end

function insert_pubchem!(
    db::CompoundDB,
    props,
    synonyms,
    retrieved;
    query::AbstractString = "",
)
    record = pubchem_record(props, synonyms)
    name = query_name(query)
    if !isempty(name) && !any(n -> normalize_name(n) == normalize_name(name), record.names)
        push!(record.names, name)
    end
    return insert_record!(db; record..., source = "pubchem", retrieved)
end

"Lay the compounds that came from PubChem over the list (see `compound_database`)."
function load_pubchem!(db::CompoundDB, dir::AbstractString)
    folder = pubchem_dir(dir)
    isdir(folder) || return db
    for file in sort!(readdir(folder; join = true))
        endswith(file, ".json") || continue
        try
            props, synonyms, retrieved, query = read_pubchem_file(file)
            insert_pubchem!(db, props, synonyms, retrieved; query)
        catch err
            err isa InterruptException && rethrow()
            @warn "A file from PubChem could not be read and was ignored" file reason =
                sprint(showerror, err)
        end
    end
    return db
end

# Questions PubChem could not answer: "kind:text" => the date it was asked.
function read_pubchem_missing(dir::AbstractString)
    path = pubchem_missing_path(dir)
    isfile(path) || return Dict{String,String}()
    try
        return Dict{String,String}(
            String(k) => String(v) for (k, v) in TOML.parsefile(path)
        )
    catch err
        err isa InterruptException && rethrow()
        @warn "The list of questions PubChem could not answer was ignored" path reason =
            sprint(showerror, err)
        return Dict{String,String}()
    end
end

missing_key(kind::Symbol, value::AbstractString) =
    string(kind, ':', lowercase(strip(value)))

function fresh_missing(entries::AbstractDict, key::AbstractString; today = Dates.today())
    asked = get(entries, key, "")
    isempty(asked) && return false
    date = tryparse(Dates.Date, asked)
    return date !== nothing && Dates.value(today - date) <= PUBCHEM_MISSING_DAYS
end

known_missing(dir::AbstractString, key::AbstractString; today = Dates.today()) =
    fresh_missing(read_pubchem_missing(dir), key; today)

function record_missing!(dir::AbstractString, key::AbstractString)
    entries = read_pubchem_missing(dir)
    entries[key] = string(Dates.today())
    mkpath(dir)
    open(pubchem_missing_path(dir), "w") do io
        TOML.print(io, entries)
    end
    return nothing
end

function forget_missing!(dir::AbstractString, key::AbstractString)
    entries = read_pubchem_missing(dir)
    haskey(entries, key) || return nothing
    delete!(entries, key)
    open(pubchem_missing_path(dir), "w") do io
        TOML.print(io, entries)
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Asking PubChem
# ----------------------------------------------------------------------------------

# The CIDs that a text identifies (empty when PubChem has none).
function pubchem_identify(kind::Symbol, value::AbstractString)
    if kind == :cid
        cid = tryparse(Int64, value)
        return cid === nothing || cid <= 0 ? Int64[] : Int64[cid]
    end
    namespace = kind == :inchikey ? "inchikey" : String(kind)
    answer = if kind in (:smiles, :inchi) || (kind == :name && needs_post(value))
        pubchem_request(
            "compound/$namespace/cids/JSON";
            body = string(namespace, '=', percent_encode(value)),
        )
    else
        pubchem_request("compound/$namespace/$(percent_encode(value))/cids/JSON")
    end
    return answer === nothing ? Int64[] : pubchem_cids(answer)
end

function chunks(items::AbstractVector, size::Int)
    return [items[i:min(i+size-1, end)] for i = 1:size:length(items)]
end

# CID => properties, from the files already kept or else from PubChem.
function pubchem_properties(
    cids::AbstractVector{<:Integer},
    dir::AbstractString;
    refresh::Bool = false,
)
    out = Dict{Int64,Dict{String,Any}}()
    wanted = Int64[]
    for cid in cids
        file = pubchem_file(dir, cid)
        if !refresh && isfile(file)
            try
                out[cid] = read_pubchem_file(file)[1]
                continue
            catch err
                err isa InterruptException && rethrow()
            end
        end
        push!(wanted, cid)
    end
    for part in chunks(wanted, 100)
        answer = pubchem_request(
            "compound/cid/$(join(part, ','))/property/$PUBCHEM_PROPERTIES/JSON",
        )
        answer === nothing || merge!(out, parse_pubchem_properties(answer))
    end
    return out
end

function pubchem_synonyms(cids::AbstractVector{<:Integer})
    out = Dict{Int64,Vector{String}}()
    for part in chunks(collect(Int64, cids), 25)
        answer = pubchem_request("compound/cid/$(join(part, ','))/synonyms/JSON")
        answer === nothing || merge!(out, parse_pubchem_synonyms(answer))
    end
    return out
end

function pubchem_describe(cids, props)
    lines = String[]
    for (n, cid) in enumerate(cids)
        p = get(props, cid, nothing)
        parts = String["CID $cid"]
        if p !== nothing
            for key in ("IUPACName", "MolecularFormula", "InChIKey")
                v = get(p, key, "")
                v isa AbstractString && !isempty(v) && push!(parts, String(v))
            end
            mass = pubchem_number(get(p, "MolecularWeight", nothing))
            isfinite(mass) && push!(parts, "$(mass) g/mol")
        end
        push!(lines, string(lpad(n, 3), ". ", join(parts, "  |  ")))
    end
    return join(lines, '\n')
end

# Which of several CIDs the user means (the `choose` rules of the linked database).
function pubchem_choose(text, cids, props, choose, input::IO, output::IO)
    action, position = choice_for(choose, text)
    listing = pubchem_describe(cids, props)
    refuse() = ArgumentError(
        "\"$text\" matches $(length(cids)) compounds in PubChem:\n$listing\n" *
        "Pass choose = Dict(\"$text\" => n) with the number of the one you mean, " *
        "choose = :all for all of them, or search by InChIKey or CID.",
    )
    action == :all && return cids
    if action == :index
        1 <= position <= length(cids) || throw(
            ArgumentError(
                "\"$text\" has $(length(cids)) candidates, so $position is not a valid answer",
            ),
        )
        return cids[[position]]
    end
    (action == :error || !(input !== stdin || isinteractive())) && throw(refuse())
    println(output, '"', text, "\" matches ", length(cids), " compounds in PubChem:")
    println(output, listing)
    for _ = 1:5
        print(output, "Which one? (1-", length(cids), ", a for all of them, q to cancel): ")
        flush(output)
        answer = lowercase(strip(readline(input)))
        (answer == "q" || answer == "") &&
            throw(ArgumentError("no compound was chosen for \"$text\""))
        answer == "a" && return cids
        n = tryparse(Int, answer)
        n !== nothing && 1 <= n <= length(cids) && return cids[[n]]
        println(output, "Not a valid answer.")
    end
    throw(ArgumentError("no compound was chosen for \"$text\""))
end

"""
    fetch_pubchem!(db, text; by = :auto, choose = :ask, force = false, refresh = false,
                   limit = 10, dir = nothing, input = stdin, output = stdout)
        -> Vector{Int32}

Ask PubChem about `text` and add what it answers to the compound database `db`; returns the
rows of `db` that PubChem described (empty when it has nothing). This is the only place that
uses the network, and it runs only when you call it (or pass `online = true` to
[`lookup_compounds`](@ref), [`points`](@ref) or [`mixture`](@ref)).

If `db` already knows the compound (an exact match of the text with an identifier or a name,
as in [`lookup_compounds`](@ref)) nothing is asked and the rows it has are returned. A name
can describe a different species than the one you mean (`"sulfur"` and hydrogen sulfide, for
example): pass `force = true` to ask PubChem anyway. `refresh = true` does that too, and also
downloads again the compounds that are already kept as files.

`text` is a name, a CAS number (PubChem treats it as a name), an InChIKey, a PubChem CID
(digits only), an InChI, or a SMILES written `"SMILES=CCO"`; `by` (`:name`, `:cas`, `:cid`,
`:inchikey`, `:inchi`, `:smiles`) says what it is. Names and CAS numbers may belong to
several compounds (salts, hydrates, stereoisomers): then they are listed in the order PubChem
gives and you choose, with the same `choose` rules as [`LinkedDatabase`](@ref) (`:ask`,
`:error`, `:all` or a `Dict` of prepared answers). At most `limit` candidates are offered.

What PubChem answers is kept as one JSON file for each compound in `compounds/pubchem/`
(inside `dir`, by default the folder the database was loaded from), with the date and the
question, and `compound_database()` lays those files over the lists in every session. A
question PubChem cannot answer is remembered for $(PUBCHEM_MISSING_DAYS) days and not asked again, unless
`refresh = true`, which also asks again for the compounds that are already kept.

The package waits between requests (3 per second; see [`pubchem_rate!`](@ref)). If PubChem
cannot be reached a [`ThermophysicalDB.PubChemError`](@ref) is thrown and nothing is changed.

```julia
cdb = compound_database()
fetch_pubchem!(cdb, "1-butyl-3-methylimidazolium tetrafluoroborate")
fetch_pubchem!(cdb, "SMILES=CCO")
```
"""
function fetch_pubchem!(
    db::CompoundDB,
    text::AbstractString;
    by::Symbol = :auto,
    choose = :ask,
    force::Bool = false,
    refresh::Bool = false,
    limit::Int = 10,
    dir::Union{Nothing,AbstractString} = nothing,
    input::IO = stdin,
    output::IO = stdout,
)
    limit >= 1 || throw(ArgumentError("limit must be at least 1"))
    folder = String(dir === nothing ? get(db.meta, "dir", compounds_dir()) : dir)
    kind = pubchem_kind(text, by)
    value = pubchem_value(text, kind)
    isempty(value) && throw(ArgumentError("there is nothing to ask PubChem about"))
    if !force && !refresh
        known = lookup_local(db, text; by, limit = 25)
        exact = findall(k -> k ∉ (:contains, :similar), known.match)
        isempty(exact) || return known.id[exact]
    end
    key = missing_key(kind, value)
    if !refresh && known_missing(folder, key)
        @info "PubChem had nothing for \"$text\" when it was asked less than $(PUBCHEM_MISSING_DAYS) days ago; pass refresh = true to ask again"
        return Int32[]
    end
    cids = pubchem_identify(kind, value)
    if isempty(cids)
        record_missing!(folder, key)
        return Int32[]
    end
    length(cids) > limit && (cids = cids[1:limit])
    props = pubchem_properties(cids, folder; refresh)
    filter!(c -> haskey(props, c), cids)
    if isempty(cids)
        record_missing!(folder, key)
        return Int32[]
    end
    chosen =
        length(cids) == 1 ? cids : pubchem_choose(text, cids, props, choose, input, output)
    synonyms = Dict{Int64,Vector{String}}()
    needed = Int64[]
    for cid in chosen
        file = pubchem_file(folder, cid)
        if !refresh && isfile(file)
            try
                synonyms[cid] = read_pubchem_file(file)[2]
                continue
            catch err
                err isa InterruptException && rethrow()
            end
        end
        push!(needed, cid)
    end
    merge!(synonyms, pubchem_synonyms(needed))
    ids = Int32[]
    for cid in chosen
        names = get(synonyms, cid, String[])
        cid in needed && write_pubchem_file(folder, cid, props[cid], names, text)
        push!(
            ids,
            insert_pubchem!(db, props[cid], names, string(Dates.today()); query = text),
        )
    end
    forget_missing!(folder, key)
    return ids
end

# ----------------------------------------------------------------------------------
# The compounds of the archive that the database lacks
# ----------------------------------------------------------------------------------

# Compounds of the archive that have an InChIKey and that the compound database does not know
# (neither by InChIKey nor by InChI).
function unlinked_compounds(ds::Dataset, db::CompoundDB)
    t = ds.compounds
    ex = exact_index(db)
    ids = Int32[]
    for c in eachindex(t.key)
        key = uppercase(t.inchikey[c])
        isempty(key) && continue
        haskey(ex.inchikey, key) && continue
        isempty(t.inchi[c]) || !haskey(ex.inchi, inchi_body(t.inchi[c])) || continue
        push!(ids, Int32(c))
    end
    return ids
end

"""
    prefetch_compounds!(dataset, db = compound_database(); top = 200, refresh = false,
                        progress = true, dir = nothing) -> NamedTuple

Ask PubChem about the most measured compounds of the ThermoML `dataset` that the compound
database `db` does not know, and keep what it answers as [`fetch_pubchem!`](@ref) does.
`top` is the rank that counts: the `top` compounds of the archive with the most points are
considered, those that `db` already knows (by InChIKey or InChI) are skipped, and so are
the ones that PubChem is already known to lack (asked in the last 180 days, unless
`refresh = true`). So `top = 200` asks about nothing new once those 200 are in the database,
and running it again later only asks about what is still missing. It asks by InChIKey, so
the answer is the same compound and there is nothing to choose; compounds without an
InChIKey cannot be asked this way.

Run it once after downloading the archive, to fill the gaps of the lists with the compounds
that matter most; ionic liquids, for example, are among the most measured and are not in the
lists. It can be interrupted and run again: what was kept stays, and nothing is asked twice.
A `LinkedDatabase` is accepted in place of the dataset (call [`link_compounds`](@ref) again
afterwards to refresh the table of links). The result tells how many compounds were
`considered`, how many of those were `unknown` to `db`, and how many were `requested`,
`fetched`, `not_found` and `remembered_missing`.

It needs the network and spaces its requests as [`fetch_pubchem!`](@ref) does (about one
request for each compound asked, 3 per second by default). It can also run when the database
is built: `database(; prefetch_compounds = 200)`.

```julia
db = database()
cdb = compound_database()
prefetch_compounds!(db, cdb; top = 100)
linked = link_compounds(db, cdb)
```
"""
function prefetch_compounds!(
    ds::Dataset,
    db::CompoundDB;
    top::Int = 200,
    refresh::Bool = false,
    progress::Bool = true,
    dir::Union{Nothing,AbstractString} = nothing,
    batch::Int = 25,
)
    top >= 1 || throw(ArgumentError("top must be at least 1"))
    batch >= 1 || throw(ArgumentError("batch must be at least 1"))
    folder = String(dir === nothing ? get(db.meta, "dir", compounds_dir()) : dir)
    t = ds.compounds
    withkey = Int32[Int32(c) for c in eachindex(t.key) if !isempty(t.inchikey[c])]
    counts = point_counts(ds, withkey)
    order = sortperm(counts; rev = true)
    ranked = Int32[withkey[i] for i in order[1:min(top, length(order))] if counts[i] > 0]
    unknown = Set(unlinked_compounds(ds, db))
    entries = read_pubchem_missing(folder)
    todo = Int32[]
    remembered = 0
    nunknown = 0
    for c in ranked
        c in unknown || continue
        nunknown += 1
        if !refresh && fresh_missing(entries, missing_key(:inchikey, t.inchikey[c]))
            remembered += 1
            continue
        end
        push!(todo, c)
    end
    pending = Dict{Int64,Dict{String,Any}}()
    queries = Dict{Int64,String}()
    fetched = 0
    absent = 0
    today = string(Dates.today())
    function flush!()
        isempty(pending) && return nothing
        cids = sort!(collect(keys(pending)))
        synonyms = pubchem_synonyms(cids)
        for cid in cids
            names = get(synonyms, cid, String[])
            write_pubchem_file(folder, cid, pending[cid], names, queries[cid])
            insert_pubchem!(db, pending[cid], names, today; query = queries[cid])
        end
        fetched += length(cids)
        empty!(pending)
        empty!(queries)
        return nothing
    end
    for (n, c) in enumerate(todo)
        key = uppercase(t.inchikey[c])
        answer = pubchem_request(
            "compound/inchikey/$(percent_encode(key))/property/$PUBCHEM_PROPERTIES/JSON",
        )
        found =
            answer === nothing ? Dict{Int64,Dict{String,Any}}() :
            parse_pubchem_properties(answer)
        if isempty(found)
            record_missing!(folder, missing_key(:inchikey, key))
            absent += 1
        else
            for (cid, props) in found
                pending[cid] = props
                queries[cid] = key
            end
            forget_missing!(folder, missing_key(:inchikey, key))
        end
        length(pending) >= batch && flush!()
        progress &&
            (n % 25 == 0 || n == length(todo)) &&
            @info "PubChem: $n of $(length(todo)) compounds asked ($(fetched + length(pending)) found)"
    end
    flush!()
    return (;
        considered = length(ranked),
        unknown = nunknown,
        requested = length(todo),
        fetched,
        not_found = absent,
        remembered_missing = remembered,
    )
end

prefetch_compounds!(ds::Dataset; kwargs...) = prefetch_compounds!(
    ds,
    compound_database(; progress = get(kwargs, :progress, true));
    kwargs...,
)
