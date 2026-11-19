# A copy of a dataset that keeps only some of its references, experiments and points. It is how a
# reference is removed and how a failed or refused addition leaves nothing behind: the rows that stay
# are copied, in their order, to new tables (the ids are renumbered, so every id that points at a
# row is mapped), and what is shared with nobody is copied too, so the copy can be changed without
# touching the original.

# Which rows stay.
struct Keep
    references::BitVector
    experiments::BitVector
    measurements::BitVector
end

"""
    keep_all(ds) -> Keep

Everything stays: the copy made from it is a complete, independent copy of `ds`.
"""
keep_all(ds::Dataset) = Keep(
    trues(length(ds.references)),
    trues(length(ds.experiments)),
    trues(length(ds.measurements)),
)

# What stays when `drop_references` (ids) and `drop_measurements` (rows) go: the experiments and
# points of a reference that goes, and an experiment whose points all went (an experiment that never
# had points stays).
function cascade(
    ds::Dataset;
    drop_references::AbstractVector{<:Integer} = Int32[],
    drop_measurements::AbstractVector{<:Integer} = Int32[],
)::Keep
    rf, ex, m = ds.references, ds.experiments, ds.measurements
    kr = trues(length(rf))
    kr[drop_references] .= false
    km = trues(length(m))
    km[drop_measurements] .= false
    ke = BitVector(kr[ex.reference[e]] for e in eachindex(ex.reference))
    total = zeros(Int32, length(ex.reference))
    left = zeros(Int32, length(ex.reference))
    @inbounds for i in eachindex(m.experiment)
        e = m.experiment[i]
        total[e] += 1
        km[i] &= ke[e]
        left[e] += km[i]
    end
    @inbounds for e in eachindex(ke)
        ke[e] && total[e] > 0 && left[e] == 0 && (ke[e] = false)
    end
    return Keep(kr, ke, km)
end

# The new id of every row that stays, and 0 for the rows that go.
function id_map(mask::AbstractVector{Bool})
    map = zeros(Int32, length(mask))
    n = Int32(0)
    @inbounds for i in eachindex(mask)
        if mask[i]
            n += Int32(1)
            map[i] = n
        end
    end
    return map
end

# The ids of `ids` through `map`; an absent id stays absent.
remap_ids(map::Vector{Int32}, ids::AbstractVector{Int32}) =
    Int32[id == NO_ID ? NO_ID : map[id] for id in ids]

copy_pool(p::StringPool) = StringPool(copy(p.strings), copy(p.index))

# The rows `idx` of a column, as a column of its own.
take(v::Vector, idx) = v[idx]
take(v::PooledFloats, idx) = typeof(v)(v.codes[idx], copy(v.pool), copy(v.lookup))
take(v::NTuple{N,<:AbstractVector}, idx) where {N} = map(c -> take(c, idx), v)
# An index (a dictionary) does not follow the rows: the table that has one gives its new one.
take(d::AbstractDict, ::Any) = d

# A table of the same kind with the rows `idx`; `changes` replaces whole columns by name.
function subset_table(t::T, idx; changes...) where {T}
    replaced =
        Dict{Int,Any}(Base.fieldindex(T, name) => column for (name, column) in changes)
    values = Any[
        haskey(replaced, i) ? replaced[i] : take(getfield(t, i), idx) for
        i = 1:fieldcount(T)
    ]
    return T(values...)
end

const POOL_FIELDS = (
    :sources,
    :groups,
    :methods,
    :phases,
    :kinds,
    :extra_keys,
    :extra_texts,
    :origins,
    :statuses,
    :suppliers,
    :analyses,
    :purifications,
    :purposes,
    :unc_methods,
    :evaluators,
    :method_texts,
    :condition_groups,
    :condition_labels,
)

# The rows of a table of notes (extras, conditions, uncertainties) that stay, with their new row.
function kept_notes(keep_row::Function, scope, row)
    idx = Int[]
    new_row = Int32[]
    @inbounds for i in eachindex(row)
        r = keep_row(scope[i], row[i])
        iszero(r) && continue
        push!(idx, i)
        push!(new_row, r)
    end
    return idx, new_row
end

