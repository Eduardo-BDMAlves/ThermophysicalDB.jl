# The data entry template: a spreadsheet that the user fills in and the package imports.
#
# What is here does not depend on any spreadsheet package. The functions that read and write the
# `.xlsx` file (`read_template`, `write_template`) live in the extension that is loaded with
# `using XLSX`; they hand over a `TemplateData` (the cells as they are in the file, found by the
# defined names of the workbook) and this file turns it into the arguments of `add_reference_data!`,
# naming the cell of every mistake.

"""
    TemplateExperiment

One EXP-n / PTS-n pair of a filled template: the fields of the experiment sheet, the unit, the
type of uncertainty and the coverage factor of each column of the points sheet, and the cells of
the points as they are in the file (`cells`, one row per sheet row in `rows`, 13 columns from B
to N: `x1 x2 x3 u(x1) u(x2) u(x3) T u(T) P u(P) value u(value) note`). A cell that is empty is
`missing`.
"""
struct TemplateExperiment
    file::String
    sheet::Int
    name::Any
    property::Any
    phase::Any
    method::Any
    purpose::Any
    components::Vector{Any}
    scale::Any
    source::Any
    notes::Vector{Any}
    units::Vector{Any}      # columns B to M
    unc_type::Vector{Any}   # columns B to M
    unc_k::Vector{Any}      # columns B to M
    rows::Vector{Int}
    cells::Matrix{Any}
end

"""
    TemplateData

A template as read from a file: the target database and its kind, the reference (`doi`, `authors`,
`title`, `journal`, `year`, `volume`, `pages`, `other`, as the cells hold them), the compounds (one
`NamedTuple` for each row with a name; its `row` is the row of the sheet) and the
[`TemplateExperiment`](@ref)s.
"""
struct TemplateData
    path::String
    format::Int
    package_version::String
    target::Any
    kind::Any
    reference::NamedTuple
    compounds::Vector{NamedTuple}
    experiments::Vector{TemplateExperiment}
end

# What the package tells the template about the databases and the properties of this computer.
struct TemplateInfo
    package_version::String
    schema::String
    generated::String
    databases::Vector{NamedTuple}
    properties::Vector{NamedTuple}
    lists::NamedTuple
end

TemplateInfo(version, schema, generated, databases, properties) =
    TemplateInfo(version, schema, generated, databases, properties, (;))

# Most used first; the menus of the template stay usable.
const TEMPLATE_LIST_LIMIT = 300
const TEMPLATE_LIST_KEYS = (:method, :phase, :source, :supplier, :analysis, :purification)

# The values that the databases of this computer already use for the menus of the template (the
# methods, the phases and, for the samples, the source, the supplier, how the purity was checked
# and the purification), most used first. A new point is most likely one of them, and using the
# same text lets it join the points that are already there.
function template_lists(db::Database)
    counts = Dict(key => Dict{String,Int}() for key in TEMPLATE_LIST_KEYS)
    function tally!(key, pool, ids)
        n = zeros(Int, length(pool))
        # A column holds one id per row or, for some, a list of ids per row.
        for entry in ids, id in entry
            id > 0 && (n[id] += 1)
        end
        table = counts[key]
        for (id, c) in enumerate(n)
            c == 0 && continue
            label = strip(pool.strings[id])
            isempty(label) || (table[label] = get(table, label, 0) + c)
        end
    end
    for m in db.members
        ds = member_dataset(m)
        tally!(:method, ds.methods, ds.measurements.method)
        tally!(:phase, ds.phases, ds.measurements.phase)
        tally!(:source, ds.origins, ds.samples.origin)
        tally!(:supplier, ds.suppliers, ds.samples.supplier)
        tally!(:analysis, ds.analyses, ds.samples.analysis)
        tally!(:analysis, ds.analyses, ds.purity_steps.analysis)
        tally!(:purification, ds.purifications, ds.samples.purification)
        tally!(:purification, ds.purifications, ds.purity_steps.purification)
    end
    ordered(table) = first(
        String[first(p) for p in sort!(collect(table); by = p -> (-last(p), first(p)))],
        TEMPLATE_LIST_LIMIT,
    )
    return NamedTuple{TEMPLATE_LIST_KEYS}(
        map(key -> ordered(counts[key]), TEMPLATE_LIST_KEYS),
    )
end

const TEMPLATE_FORMAT = 1
const TEMPLATE_SCHEMA = "ThermoML 2.0"
const TEMPLATE_MAX_EXPERIMENTS = 99

