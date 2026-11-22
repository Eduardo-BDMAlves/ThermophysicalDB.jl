# Removing and changing points that are already in a database of the user. The points are the ones of
# a selection (`points(db; ...)`), so whatever finds points also says which ones to remove or change.
# A removal makes a new dataset without them (`subset_dataset`, the rows are numbered again); a change
# writes the columns in place (nothing is renumbered, so what the user holds stays valid) after
# every new number has been checked, and it is undone when it makes a point repeat another one and
# the user does not want that.

# One database of a selection that can be edited: the member, its dataset and the selected rows.
struct EditPart
    member::Member
    dataset::Dataset
    rows::Vector{Int32}
end

# The editable parts of a selection. A selection that holds points of the archive, of a database that
# is not of this `db`, or of a dataset that has been replaced since it was made, is refused, so
# that no point is changed or removed by a mistake.
function edit_parts(db::Database, selection)
    pairs = if selection isa DatabaseView
        selection.database === db || throw(
            ArgumentError(
                "the selection was made from another database than the one given",
            ),
        )
        [(db.members[i], part) for (i, part) in zip(selection.index, selection.parts)]
    elseif selection isa DataView
        found = [m for m in db.members if is_open(m) && member_dataset(m) === selection.dataset]
        isempty(found) && throw(
            ArgumentError(
                "the selection belongs to no database of this session (a removal or a replacement made it out of date); select the points again",
            ),
        )
        [(first(found), selection)]
    else
        throw(
            ArgumentError(
                "give a selection of points (the result of points(db; ...)), got $(typeof(selection))",
            ),
        )
    end
    parts = EditPart[]
    for (m, part) in pairs
        isempty(part.rows) && continue
        m.kind === :thermoml && throw(
            ArgumentError(
                "the selection has points of \"$(m.name)\", the ThermoML archive, which is never changed; select the points of your own databases (points(db; database = \"name\", ...))",
            ),
        )
        member_dataset(m) === part.dataset || throw(
            ArgumentError(
                "the selection of \"$(m.name)\" is out of date (the database was changed after it was made); select the points again",
            ),
        )
        push!(parts, EditPart(m, part.dataset, collect(Int32, part.rows)))
    end
    return parts
end

# ----------------------------------------------------------------------------------
# Removal
# ----------------------------------------------------------------------------------

"""
    remove_points!(db, selection; confirm = false) -> NamedTuple

Remove the points of `selection` (the result of [`points`](@ref)) from the databases of your own that
hold them. An experiment that is left without points goes with them; the references stay. Without
`confirm = true` nothing is removed and the result says what would be: `(points, experiments,
databases, removed)`. The selection must have points of databases of your own only (the archive is
never changed); take them with `points(db; source = "my_lab", ...)`. Note that `points` leaves out
a point that another database repeats unless you give `duplicate = true`.

The rows are numbered again, so the references and experiments you hold from before stop being valid
(get them again), and a selection made before is out of date. The removal is in memory until
[`save_database`](@ref), which writes `points_removed` in the audit log.

```julia
sel = points(db; source = "my_lab", doi = "10.1000/example", temperature = (300, nothing))
remove_points!(db, sel)                  # what would go
remove_points!(db, sel; confirm = true)  # remove them
```
"""
function remove_points!(db::Database, selection; confirm::Bool = false)
    parts = edit_parts(db, selection)
    plans = map(parts) do p
        keep = cascade(p.dataset; drop_measurements = p.rows)
        (;
            p,
            keep,
            points = count(!, keep.measurements),
            experiments = count(!, keep.experiments),
        )
    end
    summary = (;
        points = sum(x -> x.points, plans; init = 0),
        experiments = sum(x -> x.experiments, plans; init = 0),
        databases = String[x.p.member.name for x in plans],
        removed = confirm && !isempty(plans),
    )
    if !confirm
        isempty(plans) ||
            @info "Nothing was removed; call again with confirm = true to remove $(summary.points) points" experiments =
                summary.experiments databases = summary.databases
        return summary
    end
    for x in plans
        detail = "points=$(x.points) experiments=$(x.experiments)"
        replace_dataset!(
            db,
            x.p.member,
            subset_dataset(x.p.dataset, x.keep),
            "points_removed",
            detail,
        )
    end
    return summary
end

# ----------------------------------------------------------------------------------
# Change
# ----------------------------------------------------------------------------------

