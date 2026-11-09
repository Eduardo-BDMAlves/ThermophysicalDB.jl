# The ThermoML dataset joined with the compound database.
#
# The dataset is never changed: a `LinkedDatabase` only keeps the two side by side, plus the
# table of links between them, and lets a compound be named by anything either of them
# knows (a synonym, a CAS number, a PubChem CID, an InChI, a SMILES). When a text leads to
# more than one compound of the dataset the user chooses, because the dataset is the
# reference and a guess would silently change what is measured.

"""
    LinkedDatabase

What [`link_compounds`](@ref) returns: the ThermoML dataset (`dataset`), the compound
database (`compounds`), the table of links between them (`links`, a [`CompoundLinks`](@ref))
and the choices the user made when a name was ambiguous (`choices`).

[`points`](@ref), [`mixture`](@ref) and [`find_compounds`](@ref) accept it in place of the
dataset, and a compound can then be named by any identifier the compound database knows:

```julia
linked = link_compounds(database(), compound_database())
points(linked; component = "oxidane", property = "Mass density")   # a synonym, not in any article
mixture(linked, "7732-18-5", "64-17-5")                              # water + ethanol, by CAS number
```

Both calls return an ordinary [`DataView`](@ref) of the dataset, so the rest of the
package works on it as before (a view does not remember the compound database, so refine it
with the names the dataset uses). It is a Tables.jl table of the links.

A text that leads to a single compound is used as it is. When it leads to several (a formula
shared by isomers, a name used for different species), the candidates are listed with their
formula, InChIKey, CAS number and number of points, and the user answers with a number, `a`
for all of them or `q` to cancel. The keyword `choose` of `points`, `mixture` and
`find_compounds`-based searches decides how:

- `choose = :ask` (default): ask in the terminal when the session is interactive
  (`isinteractive()`); otherwise throw an `ArgumentError` that lists the candidates.
- `choose = :error`: never ask, always throw.
- `choose = :all`: take every exact candidate. A text with no exact candidate is never
  accepted this way.
- `choose = Dict("butane" => 2, "C4H10" => :all)`: a prepared answer for each text, by the
  number the menu would show, so a script does not stop to ask.

With `online = true` a text that neither database knows is asked of PubChem
([`fetch_pubchem!`](@ref)) before giving up: what PubChem answers is kept in the compound
database, so it is found again without the network. The compounds that PubChem lists for the
text have their own menu, whose prepared answers are the entries of `choose` with a key that
starts with `"pubchem:"` (`Dict("pubchem:glucose" => 1)`). A compound added this way is
joined to the dataset by its InChIKey; call [`link_compounds`](@ref) again to refresh the
table of links.

`input` and `output` (default `stdin` and `stdout`) say where the question is read and
written. The answers given are kept in `choices` and used again for the same text; call
[`forget_choices!`](@ref) to clear them. The candidates are ordered by number of points and
then by name, so a number means the same thing every time on the same data.
"""
struct LinkedDatabase{D,L}
    dataset::D
    compounds::CompoundDB
    links::L
    choices::Dict{String,CompoundMatches}
end

# A `LinkedDatabase` over a `Database` (see `link_compounds(db::Database, ...)`) has one table of
# links for each member.
const LinkedMembers = LinkedDatabase{D,Vector{CompoundLinks}} where {D}

# The table of links as Tables.jl sees it: the table itself, or the rows of every member with the
# column `database`.
function links_table(l::LinkedDatabase)
    l.links isa CompoundLinks && return Tables.columns(l.links)
    cols = [Tables.columns(x) for x in l.links]
    names = keys(first(cols))
    merged = NamedTuple{names}(map(k -> reduce(vcat, (c[k] for c in cols)), names))
    database = reduce(
        vcat,
        [fill(m.name, length(x)) for (m, x) in zip(l.dataset.members, l.links)],
    )
    return merge(merged, (; database))
end

Tables.istable(::Type{<:LinkedDatabase}) = true
Tables.columnaccess(::Type{<:LinkedDatabase}) = true
Tables.columns(l::LinkedDatabase) = links_table(l)
Tables.schema(l::LinkedDatabase) = Tables.schema(links_table(l))