"""
    read_template(path) -> TemplateData

Read a filled template (needs `using XLSX`).
"""
function read_template end

"""
    write_template(path, experiments, info; fill = nothing)

Write a template with `experiments` pairs of sheets (needs `using XLSX`), with the cells of `fill`
(a [`TemplateData`](@ref)) in it when it is given.
"""
function write_template end

"""
    read_template_info(path) -> TemplateInfo

The lists of databases and of properties that an existing template carries (needs `using XLSX`).
"""
function read_template_info end

template_available() = hasmethod(read_template, Tuple{String})

function require_template_support()
    template_available() || throw(
        ArgumentError(
            "reading and writing the template needs the XLSX package: run `using XLSX` first",
        ),
    )
    return nothing
end

# ---------------------------------------------------------------------------------------------
# The template of this computer
# ---------------------------------------------------------------------------------------------

function template_info(db::Database)
    databases = NamedTuple[
        (;
            name = m.name,
            kind = String(m.kind),
            priority = m.priority,
            points = member_points(m),
            saved = m.persistent || (!isempty(m.path) && isfile(m.path)),
        ) for m in db.members
    ]
    totals = Dict{String,Tuple{String,Int,Vector{String}}}()
    for m in db.members
        ds = member_dataset(m)
        counts = zeros(Int, length(ds.properties))
        for p in ds.measurements.property
            counts[p] += 1
        end
        for (i, label) in enumerate(ds.properties.label)
            counts[i] == 0 && continue
            unit, n, found = get(totals, label, (ds.properties.unit[i], 0, String[]))
            m.name in found || push!(found, m.name)
            totals[label] = (unit, n + counts[i], found)
        end
    end
    properties = NamedTuple[
        (; label, unit, points, found_in = join(found, ", ")) for
        (label, (unit, points, found)) in totals
    ]
    sort!(properties; by = p -> (-p.points, p.label))
    return TemplateInfo(
        string(pkgversion(@__MODULE__)),
        TEMPLATE_SCHEMA,
        string(Dates.today()),
        databases,
        properties,
        template_lists(db),
    )
end

"""
    export_template(db, path; experiments = 2, overwrite = false) -> String

Write a spreadsheet that you fill in and then import with [`import_template`](@ref). It has a guide,
a sheet for the reference and the compounds of the work (with their samples), and one pair of sheets
for each experiment (what was measured, and the points, with their units and uncertainties).
`experiments` is how many pairs it has; [`add_template_experiments!`](@ref) adds more later. The
menus are filled from `db`: its databases and the properties that they already have, so that your
points join those properties. Needs `using XLSX`.

```julia
using ThermophysicalDB, XLSX
db = database()
export_template(db, "my_article.xlsx"; experiments = 3)
```
"""
function export_template(
    db::Database,
    path::AbstractString;
    experiments::Integer = 2,
    overwrite::Bool = false,
)
    require_template_support()
    check_template_count(experiments)
    path = String(path)
    (isfile(path) && !overwrite) &&
        throw(ArgumentError("$path already exists; use overwrite = true to replace it"))
    write_template(path, Int(experiments), template_info(db))
    return path
end

function check_template_count(n::Integer)
    1 <= n <= TEMPLATE_MAX_EXPERIMENTS || throw(
        ArgumentError(
            "a template has between 1 and $TEMPLATE_MAX_EXPERIMENTS experiments, got $n",
        ),
    )
    return nothing
end

"""
    add_template_experiments!(path; count = 1, db = nothing) -> Int

Add `count` pairs of experiment and points sheets to a template that you have already started
filling in; what is in the file stays where it is. The menus keep the lists the file already has,
or take them from `db` when it is given. Returns the new number of experiments. Copying the sheets
by hand does not work, because each pair is linked to its own names: use this. Needs `using XLSX`.
"""
function add_template_experiments!(
    path::AbstractString;
    count::Integer = 1,
    db::Union{Nothing,Database} = nothing,
)
    require_template_support()
    count >= 1 || throw(ArgumentError("count must be at least 1, got $count"))
    path = String(path)
    isfile(path) || throw(ArgumentError("there is no file $path"))
    data = read_template(path)
    total = length(data.experiments) + Int(count)
    check_template_count(total)
    info = db === nothing ? read_template_info(path) : template_info(db)
    write_template(path, total, info; fill = data)
    return total
end

# ---------------------------------------------------------------------------------------------
# From the cells to the arguments of add_reference_data!
# ---------------------------------------------------------------------------------------------

