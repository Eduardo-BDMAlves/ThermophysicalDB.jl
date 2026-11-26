# Moving a reference from one database of the user to another, and publishing the data of the user.
#
# The databases stay apart: nothing here joins two of them. A reference (with its experiments,
# points, samples, conditions and uncertainties) is copied into the destination and then removed
# from the origin, each as a new dataset that replaces the old one, so a mistake leaves both as
# they were. The ThermoML archive is never an origin or a destination.

const MOVE_CONFLICTS = (:error, :merge, :skip)

# The identifier of `code` in the pool `name` of the destination, or `NO_ID`.
@inline pooled_code(maps, name::Symbol, code::Integer) =
    code == NO_ID ? NO_ID : maps[name][code]

# The compound of `src` row `i` in `t`, added when the destination does not have it.
function adopt_compound!(t::CompoundTable, src::CompoundTable, i::Integer)
    key = src.key[i]
    id = get(t.index, key, NO_ID)
    if id != NO_ID
        isempty(t.inchi[id]) && (t.inchi[id] = src.inchi[i])
        isempty(t.formula[id]) && (t.formula[id] = src.formula[i])
        for name in src.names[i]
            name in t.names[id] || push!(t.names[id], name)
        end
        return id
    end
    push!(t.key, key)
    push!(t.inchikey, src.inchikey[i])
    push!(t.inchi, src.inchi[i])
    push!(t.formula, src.formula[i])
    push!(t.names, copy(src.names[i]))
    id = Int32(length(t.key))
    t.index[key] = id
    t.lookup[] = nothing
    return id
end

