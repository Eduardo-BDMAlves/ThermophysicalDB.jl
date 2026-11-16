# The ThermoML dataset joined with the compound database.
#
# A `Database` can have the compound database attached. The dataset is never changed: the
# compound database sits beside it, and lets a compound be named by anything either of them
# knows (a synonym, a CAS number, a PubChem CID, an InChI, a SMILES). When a text leads to
# more than one compound of the dataset the user chooses, because the dataset is the
# reference and a guess would silently change what is measured.
#
# What it costs: nothing until it is used. `database()` only remembers how to load the compound
# database; it is loaded the first time a text has to be understood. The table of links between
# the two (one row for each candidate of each compound) is built the first time it is looked at
# (`link_table`, or the menu of an ambiguous text) and forgotten when a member changes.

# ----------------------------------------------------------------------------------
# Attaching the compound database
# ----------------------------------------------------------------------------------

# The attached compound database, loading it the first time when `database()` said to. A failure
# (no cache and no network, for example) is a warning, and the database goes on as it was without
# one: a name is then understood the way the dataset spells it.
function compounds_of(db::Database)
    db.compounds === nothing || return db.compounds
    loader = db.compound_loader
    loader === nothing && return nothing
    db.compound_loader = nothing    # one attempt
    try
        db.compounds = loader()
    catch err
        err isa InterruptException && rethrow()
        @warn "The compound database could not be loaded, so compounds can only be named the way the dataset spells them. Use `link_compounds!(db, compound_database())` when it is available" reason =
            sprint(showerror, err)
    end
    return db.compounds
end

# `compound_library`: `true` loads `compound_database()` when it is first needed, a function does the
# loading its own way, a compound database is attached at once, `false` attaches nothing.
function attach_library!(db::Database, library::Bool, progress::Bool)
    library && (db.compound_loader = () -> compound_database(; progress))
    return db
end
attach_library!(db::Database, library::Function, ::Bool) =
    (db.compound_loader = library; db)
attach_library!(db::Database, library::CompoundDB, ::Bool) = link_compounds!(db, library)

# What was worked out from the members and the compound database, and the answers that the user
# gave, are forgotten when either changes.
function forget_links!(db::Database)
    db.links = nothing
    empty!(db.choices)
    return db
end

"""
    link_compounds!(db, compounds; by_name = true) -> db

Attach the compound database `compounds` ([`compound_database`](@ref)) to the `Database` `db`.
[`database`](@ref) does this by default (`compound_library = true`), loading the compound
database the first time it is needed, so this is for a compound database of your own, or for a
`database(; compound_library = false)`.

A compound can then be named by anything the compound database knows (a synonym, a CAS number,
a PubChem CID, an InChI or a SMILES) in [`points`](@ref), [`mixture`](@ref) and
[`find_compounds`](@ref), whichever name each database uses:

```julia
db = database()
points(db; component = "oxidane", property = "Mass density")      # a synonym, not in any article
mixture(db, "7732-18-5", "64-17-5")                                 # water + ethanol, by CAS number
```

The compounds are matched with the dataset by the InChIKey first, then the InChI, then the names
(with the usual spelling variants); `by_name = false` leaves the names out. A compound found only
by name is marked `via = :name` in [`link_table`](@ref), because a name can describe more than one
species: trust such a link only when `formula_check` and `inchi_check` are `:same`, and treat
`:stereo` (the same skeleton with other stereochemistry or isotopes) and `:different` (a hydrate
and its anhydrous salt, for example) as a related compound, not as the same one. The databases are
not modified.

A text that leads to a single compound is used as it is. When it leads to several (a formula
shared by isomers, a name used for different species), the candidates are listed with their
formula, InChIKey, CAS number and number of points, and the user answers with a number, `a`
for all of them or `q` to cancel. The keyword `choose` of `points`, `mixture` and
`find_compounds`-based searches decides how:

- `choose = :ask` (default): ask in the terminal when the session is interactive
  (`isinteractive()` and the output is the terminal); otherwise throw an `ArgumentError` that lists
  the candidates.
- `choose = :error`: never ask, always throw.
- `choose = :all`: take every exact candidate. A text with no exact candidate is never
  accepted this way.
- `choose = Dict("butane" => 2, "C4H10" => :all)`: a prepared answer for each text, by the
  number the menu would show, so a script does not stop to ask.

With `online = true` a text that neither database knows is asked of PubChem
([`fetch_pubchem!`](@ref)) before giving up: what PubChem answers is kept in the compound
database, so it is found again without the network. The compounds that PubChem lists for the
text have their own menu, whose prepared answers are the entries of `choose` with a key that
starts with `"pubchem:"` (`Dict("pubchem:glucose" => 1)`). A compound added this way is joined to
the dataset by its InChIKey.

`input` and `output` (default `stdin` and `stdout`) say where the question is read and
written. The answers given are kept and used again for the same text; call
[`forget_choices!`](@ref) to clear them. The candidates are ordered by number of points and
then by name, so a number means the same thing every time on the same data.
"""
function link_compounds!(db::Database, compounds::CompoundDB; by_name::Bool = true)
    db.compounds = compounds
    db.compound_loader = nothing
    db.by_name = by_name
    forget_links!(db)
    return db