const TEMPLATE_SCALES = Dict(
    "Mole fraction" => :mole_fraction,
    "Mass fraction" => :mass_fraction,
    "Molality" => :molality,
    "Amount concentration" => :molarity,
)

# Factor that turns what the sheet says (unit of the composition columns) into the scale of the package.
const TEMPLATE_COMPOSITION = Dict(
    (:mole_fraction, "fraction") => 1.0,
    (:mole_fraction, "%") => 0.01,
    (:mass_fraction, "fraction") => 1.0,
    (:mass_fraction, "%") => 0.01,
    (:molality, "mol/kg") => 1.0,
    (:molarity, "mol/L") => 1.0,
    (:molarity, "mol/m3") => 1.0e-3,
)

const COMPOUND_COLUMNS = (
    :name,
    :cas,
    :inchikey,
    :supplier,
    :source,
    :purity,
    :basis,
    :purity_unc,
    :water,
    :analysis,
    :purification,
    :notes,
)

isgiven(x) =
    !(x === missing || x === nothing || (x isa AbstractString && isempty(strip(x))))
text_of(x) = isgiven(x) ? String(strip(string(x))) : ""

# Where a cell is, for the messages: `PTS-1!H12`, with the file when several are joined.
struct Place
    file::String
    many::Bool
end
function place(p::Place, sheet::AbstractString, ref::AbstractString)
    return p.many ? string(basename(p.file), " ", sheet, "!", ref) : string(sheet, "!", ref)
end

const SHEET_COLUMNS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
sheet_ref(row::Integer, col::Integer) = string(SHEET_COLUMNS[col], row)

# What the file says that this version of the package does not store.
struct TemplateArguments
    target::String
    kind::Union{Nothing,Symbol}
    reference::NamedTuple
    experiments::Vector{NamedTuple}
    where_::Vector{Tuple{String,Vector{Int}}}   # sheet and sheet rows of each experiment
    problems::Vector{String}
    ignored::Vector{String}
end

function reference_of(td::TemplateData, p::Place, problems)
    r = td.reference
    year = 0
    if isgiven(r.year)
        y = r.year
        if y isa Real && isinteger(y)
            year = Int(y)
        elseif y isa AbstractString && !isnothing(tryparse(Int, strip(y)))
            year = parse(Int, strip(y))
        else
            push!(
                problems,
                "$(place(p, "Reference", "C14")): the year must be a whole number, got $(repr(y))",
            )
        end
    end
    authors = String[text_of(a) for a in r.authors if isgiven(a)]
    if isempty(text_of(r.doi)) && isempty(authors) && !isgiven(r.title)
        push!(
            problems,
            "$(place(p, "Reference", "C9")): give the DOI, or the authors, so that the points can be credited",
        )
    end
    (!isgiven(r.year) && isempty(text_of(r.doi))) && push!(
        problems,
        "$(place(p, "Reference", "C14")): without a DOI the year is required",
    )
    return (;
        doi = text_of(r.doi),
        title = text_of(r.title),
        journal = text_of(r.journal),
        year,
        volume = text_of(r.volume),
        pages = text_of(r.pages),
        authors,
    )
end

function compound_spec(row::NamedTuple)
    return (;
        name = text_of(row.name),
        cas = text_of(row.cas),
        inchikey = text_of(row.inchikey),
    )
end

# A temperature, a pressure or a composition cell, for add_reference_data!: a number with the unit of
# its column, or the text that the user wrote.
function with_unit(x, unit::AbstractString, default::AbstractString)
    x isa Real || return x
    (isempty(unit) || unit == default) && return Float64(x)
    return string(repr(Float64(x)), " ", unit)
end

# One cell of a u(...) column as the `UncertaintyTerm` that `add_reference_data!` is given: the
# column states how it was obtained ("absolute" or "relative (%)", row 6) and its coverage factor
# (row 7). An absolute uncertainty of T or P is a difference in the unit of the column of the
# quantity; one of an amount is multiplied by the factor that brings the amounts to the scale (a
# difference of amounts). A relative one is written as a percentage, which the package takes of
# the value in K or kPa, and of the amount as stored.
function input_term_of(
    w,
    col::Integer,
    unit,
    default,
    factor,
    e::TemplateExperiment,
    p::Place,
    sheet,
    r,
    problems,
)
    cell(row) = place(p, sheet, sheet_ref(row, col + 1))
    k = e.unc_k[col]
    if !(k isa Real && k > 0)
        push!(
            problems,
            "$(cell(7)): state the coverage factor k of this uncertainty (1 for a standard uncertainty, 2 for about 95 %)",
        )
        return nothing
    end
    if w isa Real && !(isfinite(w) && w >= 0)
        push!(problems, "$(cell(r)): an uncertainty must be a number that is not negative")
        return nothing
    end
    kind = text_of(e.unc_type[col])
    if kind == "relative (%)"
        w isa Real || return UncertaintyTerm(w; k = Float64(k))
        return UncertaintyTerm(string(repr(Float64(w)), " %"); k = Float64(k))
    end
    if w isa Real
        value = factor isa Real && factor != 1 ? Float64(w) * factor : Float64(w)
        return UncertaintyTerm(with_unit(value, unit, default); k = Float64(k))
    end
    return UncertaintyTerm(w; k = Float64(k))