# Put the references, experiments and points of `sub` (a dataset made by `subset_dataset`) in
# `dst`, as new rows, with every identifier translated. With `into` the references of `sub` are
# given to that reference of `dst` instead of being added (the experiments of two references with
# the same DOI are then of one reference). Returns `(references, experiments, points)` added.
function append_subset!(
    dst::Dataset,
    sub::Dataset;
    into::Integer = NO_ID,
    rename::Pair{String,String} = "" => "",
)
    maps = Dict{Symbol,Vector{Int32}}()
    for name in schema_pools()
        p, q = getproperty(sub, name)::StringPool, getproperty(dst, name)::StringPool
        maps[name] = Int32[
            intern!(q, name === :sources && s == rename.first ? rename.second : s) for
            s in p.strings
        ]
    end
    cmap = Int32[
        adopt_compound!(dst.compounds, sub.compounds, i) for
        i in eachindex(sub.compounds.key)
    ]
    pp, dp = sub.properties, dst.properties
    propmap = Int32[
        add_property!(
            dp,
            pp.label[i],
            pp.unit[i];
            group = pooled_code(maps, :groups, pp.group[i]),
        ) for i in eachindex(pp.label)
    ]

    # references
    rf, df = sub.references, dst.references
    rmap = Int32[]
    added_references = 0
    for i in eachindex(rf.doi)
        if into != NO_ID
            push!(rmap, Int32(into))
            continue
        end
        before = length(df)
        id = add_reference!(
            df;
            doi = rf.doi[i],
            title = rf.title[i],
            journal = rf.journal[i],
            year = rf.year[i],
            volume = rf.volume[i],
            pages = rf.pages[i],
            authors = rf.authors[i],
            source = pooled_code(maps, :sources, rf.source[i]),
        )
        added_references += length(df) - before
        push!(rmap, id)
    end

    # samples and their purity steps
    st, dt = sub.samples, dst.samples
    smap = Int32[]
    analyses(v) = Int32[pooled_code(maps, :analyses, c) for c in v]
    purifications(v) = Int32[pooled_code(maps, :purifications, c) for c in v]
    for i in eachindex(st.reference)
        ref, comp = rmap[st.reference[i]], cmap[st.compound[i]]
        number = st.number[i]
        if haskey(dt.index, (ref, comp, number))
            used = (n for (r, c, n) in keys(dt.index) if r == ref && c == comp)
            number = Int32(maximum(used) + 1)
        end
        push!(dt.reference, ref)
        push!(dt.compound, comp)
        push!(dt.number, number)
        push!(dt.origin, pooled_code(maps, :origins, st.origin[i]))
        push!(dt.status, pooled_code(maps, :statuses, st.status[i]))
        push!(dt.supplier, pooled_code(maps, :suppliers, st.supplier[i]))
        push!(dt.nsteps, st.nsteps[i])
        push!(dt.purity, st.purity[i])
        push!(dt.purity_kind, st.purity_kind[i])
        push!(dt.purity_initial, st.purity_initial[i])
        push!(dt.purity_initial_kind, st.purity_initial_kind[i])
        push!(dt.water, st.water[i])
        push!(dt.purity_basis, st.purity_basis[i])
        push!(dt.analysis, analyses(st.analysis[i]))
        push!(dt.purification, purifications(st.purification[i]))
        id = Int32(length(dt.reference))
        dt.index[(ref, comp, number)] = id
        push!(smap, id)
    end
    ps, dps = sub.purity_steps, dst.purity_steps
    for i in eachindex(ps.sample)
        push!(dps.sample, smap[ps.sample[i]])
        push!(dps.step, ps.step[i])
        push!(dps.mass, ps.mass[i])
        push!(dps.mole, ps.mole[i])
        push!(dps.volume, ps.volume[i])
        push!(dps.unknown, ps.unknown[i])
        push!(dps.digits, ps.digits[i])
        push!(dps.water_mass, ps.water_mass[i])
        push!(dps.water_mole, ps.water_mole[i])
        push!(dps.halide_mass, ps.halide_mass[i])
        push!(dps.halide_mole, ps.halide_mole[i])
        push!(dps.analysis, analyses(ps.analysis[i]))
        push!(dps.analysis_text, pooled_code(maps, :extra_texts, ps.analysis_text[i]))
        push!(dps.purification, purifications(ps.purification[i]))
        push!(
            dps.purification_text,
            pooled_code(maps, :extra_texts, ps.purification_text[i]),
        )
    end

    # experiments
    ex, de = sub.experiments, dst.experiments
    eoff = length(de)
    for i in eachindex(ex.reference)
        push!(de.reference, rmap[ex.reference[i]])
        push!(de.source, pooled_code(maps, :sources, ex.source[i]))
        push!(de.number, ex.number[i])
        push!(de.ncomp, ex.ncomp[i])
        for j = 1:MAX_COMPONENTS
            c = ex.components[j][i]
            push!(de.components[j], c == NO_ID ? NO_ID : cmap[c])
            push!(de.kinds[j], pooled_code(maps, :kinds, ex.kinds[j][i]))
            s = ex.samples[j][i]
            push!(de.samples[j], s == NO_ID ? NO_ID : smap[s])
        end
        push!(de.purpose, pooled_code(maps, :purposes, ex.purpose[i]))
    end

    # points
    m, dm = sub.measurements, dst.measurements
    moff = length(dm)
    for i in eachindex(m.experiment)
        push!(dm.experiment, m.experiment[i] + Int32(eoff))
        push!(dm.property, UInt8(propmap[m.property[i]]))
        push!(dm.method, narrow(UInt16, pooled_code(maps, :methods, m.method[i]), "method"))
        push!(dm.phase, narrow(UInt8, pooled_code(maps, :phases, m.phase[i]), "phase"))
        push!(dm.value, m.value[i])
        push!(dm.unc, m.unc[i])
        push!(dm.unc_k, m.unc_k[i])
        push!(dm.unc_level, m.unc_level[i])
        push!(dm.temperature, m.temperature[i])
        push!(dm.pressure, m.pressure[i])
        for j = 1:MAX_COMPONENTS
            push!(dm.composition[j], m.composition[j][i])
            push!(dm.composition_digits[j], m.composition_digits[j][i])
        end
        push!(
            dm.unc_method,
            narrow(
                UInt8,
                pooled_code(maps, :unc_methods, m.unc_method[i]),
                "uncertainty method",
            ),
        )
        push!(
            dm.evaluator,
            narrow(
                UInt16,
                pooled_code(maps, :evaluators, m.evaluator[i]),
                "uncertainty evaluator",
            ),
        )
        push!(dm.assessment, m.assessment[i])
        push!(dm.block, m.block[i] == NO_ID ? NO_ID : m.block[i] + Int32(moff))
        push!(dm.digits, m.digits[i])
        push!(dm.temperature_digits, m.temperature_digits[i])
        push!(dm.pressure_digits, m.pressure_digits[i])
    end

    # notes
    xs, dx = sub.extras, dst.extras
    seen = Set{Tuple{UInt8,Int32,UInt8}}(
        (dx.scope[i], dx.row[i], dx.key[i]) for i in eachindex(dx.row)
    )
    for i in eachindex(xs.row)
        what = EXTRA_SCOPES[Int(xs.scope[i])]
        row =
            what === :reference ? rmap[xs.row[i]] :
            what === :compound ? cmap[xs.row[i]] :
            what === :experiment ? xs.row[i] + Int32(eoff) : xs.row[i] + Int32(moff)
        key = narrow(UInt8, pooled_code(maps, :extra_keys, xs.key[i]), "extra field")
        what === :compound && (xs.scope[i], row, key) in seen && continue
        push!(dx.scope, xs.scope[i])
        push!(dx.row, row)
        push!(dx.key, key)
        push!(dx.number, xs.number[i])
        push!(dx.text, pooled_code(maps, :extra_texts, xs.text[i]))
    end
    cs, dc = sub.conditions, dst.conditions
    for i in eachindex(cs.row)
        push!(dc.scope, cs.scope[i])
        push!(
            dc.row,
            cs.row[i] +
            Int32(CONDITION_SCOPES[Int(cs.scope[i])] === :experiment ? eoff : moff),
        )
        push!(dc.role, cs.role[i])
        push!(dc.group, pooled_code(maps, :condition_groups, cs.group[i]))
        push!(dc.label, pooled_code(maps, :condition_labels, cs.label[i]))
        push!(dc.value, cs.value[i])
        push!(dc.digits, cs.digits[i])
        push!(dc.phase, pooled_code(maps, :phases, cs.phase[i]))
        push!(dc.component, cs.component[i] == NO_ID ? NO_ID : cmap[cs.component[i]])
        push!(
            dc.phase_component,
            cs.phase_component[i] == NO_ID ? NO_ID : cmap[cs.phase_component[i]],
        )
    end
    us, du = sub.uncertainties, dst.uncertainties
    for i in eachindex(us.row)
        push!(du.scope, us.scope[i])
        push!(
            du.row,
            us.row[i] +
            Int32(UNCERTAINTY_SCOPES[Int(us.scope[i])] === :experiment ? eoff : moff),
        )
        push!(du.quantity, us.quantity[i])
        push!(du.kind, us.kind[i])
        push!(du.origin, us.origin[i])
        push!(du.value, us.value[i])
        push!(du.k, us.k[i])
        push!(du.level, us.level[i])
        push!(du.method, pooled_code(maps, :unc_methods, us.method[i]))
    end
    touch!(dst)
    return (;
        references = added_references,
        experiments = length(ex.reference),
        points = length(m.experiment),
    )
