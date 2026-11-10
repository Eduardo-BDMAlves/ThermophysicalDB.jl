# What the tables say about the samples behind a selection: purity, how it was validated,
# how the sample was purified and where it came from. Used by the reference summary and by
# the sample tables.

kind_name(code::Integer) = code == 0 ? "" : String(PURITY_KINDS[code])
basis_name(code::Integer) = code == 0 ? "" : String(PURITY_BASES[code])

"Short suffix that says on which basis a purity is stated."
function kind_suffix(code::Integer)
    code == 1 && return " mass"
    code == 2 && return " mol"
    code == 3 && return " vol"
    return ""
end

pool_strings(pool::StringPool, ids::AbstractVector{Int32}) =
    String[pool_string(pool, id) for id in ids]

"""
    SampleSummary

Texts and ranges that describe the samples of one group of points, see
[`describe_samples`](@ref).
"""
struct SampleSummary
    purity::String
    purity_min::Float64     # per cent
    purity_max::Float64
    purity_basis::String
    purity_method::String
    purification::String
    sample_source::String
    supplier::String
end

function add_unique!(list::Vector{String}, text::AbstractString)
    isempty(text) || text in list || push!(list, text)
    return list
end

"""
    describe_samples(ds, pairs; digits = 6) -> SampleSummary

Describe the samples of a group of points. `pairs` lists the (compound, sample) of its
components, with `NO_ID` for a sample the source does not describe. The purity is written
`methane 99.95 % mass` (the compound is named only when the group has more than one);
a sample without information adds nothing, like any other missing value.
"""
function describe_samples(
    ds::Dataset,
    pairs::AbstractVector{Tuple{Int32,Int32}};
    digits::Integer = 6,
)
    st = ds.samples
    several = length(unique(first.(pairs))) > 1
    purity, basis = String[], String[]
    methods, purification, origin, supplier = String[], String[], String[], String[]
    lo, hi = Inf, -Inf
    for (compound, sample) in pairs
        sample == NO_ID && continue
        p = st.purity[sample]
        if !isnan(p)
            percent = 100 * p
            lo, hi = min(lo, percent), max(hi, percent)
            text = string(
                format_number(percent, digits),
                " %",
                kind_suffix(st.purity_kind[sample]),
            )
            several && (text = string(compound_label(ds.compounds, compound), " ", text))
            add_unique!(purity, text)
            add_unique!(basis, basis_name(st.purity_basis[sample]))
        end
        foreach(
            m -> add_unique!(methods, m),
            pool_strings(ds.analyses, st.analysis[sample]),
        )
        foreach(
            m -> add_unique!(purification, m),
            pool_strings(ds.purifications, st.purification[sample]),
        )
        add_unique!(origin, pool_string(ds.origins, st.origin[sample]))
        add_unique!(supplier, pool_string(ds.suppliers, st.supplier[sample]))
    end
    return SampleSummary(
        join(purity, "; "),
        isinf(lo) ? NaN : lo,
        isinf(hi) ? NaN : hi,
        join(basis, "; "),
        join(methods, "; "),
        join(purification, "; "),
        join(origin, "; "),
        join(supplier, "; "),
    )
end

# ----------------------------------------------------------------------------------
# Tables of samples
# ----------------------------------------------------------------------------------

# Samples used by the experiments behind the points of a view, in table order.
function used_samples(view::DataView)
    ds = view.dataset
    ex, m = ds.experiments, ds.measurements
    seen_experiment = falses(length(ex))
    used = falses(length(ds.samples))
    for r in view.rows
        e = m.experiment[r]
        seen_experiment[e] && continue
        seen_experiment[e] = true
        for i = 1:Int(ex.ncomp[e])
            s = ex.samples[i][e]
            s == NO_ID || (used[s] = true)
        end
    end
    return findall(used)
end

digits_column(d::AbstractVector{UInt8}) = Int[x == NO_DIGITS ? -1 : Int(x) for x in d]