end

function experiment_arguments(
    e::TemplateExperiment,
    compounds::Dict{String,NamedTuple},
    p::Place,
    problems,
    ignored,
)
    sheet = string("PTS-", e.sheet)
    esheet = string("EXP-", e.sheet)
    where_ = place(p, esheet, "C5")
    isgiven(e.name) || push!(problems, "$where_: the experiment needs a name")
    prop = text_of(e.property)
    isempty(prop) && push!(problems, "$(place(p, esheet, "C6")): the property is required")
    # Components, in the order of x1, x2, x3.
    names = [text_of(c) for c in e.components]
    count = something(findlast(!isempty, names), 0)
    count == 0 && push!(problems, "$(place(p, esheet, "C12")): choose the components")
    specs = NamedTuple[]
    for i = 1:count
        if isempty(names[i])
            push!(
                problems,
                "$(place(p, esheet, sheet_ref(12, 2 + i))): components are filled in from the first cell on, without gaps",
            )
            continue
        end
        row = get(compounds, lowercase(names[i]), nothing)
        if row === nothing
            push!(
                problems,
                "$(place(p, esheet, sheet_ref(12, 2 + i))): \"$(names[i])\" is not in the compounds of the Reference sheet",
            )
        else
            push!(specs, compound_spec(row))
        end
    end
    # Scale of the composition.
    scale_text = text_of(e.scale)
    scale = if count > 1
        isempty(scale_text) ? :mole_fraction : get(TEMPLATE_SCALES, scale_text, nothing)
    else
        nothing
    end
    if count > 1 && scale === nothing
        push!(
            problems,
            "$(place(p, esheet, "C15")): the composition scale \"$scale_text\" is not supported yet; use mole fraction, mass fraction, molality or amount concentration",
        )
    end
    unit_of(j) = text_of(e.units[j])
    n = size(e.cells, 1)
    column(j) = Any[e.cells[i, j] for i = 1:n]
    # Which columns carry something that this version does not store.
    for (j, label) in ((13, "Note"),)
        any(isgiven, view(e.cells, :, j)) &&
            push!(ignored, "$sheet: the column $label is not stored yet and was ignored")
    end
    # Point by point.
    temperature = Any[NaN for _ = 1:n]
    pressure = Any[NaN for _ = 1:n]
    value = Any[NaN for _ = 1:n]
    unc = Any[NaN for _ = 1:n]
    unc_k = Any[NaN for _ = 1:n]
    x = [Any[NaN for _ = 1:n] for _ = 1:3]
    # Uncertainties of the conditions: the columns of the sheet and the cell of their coverage factor.
    u_temperature = Any[NaN for _ = 1:n]
    u_pressure = Any[NaN for _ = 1:n]
    u_x = [Any[NaN for _ = 1:n] for _ = 1:3]
    keep = Int[]
    comp_unit = [unit_of(j) for j = 1:3]
    for i = 1:n
        r = e.rows[i]
        any(isgiven, view(e.cells, i, :)) || continue
        push!(keep, i)
        function number_in(j, what)
            c = e.cells[i, j]
            isgiven(c) || return nothing
            if c isa Real || c isa AbstractString
                return c
            end
            push!(
                problems,
                "$(place(p, sheet, sheet_ref(r, j + 1))): $what must be a number, got $(repr(c))",
            )
            return nothing
        end
        v = number_in(11, "the value")
        if v === nothing
            push!(problems, "$(place(p, sheet, sheet_ref(r, 12))): the point has no value")
        else
            value[i] = v
        end
        t = number_in(7, "the temperature")
        t === nothing || (temperature[i] = with_unit(t, unit_of(7), "K"))
        q = number_in(9, "the pressure")
        q === nothing || (pressure[i] = with_unit(q, unit_of(9), "kPa"))
        u = number_in(12, "the uncertainty")
        if u !== nothing
            if u isa Real && text_of(e.unc_type[12]) == "relative (%)"
                if value[i] isa Real
                    unc[i] = Float64(value[i]) * Float64(u) / 100
                else
                    push!(
                        problems,
                        "$(place(p, sheet, sheet_ref(r, 13))): a relative uncertainty needs the value as a number",
                    )
                end
            else
                unc[i] = u
            end
            k = e.unc_k[12]
            if k isa Real
                unc_k[i] = Float64(k)
            elseif isgiven(k)
                push!(
                    problems,
                    "$(place(p, "PTS-$(e.sheet)", "M7")): the coverage factor must be a number",
                )
            end
        end
        # u(T), u(P): absolute in the unit of the column of the quantity (a difference), or relative
        # (%) of the value in an absolute scale (K, kPa), see `add_measurement!`.
        for (col, target, unit, default) in
            ((8, u_temperature, unit_of(7), "K"), (10, u_pressure, unit_of(9), "kPa"))
            w = number_in(col, "the uncertainty")
            w === nothing && continue
            term = input_term_of(w, col, unit, default, 1.0, e, p, sheet, r, problems)
            term === nothing || (target[i] = term)
        end
        for j = 1:3
            w = number_in(3 + j, "the uncertainty")
            w === nothing && continue
            if j > count
                push!(
                    ignored,
                    "$sheet: u(x$j) has values but the experiment has $count component(s); they were ignored",
                )
                continue
            end
            factor =
                scale === nothing ? nothing :
                get(TEMPLATE_COMPOSITION, (scale, comp_unit[j]), nothing)
            factor === nothing && continue    # the unit of the column is already a problem
            term = input_term_of(w, 3 + j, "", "", factor, e, p, sheet, r, problems)
            term === nothing || (u_x[j][i] = term)
        end
        for j = 1:3
            c = number_in(j, "the composition")
            c === nothing && continue
            if j > count
                push!(
                    ignored,
                    "$sheet: x$j has values but the experiment has $count component(s); they were ignored",
                )
                continue
            end
            factor =
                scale === nothing ? nothing :
                get(TEMPLATE_COMPOSITION, (scale, comp_unit[j]), nothing)
            if factor === nothing
                push!(
                    problems,
                    "$(place(p, sheet, sheet_ref(r, j + 1))): the unit \"$(comp_unit[j])\" does not go with the composition scale \"$(scale_text)\"",
                )
            elseif c isa Real
                x[j][i] = Float64(c) * factor
            else
                x[j][i] = c
            end
        end
    end
    isempty(keep) && push!(
        problems,
        "$sheet: no points; fill the points or remove the experiment from the file",
    )
    pick(v) = v[keep]
    columns = Pair{Symbol,Any}[
        :property=>prop,
        :unit=>unit_of(11),
        :phase=>text_of(e.phase),
        :method=>text_of(e.method),
        :temperature=>pick(temperature),
        :pressure=>pick(pressure),
        :value=>pick(value),
        :unc=>pick(unc),
        :unc_k=>pick(unc_k),
    ]
    for j = 1:min(count, 3)
        push!(columns, Symbol("x", j) => pick(x[j]))
    end
    any(x -> x isa UncertaintyTerm, u_temperature) &&
        push!(columns, :unc_temperature => pick(u_temperature))
    any(x -> x isa UncertaintyTerm, u_pressure) &&
        push!(columns, :unc_pressure => pick(u_pressure))
    for j = 1:min(count, 3)
        any(x -> x isa UncertaintyTerm, u_x[j]) &&
            push!(columns, Symbol("unc_x", j) => pick(u_x[j]))
    end
    purpose = text_of(e.purpose)
    purpose = isempty(purpose) ? text_of(e.name) : string(text_of(e.name), ": ", purpose)
    if !isempty(text_of(e.source)) || any(isgiven, e.notes)
        push!(
            ignored,
            "$esheet: where in the article and the notes are not stored yet and were ignored",
        )
    end
    head = (; components = specs, purpose)
    if scale !== nothing
        head = merge(head, (; composition_scale = scale))
    end
    return merge(head, (; columns...)), e.rows[keep]