end

# `replace_dataset!` for the member that the reference is moved to.
function check_move_members(db::Database, from::Member, to::Member)
    from === to && throw(ArgumentError("the reference is already in \"$(to.name)\""))
    return nothing
end

"""
    move_reference!(db, reference, to; database = nothing, metadata = (;),
                    on_conflict = :error, confirm = false) -> NamedTuple

Move a reference of a database of your own, with its experiments, points, samples, conditions and
uncertainties, to another database of your own. The databases stay apart: the reference is copied
into `to` and removed from the origin, and the ThermoML archive is never an origin or a
destination (it is read only). Use it, for example, to take the data that you measured out of
your database `my_lab` and into a database of literature once they are published; see
[`publish!`](@ref) for the whole flow.

`reference` is the result of [`add_reference!`](@ref) or a DOI of the database `database` (needed
when there is more than one of your own). With `confirm = false` (the default) nothing changes and
the result says what would move, `(moved = false, from, to, references, experiments, points,
conflict)`; call again with `confirm = true` to do it. In memory until [`save_database`](@ref),
which writes the events `reference_moved_out` and `reference_moved_in` in the audit logs.

`metadata` replaces fields of the reference on the way (`doi`, `title`, `journal`, `year`,
`volume`, `pages`, `authors`): a reference of your data that has no DOI becomes the article. When
`to` already has a reference with that DOI, `on_conflict` says what to do: `:error` (default),
`:merge` (the experiments join that reference) or `:skip` (nothing moves).

```julia
move_reference!(db, "10.1000/mine", "papers"; metadata = (; doi = "10.1021/je1234"), confirm = true)
```
"""
function move_reference!(
    db::Database,
    reference,
    to::AbstractString;
    database = nothing,
    metadata = (;),
    on_conflict::Symbol = :error,
    confirm::Bool = false,
)
    on_conflict in MOVE_CONFLICTS || throw(
        ArgumentError(
            "on_conflict is one of $(join(repr.(MOVE_CONFLICTS), ", ")), got :$on_conflict",
        ),
    )
    unknown = [k for k in keys(metadata) if !(k in REFERENCE_FIELDS)]
    isempty(unknown) || throw(
        ArgumentError(
            "unknown field $(repr(first(unknown))) of a reference; the fields are $(join(REFERENCE_FIELDS, ", "))",
        ),
    )
    from = reference isa ReferenceRef ? reference.member : writable_member(db, database)
    dest = writable_member(db, String(to))
    check_move_members(db, from, dest)
    ref = find_reference(db, from, reference)
    src = live_dataset(ref)
    keep = cascade(
        src;
        drop_references = Int32[i for i = 1:length(src.references) if i != ref.id],
    )
    sub = subset_dataset(src, keep)
    apply_metadata!(sub, 1, metadata)
    target = member_dataset(dest)
    existing =
        isempty(sub.references.doi[1]) ? NO_ID :
        get(target.references.index, sub.references.doi[1], NO_ID)
    conflict = existing != NO_ID
    counts = (;
        references = conflict ? 0 : 1,
        experiments = count(keep.experiments),
        points = count(keep.measurements),
    )
    plan = (; from = from.name, to = dest.name, counts..., conflict)
    conflict &&
        on_conflict === :error &&
        throw(
            ArgumentError(
                "\"$(dest.name)\" already has the reference with the DOI \"$(sub.references.doi[1])\"; " *
                "use on_conflict = :merge to join the experiments to it or :skip to leave them",
            ),
        )
    (conflict && on_conflict === :skip) && return (; moved = false, plan...)
    confirm || return (; moved = false, plan...)
    grown = copy_dataset(target)
    append_subset!(
        grown,
        sub;
        into = conflict ? existing : NO_ID,
        rename = from.name => dest.name,
    )
    rest = subset_dataset(src, cascade(src; drop_references = Int32[ref.id]))
    doi = src.references.doi[ref.id]
    label = isempty(doi) ? "reference $(ref.id)" : doi
    detail = "reference=$label experiments=$(counts.experiments) points=$(counts.points)"
    replace_dataset!(db, dest, grown, "reference_moved_in", "$detail from=$(from.name)")
    replace_dataset!(db, from, rest, "reference_moved_out", "$detail to=$(dest.name)")
    return (; moved = true, plan...)
