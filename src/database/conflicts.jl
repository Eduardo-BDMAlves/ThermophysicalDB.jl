# What happens when the points that are added to a database are points it already has. "The same
# point" is the one of `duplicates`: the same work, system, property, and the same conditions and
# value within the `DuplicateRules`. The points are added first and the repeated ones are looked up
# afterwards with `find_repeats`, so both use one criterion; what the policy says to leave out (or
# to replace) is then taken out with `subset_dataset`, which makes a new dataset, so a refused
# addition leaves nothing behind.

const ON_CONFLICT_MODES = (:ask, :skip, :replace, :error, :keep)

function check_on_conflict(mode)
    mode in ON_CONFLICT_MODES || throw(
        ArgumentError(
            "on_conflict must be one of $(join(repr.(ON_CONFLICT_MODES), ", ")), got $(repr(mode))",
        ),
    )
    return mode
end

# The points that repeat points the member had before: `(old, new)`, the rows of the points that
# were there and the rows of the added ones (those after row `n0`) that repeat them.
function repeated_before(
    db::Database,
    m::Member,
    ds::Dataset,
    ref::Integer,
    n0::Integer,
    rules::DuplicateRules,
)
    mine = rows_of_references(ds, references_alike(ds, ref))
    (isempty(mine) || mine[1] > n0) && return (Int32[], Int32[])
    index = Int[findfirst(x -> x === m, db.members)]
    report, _ = find_repeats(db, index, [DataView(ds, mine)], rules)
    old, new = Set{Int32}(), Set{Int32}()
    for k in eachindex(report.kind)
        report.kind[k] === :duplicate || continue
        a, b = report.row[k], report.other_row[k]
        (a <= n0 && b > n0) || continue
        push!(old, a)
        push!(new, b)
    end
    return sort!(collect(old)), sort!(collect(new))
end

function conflict_summary(ds::Dataset, ref::Integer, old, new)
    rf = ds.references
    label = isempty(rf.doi[ref]) ? "reference $ref" : rf.doi[ref]
    return "$(length(new)) of the points being added to $label are already in the database " *
           "($(length(old)) points)"
end

function ask_conflict(text::String, input::IO, output::IO)
    println(output, text, ".")
    println(output, "  s  skip the new points that are already there")
    println(output, "  r  replace the old points with the new ones")
    println(output, "  k  keep both")
    println(output, "  c  cancel, nothing is added")
    for _ = 1:5
        print(output, "What to do? (s, r, k, c): ")
        flush(output)
        answer = lowercase(strip(readline(input)))
        answer == "s" && return :skip
        answer == "r" && return :replace
        answer == "k" && return :keep
        answer in ("c", "") && return :error
        println(output, "Not a valid answer.")
    end
    return :error
end

# Look at the points just added (the rows after `n0`) and apply `mode` to those that repeat points of
# the database. Returns the dataset that is left, the new row of the reference, the experiment
# map, and how many points were left out; `nothing` when nothing changed.
function resolve_conflicts!(
    db::Database,
    m::Member,
    ds::Dataset,
    ref::Integer,
    n0::Integer,
    nr0::Integer,
    mode::Symbol,
    rules::DuplicateRules,
    input::IO,
    output::IO,
)
    mode === :keep && return nothing
    old, new = repeated_before(db, m, ds, ref, n0, rules)
    isempty(new) && return nothing
    text = conflict_summary(ds, ref, old, new)
    if mode === :ask
        mode = can_ask(input, output) ? ask_conflict(text, input, output) : :error_ask
    end
    mode === :keep && return nothing
    fresh = Int32.((n0+1):length(ds.measurements))
    if mode === :error || mode === :error_ask
        hint =
            mode === :error_ask ?
            "; this session cannot ask, so say what to do with on_conflict = :skip, :replace or :keep" :
            "; on_conflict = :skip, :replace or :keep say what to do instead"
        keep = cascade(
            ds;
            drop_references = ref > nr0 ? Int32[ref] : Int32[],
            drop_measurements = fresh,
        )
        replace_dataset!(db, m, subset_dataset(ds, keep), nothing)
        throw(ArgumentError(text * hint * "; nothing was added"))
    end
    keep =
        mode === :skip ? cascade(ds; drop_measurements = new) :
        cascade(ds; drop_measurements = old)
    left = mode === :skip ? length(new) : length(old)
    detail = "reference=$(ds.references.doi[ref]) points=$left"
    replace_dataset!(
        db,
        m,
        subset_dataset(ds, keep),
        mode === :replace ? "points_replaced" : nothing,
        detail,
    )
    return (; keep, left, mode)
end