const UPDATE_COLUMNS =
    (:value, :temperature, :pressure, :unc, :unc_k, :unc_level, :x1, :x2, :x3, :phase)

# What a change of a column needs to be checked: the message and the test of one number.
function column_check(name::Symbol)
    name === :phase && return ("is a phase", x -> true)
    name === :value && return ("must be a finite number", x -> isfinite(x))
    name === :temperature &&
        return ("is in K and must be positive (NaN to clear it)", x -> isnan(x) || x > 0)
    name === :pressure && return (
        "is in kPa and must not be negative (NaN to clear it)",
        x -> isnan(x) || x >= 0,
    )
    name === :unc &&
        return ("must not be negative (NaN to clear it)", x -> isnan(x) || x >= 0)
    name === :unc_k && return (
        "is a coverage factor and must be positive (NaN to clear it)",
        x -> isnan(x) || x > 0,
    )
    name === :unc_level && return (
        "is a level of confidence between 0 and 1 (NaN to clear it)",
        x -> isnan(x) || 0 < x < 1,
    )
    return (
        "is an amount and must not be negative (NaN to clear it)",
        x -> isnan(x) || x >= 0,
    )
end

# The current numbers of a column at `rows`.
function column_values(ds::Dataset, name::Symbol, rows::Vector{Int32})
    m = ds.measurements
    col = if name === :x1
        m.composition[1]
    elseif name === :x2
        m.composition[2]
    elseif name === :x3
        m.composition[3]
    else
        getfield(m, name)
    end
    return Float64[col[r] for r in rows]
end

# The new numbers of a column for the `n` selected points, `old` being what they are now: a number
# or a vector gives them, a function is applied to each current number.
function new_numbers(
    name::Symbol,
    given,
    old::Vector{Float64},
    offset::Integer,
    total::Integer,
)
    n = length(old)
    if given isa Real
        return fill(Float64(given), n)
    elseif given isa AbstractVector
        length(given) == total || throw(
            ArgumentError(
                "$name has $(length(given)) numbers for $total selected points; give one number or one per point",
            ),
        )
        all(x -> x isa Real, given) ||
            throw(ArgumentError("$name must be numbers, a vector of numbers or a function"))
        return Float64[given[offset+i] for i = 1:n]
    elseif given isa Function
        out = Vector{Float64}(undef, n)
        for i = 1:n
            y = given(old[i])
            y isa Real || throw(
                ArgumentError(
                    "the function for $name must return a number, it returned $(repr(y)) for $(old[i])",
                ),
            )
            out[i] = Float64(y)
        end
        return out
    end
    throw(
        ArgumentError(
            "$name must be a number, a vector of numbers or a function of the current number, got $(typeof(given))",
        ),
    )
end

# The new phases of the `n` selected points as codes of the pool of phases (as numbers, like the
# other columns): a text, a vector with one text for each point of the selection or a function of
# the current text. An empty text clears the phase. A phase that the pool does not have is added to
# it, and stays there even if the change is refused later (a pool entry that no point uses is not
# shown anywhere).
function new_phases(
    ds::Dataset,
    given,
    old::Vector{Float64},
    offset::Integer,
    total::Integer,
)
    n = length(old)
    texts = if given isa AbstractString
        fill(String(given), n)
    elseif given isa AbstractVector
        length(given) == total || throw(
            ArgumentError(
                "phase has $(length(given)) texts for $total selected points; give one text or one per point",
            ),
        )
        all(x -> x isa AbstractString, given) || throw(
            ArgumentError("phase must be a text, a vector of texts or a function"),
        )
        String[given[offset+i] for i = 1:n]
    elseif given isa Function
        out = Vector{String}(undef, n)
        for i = 1:n
            current = pool_string(ds.phases, Int32(old[i]))
            y = given(current)
            y isa AbstractString || throw(
                ArgumentError(
                    "the function for phase must return a text, it returned $(repr(y)) for $(repr(current))",
                ),
            )
            out[i] = String(y)
        end
        out
    else
        throw(
            ArgumentError(
                "phase must be a text, a vector of texts or a function of the current text, got $(typeof(given))",
            ),
        )
    end
    codes = Dict{String,Float64}()
    return Float64[
        get!(codes, text) do
            clean = String(strip(text))
            isempty(clean) ? Float64(NO_ID) : Float64(intern!(ds.phases, clean))
        end for text in texts
    ]
end