end

# Set the fields of the reference `k` of `sub` from `metadata` (a DOI that is given joins them).
function apply_metadata!(sub::Dataset, k::Integer, metadata)
    isempty(metadata) && return sub
    rf = sub.references
    fields = merge(
        (;
            doi = rf.doi[k],
            title = rf.title[k],
            journal = rf.journal[k],
            year = Int(rf.year[k]),
            volume = rf.volume[k],
            pages = rf.pages[k],
            authors = rf.authors[k],
        ),
        NamedTuple(metadata),
    )
    rf.doi[k] = normalize_doi(String(fields.doi))
    rf.title[k] = String(fields.title)
    rf.journal[k] = String(fields.journal)
    rf.year[k] = Int16(fields.year)
    rf.volume[k] = String(fields.volume)
    rf.pages[k] = String(fields.pages)
    rf.authors[k] = String.(fields.authors)
    empty!(rf.index)
    for (i, d) in enumerate(rf.doi)
        isempty(d) || (rf.index[d] = Int32(i))
    end
    return sub
end

# The points that `what` selects in each database that can be changed: `(member, mask)` with the
# mask over the points of the dataset of the member. `what` is the name of an experiment, a vector
# of names, or a selection of points (`points(...)`).
function selected_points(db::Database, what)
    pieces = Tuple{Member,BitVector}[]
    if what isa AbstractString || what isa AbstractVector{<:AbstractString}
        list = what isa AbstractString ? [String(what)] : String.(what)
        unknown = unknown_experiment_names(db, list)
        isempty(unknown) ||
            throw(ArgumentError("no experiment is called $(join(repr.(unknown), ", "))"))
        wanted = Set(list)
        for m in db.members
            m.kind === :thermoml && continue
            ds = member_dataset(m)
            tags = experiment_tags(m, ds)
            mask = BitVector([any(in(wanted), tags[e]) for e in ds.measurements.experiment])
            any(mask) && push!(pieces, (m, mask))
        end
    elseif what isa DatabaseView || what isa DataView
        parts = Tuple{Union{Nothing,Int},DataView}[]
        if what isa DatabaseView
            for (i, p) in zip(what.index, what.parts)
                push!(parts, (i, p))
            end
        else
            push!(parts, (nothing, what))
        end
        for (i, p) in parts
            isempty(p) && continue
            k =
                i === nothing ?
                findfirst(m -> member_dataset(m) === p.dataset, db.members) : Int(i)
            k === nothing && throw(ArgumentError("the selection is not of this database"))
            m = db.members[k]
            m.kind === :thermoml && throw(
                ArgumentError(
                    "the ThermoML archive is read only: its points cannot be moved or published",
                ),
            )
            ds = member_dataset(m)
            p.dataset === ds || throw(
                ArgumentError(
                    "the selection is out of date: the database \"$(m.name)\" changed; select the points again",
                ),
            )
            mask = falses(length(ds.measurements.experiment))
            mask[p.rows] .= true
            j = findfirst(x -> x[1] === m, pieces)
            j === nothing ? push!(pieces, (m, mask)) : (pieces[j][2] .|= mask)
        end
    else
        throw(
            ArgumentError(
                "choose the experiments with a name, a vector of names or a selection of points, got $(typeof(what))",
            ),
        )
    end
    isempty(pieces) && throw(ArgumentError("the selection has no points to move"))
    return pieces