end

"""
    template_arguments(data) -> TemplateArguments

Turn a [`TemplateData`](@ref) (or several of the same reference, already joined) into what
[`add_reference_data!`](@ref) is given. Every mistake that can be seen in the cells is collected
in `problems`, with the cell it is in, so that the person can fix all of them in one go.
"""
function template_arguments(td::TemplateData; many::Bool = false)
    p = Place(td.path, many)
    problems = String[]
    ignored = String[]
    reference = reference_of(td, p, problems)
    compounds = Dict{String,NamedTuple}()
    for c in td.compounds
        name = text_of(c.name)
        key = lowercase(name)
        if isempty(name)
            push!(
                problems,
                "$(place(p, "Reference", sheet_ref(c.row, 2))): the compound needs a name",
            )
        elseif haskey(compounds, key)
            push!(
                problems,
                "$(place(p, "Reference", sheet_ref(c.row, 2))): \"$name\" is listed twice",
            )
        else
            compounds[key] = c
        end
        any(
            isgiven,
            (
                c.supplier,
                c.source,
                c.purity,
                c.basis,
                c.purity_unc,
                c.water,
                c.analysis,
                c.purification,
                c.notes,
            ),
        ) && push!(
            ignored,
            "Reference: the sample data of \"$name\" (purity, supplier...) are not stored yet and were ignored",
        )
    end
    experiments = NamedTuple[]
    where_ = Tuple{String,Vector{Int}}[]
    for e in td.experiments
        any(isgiven, view(e.cells, :, :)) ||
            isgiven(e.name) ||
            isgiven(e.property) ||
            continue
        arguments, rows = experiment_arguments(e, compounds, p, problems, ignored)
        push!(experiments, arguments)
        push!(where_, (string("PTS-", e.sheet), rows))
    end
    isempty(experiments) && push!(problems, "the file has no experiment with data")
    isgiven(td.reference.other) && push!(
        ignored,
        "Reference: \"other information to cite the work\" is not stored yet and was ignored",
    )
    kind = nothing
    kind_text = text_of(td.kind)
    if !isempty(kind_text)
        kind =
            kind_text == "Literature" ? :literature : kind_text == "User" ? :user : nothing
        kind === nothing && push!(
            problems,
            "$(place(p, "Reference", "C6")): the kind of data is Literature or User, got \"$kind_text\"",
        )
    end
    return TemplateArguments(
        text_of(td.target),
        kind,
        reference,
        experiments,
        where_,
        problems,
        unique!(ignored),
    )