function write_column!(
    ds::Dataset,
    name::Symbol,
    rows::Vector{Int32},
    values::Vector{Float64},
)
    m = ds.measurements
    if name === :phase
        @inbounds for (k, r) in enumerate(rows)
            m.phase[r] = Int32(values[k])
        end
        return nothing
    end
    col, digits = if name === :value
        (m.value, m.digits)
    elseif name === :temperature
        (m.temperature, m.temperature_digits)
    elseif name === :pressure
        (m.pressure, m.pressure_digits)
    elseif name === :unc
        (m.unc, nothing)
    elseif name === :unc_k
        (m.unc_k, nothing)
    elseif name === :unc_level
        (m.unc_level, nothing)
    else
        i = parse(Int, string(name)[2:end])
        (m.composition[i], m.composition_digits[i])
    end
    @inbounds for (k, r) in enumerate(rows)
        isequal(col[r], values[k]) && continue
        col[r] = values[k]
        # The digits the source gave no longer describe the number.
        digits === nothing || (digits[r] = NO_DIGITS)
    end
    return nothing
end

# The pairs of points `(row, row)` that repeat each other among the works of the rows `rows`, with
# one of the two among `rows`.
function repeat_pairs(
    db::Database,
    m::Member,
    ds::Dataset,
    rows::Vector{Int32},
    rules::DuplicateRules,
)
    refs = unique(ds.experiments.reference[ds.measurements.experiment[r]] for r in rows)
    alike = unique(Int32[a for ref in refs for a in references_alike(ds, ref)])
    mine = rows_of_references(ds, alike)
    index = Int[findfirst(x -> x === m, db.members)]
    report, _ = find_repeats(db, index, [DataView(ds, mine)], rules)
    selected = Set(rows)
    found = Set{Tuple{Int32,Int32}}()
    for k in eachindex(report.kind)
        report.kind[k] === :duplicate || continue
        a, b = report.row[k], report.other_row[k]
        (a in selected || b in selected) && push!(found, (min(a, b), max(a, b)))
    end
    return found
end

function ask_update_conflict(text::String, input::IO, output::IO)
    println(output, text, ".")
    println(output, "  k  keep the change (the points are repeated)")
    println(output, "  c  cancel, nothing is changed")
    for _ = 1:5
        print(output, "What to do? (k, c): ")
        flush(output)
        answer = lowercase(strip(readline(input)))
        answer == "k" && return :keep
        answer in ("c", "") && return :error
        println(output, "Not a valid answer.")
    end
    return :error
end