function Base.show(io::IO, l::LinkedDatabase)
    if l.links isa CompoundLinks
        n = length(l.dataset.compounds)
        linked = length(unique(l.links.compound[l.links.record .!= 0]))
        where_ = "compounds of the dataset"
    else
        n = sum(x -> length(unique(x.compound)), l.links)
        linked = sum(x -> length(unique(x.compound[x.record .!= 0])), l.links)
        where_ = "compounds of $(length(l.links)) databases"
    end
    return print(
        io,
        "LinkedDatabase: ",
        n,
        " ",
        where_,
        ", ",
        linked,
        " found in the compound database (",
        length(l.compounds),
        " compounds)",
    )
end

"""
    link_compounds(ds, db; by_name = true) -> LinkedDatabase

Join the ThermoML dataset `ds` with the compound database `db` (see
[`LinkedDatabase`](@ref) for what the result can do). Every compound of the dataset is matched
with the database: the InChIKey is tried first, then the InChI, then the names (with the
usual spelling variants). Given a `Database` with several members instead of a dataset, every member is linked and the result searches all of them (the table of links then has one table for each member). The table of links is `linked.links`, with one row for each
candidate of each compound. A compound found only by name is marked `via = :name`, because a
name can describe more than one species: trust such a link only when `formula_check` and
`inchi_check` are `:same`, and treat `:stereo` (the same skeleton with other stereochemistry
or isotopes) and `:different` (a hydrate and its anhydrous salt, for example) as a related
compound, not as the same one. `by_name = false` links by InChIKey and InChI only. The dataset
is not modified.

```julia
db = database()
cdb = compound_database()
linked = link_compounds(db, cdb)
linked.links                       # the table of links
points(linked; component = "oxidane")
```
"""
function link_compounds(ds::Dataset, db::CompoundDB; by_name::Bool = true)
    return LinkedDatabase(
        ds,
        db,
        compound_links(ds, db; by_name),
        Dict{String,CompoundMatches}(),
    )
end

"""
    forget_choices!(linked) -> linked

Clear the answers remembered by a [`LinkedDatabase`](@ref), so the next ambiguous text asks
again.
"""
function forget_choices!(l::LinkedDatabase)
    empty!(l.choices)
    return l
end

prefetch_compounds!(l::LinkedDatabase; kwargs...) =
    prefetch_compounds!(l.dataset, l.compounds; kwargs...)
prefetch_compounds!(l::LinkedMembers; kwargs...) = throw(
    ArgumentError(
        "prefetch_compounds! works on one database; use it on `member_dataset(db, name)` and " *
        "link again",
    ),
)

find_compounds(l::LinkedDatabase, text::AbstractString; limit::Int = 10) =
    find_compounds(l.dataset, l.compounds, text; limit)

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

# The compounds that can be what `text` means: the exact ones when there are any, otherwise
# the close ones. Ordered by number of points and then by name, so that a menu number is
# reproducible.
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

function candidate_compounds(
    l::LinkedDatabase,
    text::AbstractString;
    online::Bool = false,
    choose = :ask,
    input::IO = stdin,
    output::IO = stdout,
)
    found = find_compounds(l.dataset, l.compounds, text; limit = 20)
    if online && !any(==(:exact), found.match) && !known_with_inchikey(l.compounds, text)
        fetched = fetch_pubchem!(
            l.compounds,
            text;
            choose = pubchem_choice(choose),
            force = true,
            input,
            output,
        )
        isempty(fetched) ||
            (found = find_compounds(l.dataset, l.compounds, text; limit = 20))
        if isempty(fetched) && isempty(found)
            @info "\"$text\" is not in the compound database and PubChem has nothing for it"
        end
    end
    if isempty(found)
        records = lookup_compounds(l.compounds, text; limit = 1)
        known = !isempty(records) && records.match[1] ∉ (:contains, :similar)
        known || no_such_compound(l.dataset, text)    # throws with the usual spelling hints
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

no_such_compound(ds::Dataset, text) = resolve_group(ds, text)
no_such_compound(::Any, text) =
    throw(ArgumentError("no compound matches \"$text\" in any database"))

# First link of a compound of the dataset to the compound database, as the table of links that
# has it and the row, or `nothing`. The identifier of a `Database` is global: the first member
# that has the compound answers.
function first_link(links::CompoundLinks, id::Integer)
    c = links.compound
    i = searchsortedfirst(c, Int32(id))
    return i <= length(c) && c[i] == id && links.record[i] != 0 ? (links, i) : nothing