end

"""
    link_compounds(ds::Dataset, compounds; by_name = true) -> Database

A `Database` of the single dataset `ds` with the compound database attached (see
[`link_compounds!`](@ref)). The dataset is not modified.
"""
function link_compounds(ds::Dataset, compounds::CompoundDB; by_name::Bool = true)
    return link_compounds!(Database(ds), compounds; by_name)
end

"""
    forget_choices!(db) -> db

Clear the answers that `db` remembers for the ambiguous texts it was asked about, so the next
ambiguous text asks again.
"""
function forget_choices!(db::Database)
    empty!(db.choices)
    return db
end

# The tables of links of the members, in the order of `members(db)`, built on first use.
function ensure_links!(db::Database)::Vector{CompoundLinks}
    existing = db.links
    existing === nothing || return existing
    cdb = compounds_of(db)
    cdb === nothing && throw(
        ArgumentError(
            "this database has no compound database attached; use `link_compounds!(db, " *
            "compound_database())`",
        ),
    )
    built = CompoundLinks[
        compound_links(member_dataset(m), cdb; by_name = db.by_name) for m in db.members
    ]
    db.links = built
    return built
end

"""
    link_table(db) -> NamedTuple

The links between the compounds of the databases and the compound database, as the columns of a
Tables.jl table: one row for each candidate of each compound of each member (the column `database`
says which), with how the link was found (`via`), how many candidates the compound has and
whether the formula and the InChI agree. Throws an `ArgumentError` when no compound database is
attached.
"""
function link_table(db::Database)
    links = ensure_links!(db)
    cols = [Tables.columns(x) for x in links]
    names = keys(first(cols))
    merged = NamedTuple{names}(map(k -> reduce(vcat, (c[k] for c in cols)), names))
    database = reduce(vcat, [fill(m.name, length(x)) for (m, x) in zip(db.members, links)])
    return merge(merged, (; database))
end

# What `show` says about the compound database of a `Database`.
function compounds_state(db::Database)
    cdb = db.compounds
    cdb === nothing || return "compound database attached ($(length(cdb)) compounds)"
    db.compound_loader !== nothing &&
        return "compound database attached (loaded when a name has to be understood)"
    return "no compound database attached (link_compounds!)"
end

prefetch_compounds!(db::Database; kwargs...) =
    prefetch_with_compounds!(db, compounds_of(db); kwargs...)

function prefetch_with_compounds!(db::Database, cdb::CompoundDB; kwargs...)
    found = prefetch_compounds!(sole_dataset(db), cdb; kwargs...)
    forget_links!(db)
    return found
end
prefetch_with_compounds!(::Database, ::Nothing; kwargs...) = throw(
    ArgumentError(
        "this database has no compound database attached; give one, " *
        "`prefetch_compounds!(db, compound_database())`",
    ),
)

lookup_compounds(db::Database, text::AbstractString; kwargs...) =
    lookup_compounds(attached_compounds(db), text; kwargs...)