end

# Joins the files of one work: the reference must be the same, the compounds are joined by name and
# the experiments follow one another.
function join_templates(datas::Vector{TemplateData})
    first_data = datas[1]
    identity(d) = (
        normalize_doi(text_of(d.reference.doi)),
        isempty(text_of(d.reference.doi)) ?
        lowercase(
            text_of(first(filter(isgiven, collect(d.reference.authors)); init = "")),
        ) : "",
        isempty(text_of(d.reference.doi)) ? text_of(d.reference.year) : "",
    )
    for d in datas[2:end]
        identity(d) == identity(first_data) || throw(
            ArgumentError(
                "$(basename(d.path)) is not the same work as $(basename(first_data.path)) (the DOI, or the first author and the year, differ); import them apart",
            ),
        )
    end
    compounds = NamedTuple[]
    seen = Dict{String,NamedTuple}()
    for d in datas, c in d.compounds
        key = lowercase(text_of(c.name))
        previous = get(seen, key, nothing)
        if previous === nothing
            seen[key] = c
            push!(compounds, c)
        else
            for field in (:cas, :inchikey)
                a, b = text_of(getfield(previous, field)), text_of(getfield(c, field))
                (isempty(a) || isempty(b) || a == b) || throw(
                    ArgumentError(
                        "the compound \"$(text_of(c.name))\" has $field $a in one file and $b in another",
                    ),
                )
            end
        end
    end
    targets = unique(filter(!isempty, [text_of(d.target) for d in datas]))
    length(targets) <= 1 || throw(
        ArgumentError("the files name different target databases: $(join(targets, ", "))"),
    )
    reference = first_data.reference
    for d in datas[2:end], field in keys(reference)
        isgiven(getfield(reference, field)) || (
            reference =
                merge(reference, NamedTuple{(field,)}((getfield(d.reference, field),)))
        )
    end
    return TemplateData(
        first_data.path,
        first_data.format,
        first_data.package_version,
        isempty(targets) ? missing : targets[1],
        first_data.kind,
        reference,
        compounds,
        TemplateExperiment[e for d in datas for e in d.experiments],
    )
end