"""
    update_points!(db, selection; value, temperature, pressure, unc, unc_k, unc_level,
                   x1, x2, x3, phase, on_conflict = :ask, rules) -> NamedTuple

Change columns of the points of `selection` (the result of [`points`](@ref)), in the databases of your
own that hold them. Each keyword is one of:

- a **number**, the same for every point (`NaN` clears it): `pressure = 101.325`;
- a **vector** with one number for each point of the selection, in the order of the selection;
- a **function** of the current number, applied to each point: `value = v -> v * 1.002`,
  `temperature = T -> T + 0.05`.

The numbers are the ones that the database stores: `value` and `unc` in the unit that `table` shows
for the property (`units = :native`), `temperature` in K, `pressure` in kPa and `x1`, `x2`, `x3` in the
scale of the experiment. All the new numbers are checked before anything is written, with the same
rules as when a point is added, so a mistake changes nothing. The digits that the source gave for a
number that changes are forgotten (a number written with fewer digits in the source is no longer
that number). The uncertainties of the conditions (`uncertainty_table`) are not changed.

`phase` is text: the same for every point (`phase = "Liquid (saturated)"`; `""` clears it), a
vector with one text for each point, or a function of the current text. It is how a point is
said to be on the saturation curve, and what [`thermoml_phase`](@ref) translates when the points
are exported to ThermoML; the text is not checked here, so you can use a phase of your own.

Nothing is renumbered, so what you hold from before stays valid. If a change makes a point repeat
another one (see [`duplicates`](@ref)) that did not repeat it before, `on_conflict` says what to do:
`:ask` (default; asks in a terminal session, an error in a script), `:keep` (keep the change, with a
warning) or `:error` (undo it). The change is in memory until [`save_database`](@ref), which writes
`points_updated` in the audit log. The result is `(points, changed)`.

```julia
sel = points(db; source = "my_lab", doi = "10.1000/example")
update_points!(db, sel; value = v -> v * 1.002)   # a calibration factor
update_points!(db, sel; pressure = 101.325)       # one number for all
update_points!(db, sel; phase = "Liquid (saturated)")   # the points are at saturation
```
"""
function update_points!(
    db::Database,
    selection;
    on_conflict::Symbol = :ask,
    rules::DuplicateRules = DEFAULT_DUPLICATE_RULES,
    input::IO = stdin,
    output::IO = stdout,
    changes...,
)
    on_conflict in (:ask, :keep, :error) || throw(
        ArgumentError(
            "on_conflict of update_points! must be :ask, :keep or :error, got $(repr(on_conflict))",
        ),
    )
    unknown = [k for (k, _) in changes if k ∉ UPDATE_COLUMNS]
    isempty(unknown) || throw(
        ArgumentError(
            "cannot change $(repr(first(unknown))); the columns are $(join(UPDATE_COLUMNS, ", "))",
        ),
    )
    isempty(changes) && throw(
        ArgumentError("say what to change, with one of $(join(UPDATE_COLUMNS, ", "))"),
    )
    parts = edit_parts(db, selection)
    total = sum(p -> length(p.rows), parts; init = 0)

    # First pass: every new number, checked, and nothing written.
    plans = Vector{Vector{Tuple{Symbol,Vector{Float64},Vector{Float64}}}}()
    offset = 0
    for p in parts
        ds = p.dataset
        ex, m = ds.experiments, ds.measurements
        list = Tuple{Symbol,Vector{Float64},Vector{Float64}}[]
        for (name, given) in changes
            given === nothing && continue
            old = column_values(ds, name, p.rows)
            new =
                name === :phase ? new_phases(ds, given, old, offset, total) :
                new_numbers(name, given, old, offset, total)
            what, ok = column_check(name)
            for (k, x) in enumerate(new)
                ok(x) || throw(
                    ArgumentError(
                        "point $(offset + k) of the selection: $name $what, got $(repr(x))",
                    ),
                )
                if name in (:x1, :x2, :x3)
                    c = parse(Int, string(name)[2:end])
                    ncomp = Int(ex.ncomp[m.experiment[p.rows[k]]])
                    (c <= ncomp || isnan(x)) || throw(
                        ArgumentError(
                            "point $(offset + k) of the selection: $name is the amount of component $c, and the experiment has $ncomp",
                        ),
                    )
                end
            end
            push!(list, (name, old, new))
        end
        push!(plans, list)
        offset += length(p.rows)
    end
    changed = 0
    for (p, list) in zip(parts, plans), k in eachindex(p.rows)
        any(t -> !isequal(t[2][k], t[3][k]), list) && (changed += 1)
    end
    changed == 0 && return (; points = total, changed = 0)

    # Before: the repeated pairs of the works concerned, to tell the new ones.
    before = [repeat_pairs(db, p.member, p.dataset, p.rows, rules) for p in parts]

    # Second pass: write.
    for (p, list) in zip(parts, plans)
        touch!(p.dataset)
        for (name, _, new) in list
            write_column!(p.dataset, name, p.rows, new)
        end
    end
    undo() =
        for (p, list) in zip(parts, plans), (name, old, _) in list
            write_column!(p.dataset, name, p.rows, old)
        end
    try
        for (i, p) in enumerate(parts)
            fresh = setdiff(repeat_pairs(db, p.member, p.dataset, p.rows, rules), before[i])
            isempty(fresh) && continue
            text = "the change makes $(length(fresh)) pairs of points in \"$(p.member.name)\" repeat each other"
            mode = on_conflict
            if mode === :ask
                mode =
                    can_ask(input, output) ? ask_update_conflict(text, input, output) :
                    :error_ask
            end
            mode === :keep && continue
            undo()
            hint =
                mode === :error_ask ?
                "; this session cannot ask, so say what to do with on_conflict = :keep or :error" :
                "; on_conflict = :keep keeps the change"
            throw(ArgumentError(text * hint * "; nothing was changed"))
        end
    catch
        # Whatever went wrong, the numbers are the old ones.
        undo()
        rethrow()
    end
    for (p, list) in zip(parts, plans)
        columns = join((string(t[1]) for t in list), ",")
        n = count(k -> any(t -> !isequal(t[2][k], t[3][k]), list), eachindex(p.rows))
        lock(p.member.lock) do
            push!(p.member.edits, ("points_updated", "columns=$columns points=$n"))
        end
    end
    return (; points = total, changed)
end