# The compound database, or an error that says how to get one.
function attached_compounds(db::Database)
    cdb = compounds_of(db)
    cdb === nothing && throw(
        ArgumentError(
            "this database has no compound database attached; use `link_compounds!(db, " *
            "compound_database())`",
        ),
    )
    return cdb
end

compound_source(db::Database) = compounds_of(db)

# ----------------------------------------------------------------------------------
# Choosing among candidates
# ----------------------------------------------------------------------------------

choice_key(text::AbstractString) = lowercase(strip(text))

# The answers prepared for the menu of PubChem are the entries of `choose` whose key starts
# with "pubchem:"; the others belong to the menu of the dataset.
function pubchem_choice(choose)
    choose isa AbstractDict || return choose
    prefix = "pubchem:"
    return Dict{String,Any}(
        String(strip(string(k)[(length(prefix)+1):end])) => v for
        (k, v) in choose if startswith(lowercase(string(k)), prefix)
    )
end

subset(m::CompoundMatches, idx::AbstractVector{<:Integer}) = CompoundMatches(
    m.query,
    m.id[idx],
    m.name[idx],
    m.formula[idx],
    m.inchikey[idx],
    m.points[idx],
    m.match[idx],
)

# True when the compound database knows the text (an exact match) and the compound has an
# InChIKey: asking PubChem would bring the same compound, so the dataset simply has no data
# for it. A compound without an InChIKey cannot be joined to the dataset, so PubChem is asked.
function known_with_inchikey(db::CompoundDB, text::AbstractString)
    known = lookup_compounds(db, text; limit = 25)
    return any(
        k ∉ (:contains, :similar) && !isempty(db.inchikey[id]) for
        (id, k) in zip(known.id, known.match)
    )
end

# The compounds that can be what `text` means: the exact ones when there are any, otherwise
# the close ones. Ordered by number of points and then by name, so that a menu number is
# reproducible.
function candidate_compounds(
    db::Database,
    cdb::CompoundDB,
    text::AbstractString;
    online::Bool = false,
    choose = :ask,
    input::IO = stdin,
    output::IO = stdout,
)
    found = find_compounds(db, cdb, text; limit = 20)
    if online && !any(==(:exact), found.match) && !known_with_inchikey(cdb, text)
        fetched = fetch_pubchem!(
            cdb,
            text;
            choose = pubchem_choice(choose),
            force = true,
            input,
            output,
        )
        isempty(fetched) || (found = find_compounds(db, cdb, text; limit = 20))
        isempty(fetched) || forget_links!(db)
        if isempty(fetched) && isempty(found)
            @info "\"$text\" is not in the compound database and PubChem has nothing for it"
        end
    end
    if isempty(found)
        records = lookup_compounds(cdb, text; limit = 1)
        known = !isempty(records) && records.match[1] ∉ (:contains, :similar)
        known || no_such_compound(db, text)    # throws with the usual spelling hints
        throw(
            ArgumentError(
                "\"$text\" is in the compound database (as \"$(records.name[1])\") but no " *
                "compound of the dataset has the same InChIKey, so there is no data for it",
            ),
        )
    end
    exact = findall(==(:exact), found.match)
    idx = isempty(exact) ? collect(eachindex(found.id)) : exact
    sort!(idx; by = i -> (-found.points[i], found.name[i]))
    return subset(found, idx)
end

no_such_compound(db::Database, text) =
    length(db.members) == 1 ? resolve_group(member_dataset(db.members[1]), text) :
    throw(ArgumentError("no compound matches \"$text\" in any database"))

# First link of a compound of a member to the compound database, as the table of links that has
# it and the row, or `nothing`.
function first_link(links::CompoundLinks, id::Integer)
    c = links.compound
    i = searchsortedfirst(c, Int32(id))
    return i <= length(c) && c[i] == id && links.record[i] != 0 ? (links, i) : nothing
end

# The names that the first member that has the compound gives to it, with its table of links.
function member_view(db::Database, id::Integer)
    links = ensure_links!(db)
    for (m, member) in enumerate(db.members)
        map = db.registry.compound[m]
        local_id = findfirst(==(Int32(id)), map)
        local_id === nothing && continue
        return (member_dataset(member), links[m], Int32(local_id))
    end
    return nothing
end