end
first_link(l::LinkedDatabase{<:Dataset}, id::Integer) = first_link(l.links, id)

# The names that the dataset (or the first member that has it) gives to a compound.
function member_view(l::LinkedDatabase, id::Integer)
    l.links isa CompoundLinks && return (l.dataset, l.links, Int32(id))
    for (m, member) in enumerate(l.dataset.members)
        map = l.dataset.registry.compound[m]
        local_id = findfirst(==(Int32(id)), map)
        local_id === nothing && continue
        return (member_dataset(member), l.links[m], Int32(local_id))
    end
    return nothing
end

function describe_candidates(l::LinkedDatabase, found::CompoundMatches)
    lines = String[]
    for (n, id) in enumerate(found.id)
        parts = String[found.name[n]]
        isempty(found.formula[n]) || push!(parts, found.formula[n])
        isempty(found.inchikey[n]) || push!(parts, found.inchikey[n])
        view = member_view(l, id)
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

function ambiguity_error(l::LinkedDatabase, text, found::CompoundMatches)
    exact = all(==(:exact), found.match)
    what =
        exact ? "matches $(length(found)) compounds of the dataset" :
        "has no exact match; the closest compounds are"
    return ArgumentError(
        "\"$text\" $what:\n" *
        describe_candidates(l, found) *
        "\nName one of them more precisely (an InChIKey or a CAS number), or pass " *
        "choose = Dict(\"$text\" => n) with the number of the one you mean" *
        (exact ? ", or choose = :all for all of them." : "."),
    )
end

# Ask the user; returns the chosen candidates.
function ask_choice(l::LinkedDatabase, text, found::CompoundMatches, input::IO, output::IO)
    exact = all(==(:exact), found.match)
    println(
        output,
        '"',
        text,
        "\" ",
        exact ? "matches $(length(found)) compounds of the dataset:" :
        "has no exact match; the closest compounds are:",
    )
    println(output, describe_candidates(l, found))
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
    l::LinkedDatabase,
    text::AbstractString,
    choose,
    input,
    output;
    online::Bool = false,
)
    key = choice_key(text)
    saved = get(l.choices, key, nothing)
    saved === nothing || return saved
    found = candidate_compounds(l, text; online, choose, input, output)
    exact = all(==(:exact), found.match)
    exact && length(found) == 1 && return found
    action, position = choice_for(choose, text)
    if action == :all
        exact || throw(ambiguity_error(l, text, found))
        return found
    elseif action == :index
        1 <= position <= length(found) || throw(
            ArgumentError(
                "\"$text\" has $(length(found)) candidates, so $position is not a valid answer",
            ),
        )
        picked = subset(found, [position])
    elseif action == :error || !(input !== stdin || isinteractive())
        throw(ambiguity_error(l, text, found))
    else
        picked = ask_choice(l, text, found, input, output)
    end
    l.choices[key] = picked
    return picked
end

# A `component` of the dataset's `points`, with every text replaced by the compounds of the
# dataset it stands for.
resolve_component(l::LinkedDatabase, ::Nothing, choose, input, output; online = false) =
    nothing
resolve_component(
    l::LinkedDatabase,
    text::AbstractString,
    choose,
    input,
    output;
    online = false,
) = resolve_text(l, text, choose, input, output; online)
resolve_component(l::LinkedDatabase, other, choose, input, output; online = false) = other
function resolve_component(
    l::LinkedDatabase,
    list::AbstractVector,
    choose,
    input,
    output;
    online = false,
)
    return Any[resolve_component(l, item, choose, input, output; online) for item in list]
end

function points(
    l::LinkedDatabase;
    component = nothing,
    choose = :ask,
    online::Bool = false,
    input::IO = stdin,
    output::IO = stdout,
    kwargs...,
)
    resolved = resolve_component(l, component, choose, input, output; online)
    return points(l.dataset; component = resolved, kwargs...)
end

function mixture(
    l::LinkedDatabase,
    components...;
    exact::Bool = true,
    choose = :ask,
    online::Bool = false,
    input::IO = stdin,
    output::IO = stdout,
    kwargs...,
)
    length(components) >= 2 ||
        throw(ArgumentError("a mixture needs at least two components"))
    resolved =
        Any[resolve_component(l, c, choose, input, output; online) for c in components]
    return mixture(l.dataset, resolved...; exact, kwargs...)
end