"""
    subset_dataset(ds, keep) -> Dataset

A new dataset with the references, experiments and points that `keep` says stay, and everything
that they point to (samples, purity steps, extra fields, conditions, uncertainties). The compounds
and properties are all kept, so identifiers of compounds do not change. Nothing is shared with
`ds`.
"""
function subset_dataset(ds::Dataset, keep::Keep)
    rf, st, ps, ex, m =
        ds.references, ds.samples, ds.purity_steps, ds.experiments, ds.measurements
    rmap, emap, mmap =
        id_map(keep.references), id_map(keep.experiments), id_map(keep.measurements)

    # references
    ridx = findall(keep.references)
    index = Dict{String,Int32}()
    for (new, old) in enumerate(ridx)
        isempty(rf.doi[old]) || (index[rf.doi[old]] = Int32(new))
    end
    references = ReferenceTable(
        rf.doi[ridx],
        rf.title[ridx],
        rf.journal[ridx],
        rf.year[ridx],
        rf.volume[ridx],
        rf.pages[ridx],
        rf.authors[ridx],
        rf.source[ridx],
        index,
        WorkKeys(),
    )

    # samples and their purity steps
    keep_sample =
        BitVector(keep.references[st.reference[i]] for i in eachindex(st.reference))
    smap = id_map(keep_sample)
    sidx = findall(keep_sample)
    sample_reference = rmap[st.reference[sidx]]
    sample_index = Dict{Tuple{Int32,Int32,Int32},Int32}()
    for (new, old) in enumerate(sidx)
        sample_index[(sample_reference[new], st.compound[old], st.number[old])] = Int32(new)
    end
    samples = subset_table(st, sidx; reference = sample_reference, index = sample_index)
    keep_step = BitVector(keep_sample[ps.sample[i]] for i in eachindex(ps.sample))
    pidx = findall(keep_step)
    purity_steps = subset_table(ps, pidx; sample = smap[ps.sample[pidx]])

    # experiments and points
    eidx = findall(keep.experiments)
    experiments = subset_table(
        ex,
        eidx;
        reference = rmap[ex.reference[eidx]],
        samples = map(v -> remap_ids(smap, v[eidx]), ex.samples),
    )
    midx = findall(keep.measurements)
    measurements = subset_table(m, midx; experiment = emap[m.experiment[midx]])

    # notes: a row stays when what it describes stays
    kept_blocks = Set{Int32}(m.block[i] for i in midx if m.block[i] != NO_ID)
    extra_scope = Dict(code => name for (code, name) in enumerate(EXTRA_SCOPES))
    xs = ds.extras
    xidx, xrow = kept_notes(xs.scope, xs.row) do scope, row
        what = extra_scope[Int(scope)]
        what === :reference ? rmap[row] :
        what === :compound ? row :
        what === :experiment ? emap[row] :
        what === :measurement ? mmap[row] : Int32(row in kept_blocks ? row : 0)
    end
    extras = subset_table(xs, xidx; row = xrow)
    cs = ds.conditions
    cidx, crow = kept_notes(cs.scope, cs.row) do scope, row
        CONDITION_SCOPES[Int(scope)] === :experiment ? emap[row] : mmap[row]
    end
    conditions = subset_table(cs, cidx; row = crow)
    us = ds.uncertainties
    uidx, urow = kept_notes(us.scope, us.row) do scope, row
        UNCERTAINTY_SCOPES[Int(scope)] === :experiment ? emap[row] : mmap[row]
    end
    uncertainties = subset_table(us, uidx; row = urow)

    # what is not tied to a reference is copied whole
    cp, pp = ds.compounds, ds.properties
    compounds = CompoundTable(
        copy(cp.key),
        copy(cp.inchikey),
        copy(cp.inchi),
        copy(cp.formula),
        [copy(n) for n in cp.names],
        copy(cp.index),
        Ref{Union{Nothing,NameIndex}}(nothing),
    )
    properties =
        PropertyTable(copy(pp.label), copy(pp.unit), copy(pp.group), copy(pp.index))
    pools = map(name -> copy_pool(getproperty(ds, name)), POOL_FIELDS)
    created = getfield(ds, :stamps).created
    return Dataset(
        pools...,
        references,
        compounds,
        samples,
        purity_steps,
        properties,
        experiments,
        measurements,
        extras,
        conditions,
        uncertainties,
        Stamps(created, time()),
        LazyState(),
    )
end

# A complete copy of `ds` that can be changed without touching it.
copy_dataset(ds::Dataset) = subset_dataset(ds, keep_all(ds))