end

# The `Keep` that holds the points of `mask` (when `inside`) or all the others, without the
# references and experiments that are left with no points.
function keep_points(ds::Dataset, mask::BitVector, inside::Bool)
    keep = cascade(ds; drop_measurements = findall(inside ? .!mask : mask))
    ex = ds.experiments
    kr = falses(length(ds.references))
    for e in eachindex(keep.experiments)
        keep.experiments[e] && (kr[ex.reference[e]] = true)
    end
    return Keep(kr, keep.experiments, keep.measurements)
end

# `keep` reduced to the reference `r`.
function keep_reference(ds::Dataset, keep, r::Integer)
    er = ds.experiments.reference
    ke = BitVector(keep.experiments[e] && er[e] == r for e in eachindex(er))
    km = BitVector(
        keep.measurements[i] && ke[ds.measurements.experiment[i]] for
        i in eachindex(keep.measurements)
    )
    kr = falses(length(keep.references))
    kr[r] = true
    return Keep(kr, ke, km)
end

"""
    move_experiments!(db, what, to; metadata = (;), on_conflict = :error, confirm = false)
        -> NamedTuple

Move some experiments of your own databases to another database of your own, without joining the
two: the points are copied into `to` and taken out of the origin. `what` is the name of an
experiment ([`add_name!`](@ref)), a vector of names, or a selection of points
(`points(db; experiment = "visc-run-1")`). When only some points of an experiment are selected,
those are copied with the experiment and the others stay where they were. The names go with the
experiments, so a search by name finds them in their new database. The ThermoML archive is never
an origin or a destination.

`metadata` replaces fields of the references on the way (`doi`, `title`, `journal`, `year`,
`volume`, `pages`, `authors`); with a `doi` all the points go to one reference. When `to` already
has a reference with that DOI, `on_conflict` is `:error` (default), `:merge` (join it) or `:skip`.
With `confirm = false` nothing changes and the result says what would move
(`(moved = false, from, to, references, experiments, points, partial, conflict)`).
See [`publish!`](@ref) for the whole flow.
"""
function move_experiments!(
    db::Database,
    what,
    to::AbstractString;
    metadata = (;),
    on_conflict::Symbol = :error,
    confirm::Bool = false,
)
    on_conflict in MOVE_CONFLICTS || throw(
        ArgumentError(
            "on_conflict is one of $(join(repr.(MOVE_CONFLICTS), ", ")), got :$on_conflict",
        ),
    )
    unknown = [k for k in keys(metadata) if !(k in REFERENCE_FIELDS)]
    isempty(unknown) || throw(
        ArgumentError(
            "unknown field $(repr(first(unknown))) of a reference; the fields are $(join(REFERENCE_FIELDS, ", "))",
        ),
    )
    dest = writable_member(db, String(to))
    pieces = selected_points(db, what)
    for (m, _) in pieces
        check_move_members(db, m, dest)
    end
    target = member_dataset(dest)
    grown = copy_dataset(target)
    subs = Tuple{Dataset,String}[]
    experiments = points = partial = 0
    conflicts = 0
    for (m, mask) in pieces
        src = member_dataset(m)
        keep = keep_points(src, mask, true)
        experiments += count(keep.experiments)
        points += count(keep.measurements)
        partial += count(
            e ->
                keep.experiments[e] && any(
                    i -> src.measurements.experiment[i] == e && !mask[i],
                    eachindex(mask),
                ),
            eachindex(keep.experiments),
        )
        for r in findall(keep.references)
            sub = subset_dataset(src, keep_reference(src, keep, r))
            apply_metadata!(sub, 1, metadata)
            doi = sub.references.doi[1]
            isempty(doi) ||
                get(target.references.index, doi, NO_ID) == NO_ID ||
                (conflicts += 1)
            push!(subs, (sub, m.name))
        end
    end
    conflict = conflicts > 0
    plan = (;
        from = [m.name for (m, _) in pieces],
        to = dest.name,
        references = length(subs),
        experiments,
        points,
        partial,
        conflict,
    )
    conflict &&
        on_conflict === :error &&
        throw(
            ArgumentError(
                "\"$(dest.name)\" already has $(conflicts) of the references; " *
                "use on_conflict = :merge to join the experiments to them or :skip to leave them",
            ),
        )
    (conflict && on_conflict === :skip) && return (; moved = false, plan...)
    confirm || return (; moved = false, plan...)
    for (sub, origin) in subs
        doi = sub.references.doi[1]
        existing = isempty(doi) ? NO_ID : get(grown.references.index, doi, NO_ID)
        append_subset!(grown, sub; into = existing, rename = origin => dest.name)
    end
    detail = "experiments=$experiments points=$points"
    replace_dataset!(
        db,
        dest,
        grown,
        "experiments_moved_in",
        "$detail from=$(join(plan.from, ","))",
    )
    for (m, mask) in pieces
        src = member_dataset(m)
        rest = subset_dataset(src, keep_points(src, mask, false))
        replace_dataset!(db, m, rest, "experiments_moved_out", "$detail to=$(dest.name)")
    end
    return (; moved = true, plan...)