# The row of a file that a message of add_reference_data! is about: "experiment 2, point 7: ...".
function sheet_message(message::AbstractString, where_)
    m = match(r"^experiment (\d+), point (\d+): (.*)$"s, message)
    m === nothing && return message
    e, i = parse(Int, m[1]), parse(Int, m[2])
    (1 <= e <= length(where_) && 1 <= i <= length(where_[e][2])) || return message
    sheet, rows = where_[e]
    return string(sheet, ", row ", rows[i], ": ", m[3])
end

# The names of phases that the ThermoML schema accepts (`ePhaseName`).
const THERMOML_PHASES = Set{String}((
    "Crystal 5",
    "Crystal 4",
    "Crystal 3",
    "Crystal 2",
    "Crystal 1",
    "Crystal",
    "Crystal of unknown type",
    "Crystal of intercomponent compound 1",
    "Crystal of intercomponent compound 2",
    "Crystal of intercomponent compound 3",
    "Metastable crystal",
    "Glass",
    "Smectic liquid crystal",
    "Smectic liquid crystal 1",
    "Smectic liquid crystal 2",
    "Nematic liquid crystal",
    "Nematic liquid crystal 1",
    "Nematic liquid crystal 2",
    "Cholesteric liquid crystal",
    "Liquid crystal of unknown type",
    "Liquid",
    "Liquid mixture 1",
    "Liquid mixture 2",
    "Liquid mixture 3",
    "Solution",
    "Solution 1",
    "Solution 2",
    "Solution 3",
    "Solution 4",
    "Fluid (supercritical or subcritical phases)",
    "Ideal gas",
    "Gas",
    "Air at 1 atmosphere",
))

# The criteria that the data must meet to be written as a valid ThermoML file, beyond what the
# package needs to store them. Each failure is a text that says what and where.
function thermoml_failures(args::TemplateArguments, db::Database)
    failures = String[]
    r = args.reference
    if isempty(r.doi) && (isempty(r.authors) || isempty(r.title) || r.year == 0)
        push!(
            failures,
            "Reference: the citation needs the DOI, or the authors, the title and the year",
        )
    end
    known = Set{String}()
    for m in db.members
        m.kind === :thermoml || continue
        for label in member_dataset(m).properties.label
            push!(known, String(label))
        end
    end
    for (i, e) in enumerate(args.experiments)
        sheet = args.where_[i][1]
        (isempty(known) || e.property in known) || push!(
            failures,
            "$sheet: the property \"$(e.property)\" is not in the ThermoML list (name it as in the sheet Properties)",
        )
        (isempty(e.phase) || e.phase in THERMOML_PHASES) || push!(
            failures,
            "$sheet: the phase \"$(e.phase)\" is not a ThermoML phase (for example Liquid, Gas, Crystal, Solution)",
        )
        n = length(e.components)
        if n > 1
            short = 0
            for i = 1:length(e.value)
                given = count(
                    j -> (v = e[Symbol("x", j)][i]; v isa Real && !isnan(v)),
                    1:min(n, 3),
                )
                given < n - 1 && (short += 1)
            end
            short > 0 && push!(
                failures,
                "$sheet: $short point(s) of a mixture without the $(n - 1) amount(s) that define its composition",
            )
        end
        if any(u -> u isa Real && isfinite(u), e.unc) &&
           !any(k -> k isa Real && isfinite(k), e.unc_k) &&
           !any(l -> l isa Real && isfinite(l), get(e, :unc_level, ()))
            push!(
                failures,
                "$sheet: the uncertainty of the value has no coverage factor or level of confidence",
            )
        end
    end
    return failures
end

function template_report(args::TemplateArguments, points, thermoml = String[])
    return (;
        ok = isempty(args.problems),
        imported = false,
        thermoml_compatible = isempty(args.problems) && isempty(thermoml),
        thermoml_failures = thermoml,
        target = args.target,
        reference = args.reference,
        experiments = [
            (;
                sheet = args.where_[i][1],
                property = e.property,
                points = length(args.where_[i][2]),
            ) for (i, e) in enumerate(args.experiments)
        ],
        points,
        problems = args.problems,
        ignored = args.ignored,
    )
end

function problems_error(problems::Vector{String})
    shown = first(problems, 30)
    more = length(problems) - length(shown)
    return ArgumentError(
        string(
            "the template has $(length(problems)) problem(s); nothing was added:\n  - ",
            join(shown, "\n  - "),
            more > 0 ? "\n  - ... and $more more" : "",
        ),
    )
end