"""
    sample_table(x; ids) -> NamedTuple

One row per sample of a [`Dataset`](@ref), or of the samples behind the points of a
[`DataView`](@ref): a Tables.jl table with the columns

`sample, doi, compound, inchikey, number, origin, status, supplier, nsteps, purity,
purity_kind, purity_initial, purity_initial_kind, water, purity_basis, analysis,
purification`.

Purities and `water` are fractions, `NaN` where the source does not state them;
`purity_kind` is `"mass"`, `"mole"`, `"volume"` or `"unspecified"` (`""` without a purity)
and `purity_basis` is `"supplier"`, `"measured"` or `"estimated"` (`""` when unknown).
`analysis` and `purification` list the methods of every step, separated by `"; "`. The
ThermoML archive has no name for the supplier, so `supplier` is empty for its samples and
`origin` (`"Commercial source"`, ...) is what it says about where the sample came from.
Use [`purity_step_table`](@ref) for the steps one by one.
"""
function sample_table(ds::Dataset; ids::AbstractVector{<:Integer} = 1:length(ds.samples))
    st, rf, cp = ds.samples, ds.references, ds.compounds
    ids = collect(Int, ids)
    return (;
        sample = Int32.(ids),
        doi = String[rf.doi[st.reference[i]] for i in ids],
        compound = String[compound_label(cp, st.compound[i]) for i in ids],
        inchikey = String[cp.inchikey[st.compound[i]] for i in ids],
        number = st.number[ids],
        origin = String[pool_string(ds.origins, st.origin[i]) for i in ids],
        status = String[pool_string(ds.statuses, st.status[i]) for i in ids],
        supplier = String[pool_string(ds.suppliers, st.supplier[i]) for i in ids],
        nsteps = Int.(st.nsteps[ids]),
        purity = st.purity[ids],
        purity_kind = String[kind_name(st.purity_kind[i]) for i in ids],
        purity_initial = st.purity_initial[ids],
        purity_initial_kind = String[kind_name(st.purity_initial_kind[i]) for i in ids],
        water = st.water[ids],
        purity_basis = String[basis_name(st.purity_basis[i]) for i in ids],
        analysis = String[
            join(pool_strings(ds.analyses, st.analysis[i]), "; ") for i in ids
        ],
        purification = String[
            join(pool_strings(ds.purifications, st.purification[i]), "; ") for i in ids
        ],
    )
end

sample_table(view::DataView) = sample_table(view.dataset; ids = used_samples(view))

"""
    purity_step_table(x) -> NamedTuple

One row per purification step of the samples of `x` (a [`Dataset`](@ref) or a
[`DataView`](@ref)), with the columns `sample, doi, compound, step, mass, mole, volume,
unknown, digits, water_mass, water_mole, halide_mass, halide_mole, analysis,
analysis_text, purification, purification_text`. Amounts are fractions (`NaN` when not
stated; `unknown` is a purity without a stated basis), `digits` the significant digits of
the purity (`-1` when not given), and the methods are separated by `"; "`.
"""
function purity_step_table(
    ds::Dataset;
    samples::AbstractVector{<:Integer} = 1:length(ds.samples),
)
    ps, st, rf, cp = ds.purity_steps, ds.samples, ds.references, ds.compounds
    wanted = falses(length(st))
    wanted[samples] .= true
    rows = findall(i -> wanted[ps.sample[i]], 1:length(ps))
    sample_of = ps.sample[rows]
    return (;
        sample = sample_of,
        doi = String[rf.doi[st.reference[s]] for s in sample_of],
        compound = String[compound_label(cp, st.compound[s]) for s in sample_of],
        step = ps.step[rows],
        mass = ps.mass[rows],
        mole = ps.mole[rows],
        volume = ps.volume[rows],
        unknown = ps.unknown[rows],
        digits = digits_column(ps.digits[rows]),
        water_mass = ps.water_mass[rows],
        water_mole = ps.water_mole[rows],
        halide_mass = ps.halide_mass[rows],
        halide_mole = ps.halide_mole[rows],
        analysis = String[
            join(pool_strings(ds.analyses, ps.analysis[i]), "; ") for i in rows
        ],
        analysis_text = String[
            pool_string(ds.extra_texts, ps.analysis_text[i]) for i in rows
        ],
        purification = String[
            join(pool_strings(ds.purifications, ps.purification[i]), "; ") for i in rows
        ],
        purification_text = String[
            pool_string(ds.extra_texts, ps.purification_text[i]) for i in rows
        ],
    )
end

purity_step_table(view::DataView) =
    purity_step_table(view.dataset; samples = used_samples(view))

# Columns `table(view; details = true)` adds: the sample of each component and what the
# source says about digits and about how the uncertainty was evaluated.
function detail_columns(ds::Dataset, rows)
    m, ex, st = ds.measurements, ds.experiments, ds.samples
    n = length(rows)
    purity = ntuple(_ -> fill(NaN, n), MAX_COMPONENTS)
    kind = ntuple(_ -> fill("", n), MAX_COMPONENTS)
    basis = ntuple(_ -> fill("", n), MAX_COMPONENTS)
    purpose = Vector{String}(undef, n)
    unc_method = Vector{String}(undef, n)
    for (i, r) in enumerate(rows)
        e = m.experiment[r]
        for j = 1:Int(ex.ncomp[e])
            s = ex.samples[j][e]
            s == NO_ID && continue
            purity[j][i] = st.purity[s]
            kind[j][i] = kind_name(st.purity_kind[s])
            basis[j][i] = basis_name(st.purity_basis[s])
        end
        purpose[i] = pool_string(ds.purposes, ex.purpose[e])
        unc_method[i] = pool_string(ds.unc_methods, m.unc_method[r])
    end
    return (;
        purpose,
        unc_method,
        digits = digits_column(m.digits[rows]),
        temperature_digits = digits_column(m.temperature_digits[rows]),
        pressure_digits = digits_column(m.pressure_digits[rows]),
        purity1 = purity[1],
        purity2 = purity[2],
        purity3 = purity[3],
        purity_kind1 = kind[1],
        purity_kind2 = kind[2],
        purity_kind3 = kind[3],
        purity_basis1 = basis[1],
        purity_basis2 = basis[2],
        purity_basis3 = basis[3],
    )
end