end

# The fields of a reference from the entry of its DOI (the resolver) and the publication: what the
# resolver gives wins, and what it lacks is taken from the publication.
function published_fields(
    pub::Union{Nothing,Publication},
    doi::String;
    online,
    cache,
    refresh,
    fetcher,
)
    entry = nothing
    text = fetch_entry_text(doi; online, cache, refresh, fetcher)
    text === nothing || (entry = parse_bibtex(text))
    entry === nothing || clean_resolver_entry!(entry)
    pick(name, fallback) = begin
        v = entry === nothing ? nothing : field_value(entry, name)
        v === nothing || isempty(v) ? fallback : String(v)
    end
    authors = entry === nothing ? nothing : field_value(entry, "author")
    list =
        authors === nothing || isempty(authors) ?
        (pub === nothing ? String[] : pub.authors) :
        String.(strip.(split(authors, " and ")))
    year = tryparse(Int, pick("year", pub === nothing ? "" : string(pub.year)))
    return (;
        doi,
        title = pick("title", pub === nothing ? "" : pub.title),
        journal = pick("journal", pub === nothing ? "" : pub.journal),
        year = year === nothing ? 0 : year,
        volume = pick("volume", ""),
        pages = pick("pages", ""),
        authors = list,
    ),
    entry !== nothing