"""
    import_template(db, path; database = nothing, only_check = false, create = true,
                    warn_duplicates = true)

Read a template that you filled in and add its reference, experiments and points to a database of
your own, as [`add_reference_data!`](@ref) does. `path` can be a vector of files of the same work
(the same DOI, or first author and year): the compounds are joined by name and the experiments
follow one another, which is how a work with more compounds than one file holds is imported.

The database is the one named in the file (`database` overrides it); one that does not exist yet is
created (`create = false` refuses). Everything is checked before anything is added: all the
mistakes are listed at once, each with its sheet and cell, and the database stays as it was.
`only_check = true` does the same checks and **adds nothing**, not even the database of the file,
and returns a report. Both the report and the result of an import have:

- `ok` (a report only): there is no problem; `problems` lists them, with their cells;
- `imported`: whether the points were added (`false` for `only_check = true`);
- `thermoml_compatible` and `thermoml_failures`: whether the data can be written as a valid ThermoML
  file, and the criteria that fail when they cannot (a citation that cannot be identified, a property
  or a phase that is not in the ThermoML lists, a mixture without its composition, an uncertainty
  without coverage). The package stores the data in either case; see the table of requirements in
  the tutorial "Adding your own data";
- `ignored`: what the file holds that this version does not store (the data of the samples, the
  notes), which is also a warning.

Needs `using XLSX`.

```julia
report = import_template(db, "my_article.xlsx"; only_check = true)
report.problems
report.thermoml_failures
import_template(db, "my_article.xlsx")
```
"""
function import_template(
    db::Database,
    path::Union{AbstractString,AbstractVector{<:AbstractString}};
    database::Union{Nothing,AbstractString} = nothing,
    only_check::Bool = false,
    create::Bool = true,
    warn_duplicates::Bool = true,
    compounds = nothing,
)
    check = only_check
    require_template_support()
    paths = path isa AbstractString ? [String(path)] : String.(collect(path))
    isempty(paths) && throw(ArgumentError("give at least one file"))
    datas = TemplateData[read_template(p) for p in paths]
    td = length(datas) == 1 ? datas[1] : join_templates(datas)
    args = template_arguments(td; many = length(datas) > 1)
    target = database === nothing ? args.target : String(database)
    problems = copy(args.problems)
    # The database that receives the data.
    created = nothing
    member = nothing
    if isempty(target)
        try
            member = writable_member(db, nothing)
        catch err
            err isa ArgumentError || rethrow()
            push!(problems, "Reference!C5: " * err.msg)
        end
    else
        i = findfirst(m -> m.name == target, db.members)
        if i === nothing
            if create
                try
                    created = add_database!(db, target; kind = something(args.kind, :user))
                    member = created
                catch err
                    err isa ArgumentError || rethrow()
                    push!(problems, "Reference!C5: " * err.msg)
                end
            else
                push!(problems, "Reference!C5: there is no database called \"$target\"")
            end
        else
            member = db.members[i]
            if args.kind !== nothing &&
               member.kind !== args.kind &&
               member.kind !== :thermoml
                push!(
                    problems,
                    "Reference!C6: the database \"$target\" is of kind $(member.kind) but the file says $(args.kind)",
                )
            end
        end
    end
    cleanup() =
        created !== nothing &&
        any(m -> m === created, db.members) &&
        remove_member!(db, created.name)
    if !isempty(problems)
        cleanup()
        return finish_problems(args, problems, check, thermoml_failures(args, db))
    end
    result = try
        add_reference_data!(
            db;
            reference = args.reference,
            experiments = args.experiments,
            database = member.name,
            compounds,
            warn_duplicates,
            dry_run = check,
        )
    catch err
        cleanup()
        err isa ArgumentError || rethrow()
        push!(problems, sheet_message(err.msg, args.where_))
        return finish_problems(args, problems, check, thermoml_failures(args, db))
    end
    check && cleanup()
    isempty(args.ignored) ||
        @warn "Some of what the file holds is not stored yet" ignored = args.ignored
    failures = thermoml_failures(args, db)
    check && return template_report(args, result.points, failures)
    return merge(
        result,
        (;
            imported = true,
            thermoml_compatible = isempty(failures),
            thermoml_failures = failures,
            ignored = args.ignored,
        ),
    )
end

function finish_problems(
    args::TemplateArguments,
    problems,
    check::Bool,
    failures = String[],
)
    check && return template_report(
        TemplateArguments(
            args.target,
            args.kind,
            args.reference,
            args.experiments,
            args.where_,
            problems,
            args.ignored,
        ),
        0,
        failures,
    )
    throw(problems_error(problems))
end