function describe_candidates(db::Database, found::CompoundMatches)
    lines = String[]
    for (n, id) in enumerate(found.id)
        parts = String[found.name[n]]
        isempty(found.formula[n]) || push!(parts, found.formula[n])
        isempty(found.inchikey[n]) || push!(parts, found.inchikey[n])
        view = member_view(db, id)
        ds, links, local_id = view === nothing ? (nothing, nothing, Int32(0)) : view
        hit = links === nothing ? nothing : first_link(links, local_id)
        if hit !== nothing
            links, i = hit
            isempty(links.record_cas[i]) || push!(parts, "CAS " * links.record_cas[i])
            if links.via[i] == :name &&
               (links.formula_check[i] == :different || links.inchi_check[i] == :different)
                push!(parts, "name link to \"$(links.record_name[i])\" disagrees")
            end
        end
        names = ds === nothing ? String[] : ds.compounds.names[local_id]
        others = [x for x in names if x != found.name[n]]
        isempty(others) || push!(parts, "also " * join(first(others, 3), ", "))
        push!(parts, "$(found.points[n]) points")
        push!(lines, string(lpad(n, 3), ". ", join(parts, "  |  ")))
    end
    return join(lines, '\n')
end

function ambiguity_error(db::Database, text, found::CompoundMatches)
    exact = all(==(:exact), found.match)
    what =
        exact ? "matches $(length(found)) compounds of the dataset" :
        "has no exact match; the closest compounds are"
    return ArgumentError(
        "\"$text\" $what:\n" *
        describe_candidates(db, found) *
        "\nName one of them more precisely (an InChIKey or a CAS number), or pass " *
        "choose = Dict(\"$text\" => n) with the number of the one you mean" *
        (exact ? ", or choose = :all for all of them." : "."),
    )
end

# Ask the user; returns the chosen candidates.
function ask_choice(db::Database, text, found::CompoundMatches, input::IO, output::IO)
    exact = all(==(:exact), found.match)
    println(
        output,
        '"',
        text,
        "\" ",
        exact ? "matches $(length(found)) compounds of the dataset:" :
        "has no exact match; the closest compounds are:",
    )
    println(output, describe_candidates(db, found))
    options = "1-$(length(found))" * (exact ? ", a for all of them" : "") * ", q to cancel"
    for _ = 1:5
        print(output, "Which one? (", options, "): ")
        flush(output)
        answer = lowercase(strip(readline(input)))
        if answer in ("q", "")
            throw(ArgumentError("no compound was chosen for \"$text\""))
        elseif answer == "a" && exact
            return found
        end
        n = tryparse(Int, answer)
        n !== nothing && 1 <= n <= length(found) && return subset(found, [n])
        println(output, "Not a valid answer.")
    end
    throw(ArgumentError("no compound was chosen for \"$text\""))
end

# A question is asked only where a person can answer it: in a terminal session whose output is the
# terminal, or when the caller gave the streams to use. A build that captures the output (a
# documentation build, a test run, a script that writes to a file) gets the error that lists the
# candidates, instead of waiting for a key that nobody sees.
can_ask(input::IO, output::IO) = input !== stdin || (isinteractive() && output isa Base.TTY)

# What the `choose` keyword asks for `text`: (:ask | :all | :error | :index, position).
function choice_for(choose, text::AbstractString)
    if choose isa Symbol
        choose in (:ask, :all, :error) || throw(
            ArgumentError("choose must be :ask, :all, :error or a Dict, got :$choose"),
        )
        return choose, 0
    elseif choose isa AbstractDict
        key = choice_key(text)
        for (k, v) in choose
            choice_key(String(k)) == key || continue
            v === :all && return :all, 0
            v isa Integer && return :index, Int(v)
            throw(
                ArgumentError(
                    "the answer for \"$k\" must be a number or :all, got $(repr(v))",
                ),
            )
        end
        return :ask, 0
    end
    throw(ArgumentError("choose must be :ask, :all, :error or a Dict, got $(repr(choose))"))
end