end

"""
    publish!(db, what = nothing; doi = nothing, to = nothing, confirm = false, online = true, ...)
        -> NamedTuple

Turn the data of a work into the reference of its published article: the points go to the
database of literature `to` (see [`move_experiments!`](@ref)), all in one reference, the DOI
(title, authors, journal, year and pages from the DOI, by the resolver, and from the publication
for what it lacks), and the publication is removed, so the points are literature from then on.
The rest of your data stay where they are, and the names of the experiments are kept.

`what` says which points: the name of a publication prepared with [`add_publication!`](@ref)
(`publish!(db, "paper-A"; doi = "10.…")`), a selection of points
(`publish!(db, points(db; experiment = r"^visc"); doi = ...)`), or nothing, for all the data of
the databases of kind `:user` (the publication of [`set_publication!`](@ref)). `doi` defaults to
the one of the publication, and `to` to the only database of literature of your own.

With `confirm = false` (the default) nothing changes and the result lists what would move; with
`confirm = true` it is done, in memory until [`save_database`](@ref). The ThermoML archive is
never changed. `online`, `cache`, `refresh` and `fetcher` are those of [`bibtex`](@ref).
"""
function publish!(
    db::Database,
    what = nothing;
    doi::Union{Nothing,AbstractString} = nothing,
    to::Union{Nothing,AbstractString} = nothing,
    confirm::Bool = false,
    online::Bool = true,
    cache::Bool = true,
    refresh::Bool = false,
    fetcher = default_fetcher,
)
    named = what isa AbstractString
    pub = if named
        m, k = find_publication(db, what)
        m.publications[k]
    else
        publication(db)
    end
    doi_text =
        normalize_doi(String(doi === nothing ? (pub === nothing ? "" : pub.doi) : doi))
    isempty(doi_text) && throw(
        ArgumentError(
            "publish! needs the DOI of the article: `publish!(db, ...; doi = \"10.…\")`",
        ),
    )
    selection = if named
        isempty(pub.experiments) &&
            throw(ArgumentError("the publication \"$(pub.name)\" has no experiments"))
        pub.experiments
    elseif what === nothing
        isempty(filter(m -> m.kind === :user, db.members)) &&
            throw(ArgumentError("there are no data of the user to publish"))
        user_selection(db)
    else
        what
    end
    destination = if to === nothing
        lit = [m for m in db.members if m.kind === :literature]
        length(lit) == 1 || throw(
            ArgumentError(
                "say the database of literature that receives the data with `to = \"name\"` " *
                "(there are $(length(lit)) of your own)",
            ),
        )
        only(lit).name
    else
        String(to)
    end
    dest = writable_member(db, destination)
    dest.kind === :literature ||
        throw(ArgumentError("\"$destination\" is not a database of literature"))
    fields, resolved = published_fields(pub, doi_text; online, cache, refresh, fetcher)
    plan = move_experiments!(
        db,
        selection,
        destination;
        metadata = fields,
        on_conflict = :merge,
        confirm,
    )
    summary = (;
        doi = doi_text,
        to = destination,
        references = plan.references,
        experiments = plan.experiments,
        points = plan.points,
        partial = plan.partial,
        resolved,
        fields,
    )
    confirm || return (; published = false, summary...)
    if named
        remove_publication!(db, what)
    elseif what === nothing
        set_publication!(db, nothing)
    end
    return (; published = true, summary...)
end

# All the points of the databases of kind `:user`, as a selection.
function user_selection(db::Database)
    index = Int[i for (i, m) in enumerate(db.members) if m.kind === :user]
    parts = DataView[
        DataView(
            member_dataset(db.members[i]),
            Int32.(eachindex(member_dataset(db.members[i]).measurements.experiment)),
        ) for i in index
    ]
    return DatabaseView(db, index, parts)
end