function resolve_text(
    db::Database,
    cdb::CompoundDB,
    text::AbstractString,
    choose,
    input,
    output;
    online::Bool = false,
)
    key = choice_key(text)
    saved = get(db.choices, key, nothing)
    saved === nothing || return saved
    found = candidate_compounds(db, cdb, text; online, choose, input, output)
    exact = all(==(:exact), found.match)
    if exact && length(found) == 1
        db.choices[key] = found    # a text with one answer is not looked up again
        return found
    end
    action, position = choice_for(choose, text)
    if action == :all
        exact || throw(ambiguity_error(db, text, found))
        return found
    elseif action == :index
        1 <= position <= length(found) || throw(
            ArgumentError(
                "\"$text\" has $(length(found)) candidates, so $position is not a valid answer",
            ),
        )
        picked = subset(found, [position])
    elseif action == :error || !can_ask(input, output)
        throw(ambiguity_error(db, text, found))
    else
        picked = ask_choice(db, text, found, input, output)
    end
    db.choices[key] = picked
    return picked
end

# The compounds of the dataset that the compounds of a `lookup_compounds` result stand for, by
# InChIKey: a compound of the compound database that has no InChIKey, or that no article measured,
# leaves nothing to select.
function records_component(db::Database, cdb::CompoundDB, records::CompoundRecords)
    seen = Set{Int32}()
    names, formulas, keys_, counts = String[], String[], String[], Int[]
    ids = Int32[]
    for key in records.inchikey
        isempty(key) && continue
        found = find_compounds(db, cdb, key; limit = 25)
        for (k, id) in enumerate(found.id)
            (found.match[k] === :exact && id ∉ seen) || continue
            push!(seen, id)
            push!(ids, id)
            push!(names, found.name[k])
            push!(formulas, found.formula[k])
            push!(keys_, found.inchikey[k])
            push!(counts, found.points[k])
        end
    end
    isempty(ids) && throw(
        ArgumentError(
            "no compound of the dataset has the InChIKey of the compounds given " *
            "($(join(unique(filter(!isempty, records.inchikey)), ", "))), so there is no data for them",
        ),
    )
    return CompoundMatches(
        records.query,
        ids,
        names,
        formulas,
        keys_,
        counts,
        fill(:exact, length(ids)),
    )
end

# A `component` of `points`, with every text replaced by the compounds of the dataset it stands
# for, and the result of `lookup_compounds` by the compounds that have its InChIKeys.
resolve_component(db::Database, cdb, ::Nothing, choose, input, output; online = false) =
    nothing
resolve_component(
    db::Database,
    cdb::CompoundDB,
    text::AbstractString,
    choose,
    input,
    output;
    online = false,
) = resolve_text(db, cdb, text, choose, input, output; online)
resolve_component(
    db::Database,
    cdb::CompoundDB,
    records::CompoundRecords,
    choose,
    input,
    output;
    online = false,
) = records_component(db, cdb, records)
resolve_component(db::Database, cdb, other, choose, input, output; online = false) = other
function resolve_component(
    db::Database,
    cdb::CompoundDB,
    list::AbstractVector,
    choose,
    input,
    output;
    online = false,
)
    return Any[
        resolve_component(db, cdb, item, choose, input, output; online) for item in list
    ]
end

# The compounds of a `fraction` criterion are understood as the ones of `component` (a synonym,
# a CAS number, ...).
resolve_fraction(db::Database, cdb::CompoundDB, ::Nothing, choose, input, output, online) =
    nothing
function resolve_fraction(
    db::Database,
    cdb::CompoundDB,
    fraction,
    choose,
    input,
    output,
    online,
)
    return [
        resolve_component(db, cdb, compound, choose, input, output; online) => range for
        (compound, range) in fraction_items(fraction)
    ]
end

# `component` and `fraction` as the members of `db` understand them. Nothing happens when they
# are not given (the compound database is not even loaded) or when none is attached.
function resolve_inputs(db::Database, component, fraction, choose, input, output, online)
    (component === nothing && fraction === nothing) && return (component, fraction)
    cdb = compounds_of(db)
    cdb === nothing && return (component, fraction)
    return (
        resolve_component(db, cdb, component, choose, input, output; online),
        resolve_fraction(db, cdb, fraction, choose, input, output, online),
    )
end
