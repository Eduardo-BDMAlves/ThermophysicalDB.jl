# Summary of the articles behind a selection: one row for every (article, property) pair,
# with the number of points, the ranges of temperature and pressure, the methods and the
# uncertainty. It can be shown in the REPL, used as a Tables.jl table, or written as LaTeX
# (citing the keys of the BibTeX export), Markdown or CSV.

# ----------------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------------

const MONTH_NAMES =
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

"Month number of a BibTeX `month` field (`jan`, `January`, `1`); 0 when unknown."
function parse_month(text::Union{Nothing,AbstractString})
    text === nothing && return 0
    t = lowercase(strip(String(text)))
    n = tryparse(Int, t)
    n !== nothing && return 1 <= n <= 12 ? n : 0
    idx = findfirst(==(first(t, 3)), MONTH_NAMES)
    return idx === nothing ? 0 : idx
end

plain_text(s::AbstractString) = replace(s, r"[{}]" => "")

"""
    citation_text(entry) -> String

`Chirico (2003)`, `Chirico and Frenkel (2003)` or `Chirico et al. (2003)`; the key when the
entry has no author.
"""
function citation_text(entry::BibEntry)
    authors = field_value(entry, "author")
    authors === nothing && return entry.key
    names = [plain_text(first_author_surname(a)) for a in split(authors, " and ")]
    year = field_value(entry, "year")
    tail = year === nothing ? "" : " ($year)"
    length(names) == 1 && return string(names[1], tail)
    length(names) == 2 && return string(names[1], " and ", names[2], tail)
    return string(names[1], " et al.", tail)
end

const SMALL_WORDS =
    ("a", "an", "and", "by", "for", "from", "in", "of", "on", "the", "to", "with")

"Initials of the words of a method name, without small words: `Vibrating tube method` becomes `VTM`."
function abbreviate_method(name::AbstractString)
    words = split(replace(name, r"[^\p{L}\p{N}]+" => " "))
    initials = [uppercase(first(w)) for w in words if lowercase(w) ∉ SMALL_WORDS]
    return isempty(initials) ? String(name) : String(initials)
end

"""
    display_method!(legend, abbreviations, name, max_length) -> String

The name itself when it has at most `max_length` characters, otherwise its initials. Two
different long names with the same initials get a number (`VTM`, `VTM2`). The pairs
initials => name accumulate in `legend`, to be explained in a note.
"""
function display_method!(
    legend::Dict{String,String},
    abbreviations::Dict{String,String},
    name::AbstractString,
    max_length::Integer,
)
    length(name) <= max_length && return String(name)
    return get!(abbreviations, String(name)) do
        base = abbreviate_method(name)
        abbreviation = base
        k = 1
        while haskey(legend, abbreviation) && legend[abbreviation] != name
            k += 1
            abbreviation = string(base, k)
        end
        legend[abbreviation] = String(name)
        abbreviation
    end
end

"Median or mean of `values` (reordered in place); NaN when empty."
function central(values::Vector{Float64}, statistic::Symbol)
    n = length(values)
    n == 0 && return NaN
    if statistic === :median
        sort!(values)
        mid = n ÷ 2
        return isodd(n) ? values[mid+1] : (values[mid] + values[mid+1]) / 2
    end
    return sum(values) / n
end

"`x`, in the native unit of `kind`, expressed in `to` (a unit name or a unit of a units package); NaN stays NaN."
# A limit that is missing (infinite or NaN) stays missing, as NaN.
convert_value(x::Float64, kind, to) = isfinite(x) ? convert_native(x, kind, to) : NaN

# ----------------------------------------------------------------------------------
# The summary
# ----------------------------------------------------------------------------------

"""
    ReferenceSummary

The result of [`reference_summary`](@ref): a Tables.jl table with one row per (article,
property), plus the explanation of the abbreviated methods (`legend`) and the bibliography
whose keys the rows use. Its columns are

`key, doi, year, month, citation, property, unit, system, method, method_full, phase,
n_points, n_uncertainty, T_min, T_max, p_min, p_max, unc_abs, unc_rel, purity, purity_min,
purity_max, purity_basis, purity_method, purification, sample_source, supplier`.

`T_min`, `T_max`, `p_min` and `p_max` are in `temperature_unit` and `pressure_unit`;
`unc_abs` is in `unit` (the unit of the property) and `unc_rel` is a percentage, as are
`purity_min` and `purity_max`.
"""
struct ReferenceSummary
    columns::NamedTuple
    legend::Vector{Pair{String,String}}
    temperature_unit::String
    pressure_unit::String
    statistic::Symbol
    bibliography::Bibliography
end

const SUMMARY_FIELDS =
    (:columns, :legend, :temperature_unit, :pressure_unit, :statistic, :bibliography)

function Base.getproperty(s::ReferenceSummary, name::Symbol)
    name in SUMMARY_FIELDS && return getfield(s, name)
    return getproperty(getfield(s, :columns), name)
end

Base.propertynames(s::ReferenceSummary, private::Bool = false) =
    (propertynames(getfield(s, :columns))..., SUMMARY_FIELDS...)

Base.length(s::ReferenceSummary) = length(getfield(s, :columns).key)

Tables.istable(::Type{ReferenceSummary}) = true
Tables.columnaccess(::Type{ReferenceSummary}) = true
Tables.columns(s::ReferenceSummary) = getfield(s, :columns)
Tables.schema(s::ReferenceSummary) = Tables.schema(getfield(s, :columns))

"""
    reference_summary(view; temperature_unit = "K", pressure_unit = "MPa",
                      statistic = :median, method_length = 24, purity_digits = 6,
                      policy = :nominal,
                      online = true, cache = true, refresh = false, include_source = true,
                      include_package = true, progress = true) -> ReferenceSummary

Summarise the articles behind the points of `view` ([`DataView`](@ref) or
[`Dataset`](@ref)), one row for every (article, property) pair, so an article that
measured two properties has two rows.

Each row has the number of points, the ranges of temperature and pressure (in the units
you choose: a name such as `"K"`, `"°C"`, `"MPa"` or `"bar"`, or a unit of a units package
whose extension is loaded, for example `u"MPa"` from Unitful), the methods and phases, and the
expanded uncertainty at ``k = 2`` over the points that state one: the `statistic`
(`:median`, the default, or `:mean`) of the relative uncertainty in percent, and of the
absolute uncertainty in the unit of the property. A method name longer than
`method_length` characters is replaced by its initials, and `legend` explains them.

The rows are ordered by year, then by month (when the DOI entry has it), then by the key
of the entry. The keys are those of [`bibtex`](@ref); the keywords `online`, `cache`,
`refresh`, `include_source`, `include_package` and `progress` act as there. `policy` is passed to the
conversion of uncertainties to ``k = 2`` (see [`table`](@ref)).
"""
function reference_summary(
    view::DataView;
    temperature_unit = "K",
    pressure_unit = "MPa",
    statistic::Symbol = :median,
    method_length::Integer = 24,
    purity_digits::Integer = 6,
    policy::Symbol = :nominal,
    kwargs...,
)
    statistic in (:median, :mean) ||
        throw(ArgumentError("statistic must be :median or :mean, got :$statistic"))
    bib = collect_bibliography(view; kwargs...)
    ds = view.dataset
    m, ex, rf, pr = ds.measurements, ds.experiments, ds.references, ds.properties

    position = zeros(Int, length(rf))
    for (k, i) in enumerate(bib.ids)
        position[i] = k
    end

    # one accumulator per (reference, property), filled in a single pass over the points
    index = Dict{Tuple{Int32,Int32},Int}()
    group_ref = Int32[]
    group_prop = Int32[]
    npoints = Int[]
    tmin, tmax, pmin, pmax = Float64[], Float64[], Float64[], Float64[]
    methods = Vector{Vector{String}}()
    phases = Vector{Vector{String}}()
    systems = Vector{Vector{String}}()
    relative = Vector{Vector{Float64}}()
    absolute = Vector{Vector{Float64}}()
    group_samples = Vector{Vector{Tuple{Int32,Int32}}}()
    last_experiment = Int32[]
    labels = Vector{Union{Nothing,String}}(nothing, length(ex.reference))

    for r in view.rows
        e = m.experiment[r]
        ref = ex.reference[e]
        ref == NO_ID && continue
        p = m.property[r]
        key = (ref, p)
        g = get(index, key, 0)
        if g == 0
            push!(group_ref, ref)
            push!(group_prop, p)
            push!(npoints, 0)
            push!(tmin, Inf)
            push!(tmax, -Inf)
            push!(pmin, Inf)
            push!(pmax, -Inf)
            push!(methods, String[])
            push!(phases, String[])
            push!(systems, String[])
            push!(relative, Float64[])
            push!(absolute, Float64[])
            push!(group_samples, Tuple{Int32,Int32}[])
            push!(last_experiment, NO_ID)
            g = length(group_ref)
            index[key] = g
        end
        npoints[g] += 1
        if last_experiment[g] != e
            last_experiment[g] = e
            for i = 1:Int(ex.ncomp[e])
                pair = (ex.components[i][e], ex.samples[i][e])
                pair in group_samples[g] || push!(group_samples[g], pair)
            end
        end
        T = m.temperature[r]
        if !isnan(T)
            tmin[g] = min(tmin[g], T)
            tmax[g] = max(tmax[g], T)
        end
        P = m.pressure[r]
        if !isnan(P)
            pmin[g] = min(pmin[g], P)
            pmax[g] = max(pmax[g], P)
        end
        method = pool_string(ds.methods, m.method[r])
        isempty(method) || method in methods[g] || push!(methods[g], method)
        phase = pool_string(ds.phases, m.phase[r])
        isempty(phase) || phase in phases[g] || push!(phases[g], phase)
        label = labels[e]
        if label === nothing
            label = system_label(ds, e)
            labels[e] = label
        end
        label in systems[g] || push!(systems[g], label)
        u2, _ = k2_uncertainty(m.unc[r], m.unc_k[r], m.unc_level[r], policy)
        if !isnan(u2)
            push!(absolute[g], u2)
            v = m.value[r]
            (v != 0 && !isnan(v)) && push!(relative[g], 100 * u2 / abs(v))
        end
    end

    # order: year, month, key, property
    entry_of(g) = bib.entries[position[group_ref[g]]]
    years = Int[
        something(
            tryparse(Int, something(field_value(entry_of(g), "year"), "")),
            Int(rf.year[group_ref[g]]),
        ) for g in eachindex(group_ref)
    ]
    months =
        Int[parse_month(field_value(entry_of(g), "month")) for g in eachindex(group_ref)]
    keys_ = String[entry_of(g).key for g in eachindex(group_ref)]
    names = String[pr.label[group_prop[g]] for g in eachindex(group_ref)]
    order = sortperm(collect(zip(years, months, lowercase.(keys_), names)))

    legend = Dict{String,String}()
    abbreviations = Dict{String,String}()
    method_full = String[join(methods[g], "; ") for g in order]
    method_shown = String[
        join(
            (display_method!(legend, abbreviations, x, method_length) for x in methods[g]),
            "; ",
        ) for g in order
    ]

    described =
        [describe_samples(ds, group_samples[g]; digits = purity_digits) for g in order]
    from_T, from_p = NativeTemperature(), NativePressure()
    columns = (;
        key = keys_[order],
        doi = String[rf.doi[group_ref[g]] for g in order],
        year = years[order],
        month = months[order],
        citation = String[citation_text(entry_of(g)) for g in order],
        property = names[order],
        unit = String[pr.unit[group_prop[g]] for g in order],
        system = String[join(systems[g], "; ") for g in order],
        method = method_shown,
        method_full = method_full,
        phase = String[join(phases[g], "; ") for g in order],
        n_points = npoints[order],
        n_uncertainty = Int[length(absolute[g]) for g in order],
        T_min = Float64[convert_value(tmin[g], from_T, temperature_unit) for g in order],
        T_max = Float64[convert_value(tmax[g], from_T, temperature_unit) for g in order],
        p_min = Float64[convert_value(pmin[g], from_p, pressure_unit) for g in order],
        p_max = Float64[convert_value(pmax[g], from_p, pressure_unit) for g in order],
        unc_abs = Float64[central(absolute[g], statistic) for g in order],
        unc_rel = Float64[central(relative[g], statistic) for g in order],
        purity = String[d.purity for d in described],
        purity_min = Float64[d.purity_min for d in described],
        purity_max = Float64[d.purity_max for d in described],
        purity_basis = String[d.purity_basis for d in described],
        purity_method = String[d.purity_method for d in described],
        purification = String[d.purification for d in described],
        sample_source = String[d.sample_source for d in described],
        supplier = String[d.supplier for d in described],
    )
    return ReferenceSummary(
        columns,
        sort!(collect(legend); by = first),
        string(temperature_unit),
        string(pressure_unit),
        statistic,
        bib,
    )
end

reference_summary(ds::Dataset; kwargs...) = reference_summary(DataView(ds); kwargs...)

"""
    bibtex(summary::ReferenceSummary) -> String

The BibTeX entries whose keys the rows of `summary` use.
"""
bibtex(s::ReferenceSummary) = render_bibliography(getfield(s, :bibliography))

# ----------------------------------------------------------------------------------
# Cells
# ----------------------------------------------------------------------------------

"A number with at most `digits` significant digits and no trailing `.0`; `--` for NaN."
function format_number(x::Real, digits::Integer)
    isnan(x) && return "--"
    s = string(round(Float64(x); sigdigits = digits))
    endswith(s, ".0") && (s = chop(s; tail = 2))
    return s
end

function format_range(lo::Real, hi::Real, digits::Integer, dash::AbstractString)
    isnan(lo) && return "--"
    a, b = format_number(lo, digits), format_number(hi, digits)
    return a == b ? a : string(a, dash, b)
end

const LATEX_ESCAPES = Dict{Char,String}(
    '\\' => "\\textbackslash{}",
    '&' => "\\&",
    '%' => "\\%",
    '$' => "\\\$",
    '#' => "\\#",
    '_' => "\\_",
    '{' => "\\{",
    '}' => "\\}",
    '~' => "\\textasciitilde{}",
    '^' => "\\textasciicircum{}",
    '°' => "\\textdegree{}",
    'μ' => "\\textmu{}",
    'µ' => "\\textmu{}",
)

latex_escape(s::AbstractString) = join((get(LATEX_ESCAPES, c, string(c)) for c in s))

const SUMMARY_COLUMNS = (
    :reference,
    :property,
    :system,
    :method,
    :phase,
    :points,
    :temperature,
    :pressure,
    :uncertainty,
    :uncertainty_abs,
    :purity,
    :purity_basis,
    :purity_method,
    :purification,
    :sample_source,
    :supplier,
)

"The columns shown by default: the property and the system only when they vary."
function default_columns(s::ReferenceSummary)
    c = getfield(s, :columns)
    cols = Symbol[:reference]
    length(unique(c.property)) > 1 && push!(cols, :property)
    length(unique(c.system)) > 1 && push!(cols, :system)
    any(!isempty, c.method) && push!(cols, :method)
    append!(cols, (:points, :temperature, :pressure, :uncertainty))
    any(!isempty, c.purity) && push!(cols, :purity)
    any(!isempty, c.purity_method) && push!(cols, :purity_method)
    any(!isempty, c.purification) && push!(cols, :purification)
    return cols
end

function column_header(s::ReferenceSummary, col::Symbol, latex::Bool)
    T, p = getfield(s, :temperature_unit), getfield(s, :pressure_unit)
    esc = latex ? latex_escape : identity
    col === :reference && return "Reference"
    col === :property && return "Property"
    col === :system && return "System"
    col === :method && return "Method"
    col === :phase && return "Phase"
    col === :points && return latex ? "\$N\$" : "N"
    col === :temperature &&
        return latex ? string("\$T\$ [", esc(T), "]") : string("T [", T, "]")
    col === :pressure &&
        return latex ? string("\$p\$ [", esc(p), "]") : string("p [", p, "]")
    col === :uncertainty && return latex ? "\$U_\\mathrm{r}\$ [\\%]" : "U_r [%]"
    col === :uncertainty_abs && return latex ? "\$U\$" : "U"
    col === :purity && return "Purity"
    col === :purity_basis && return "Purity basis"
    col === :purity_method && return "Purity analysis"
    col === :purification && return "Purification"
    col === :sample_source && return "Sample source"
    col === :supplier && return "Supplier"
    throw(ArgumentError("unknown column :$col; choose from $(SUMMARY_COLUMNS)"))
end

function cell_value(
    s::ReferenceSummary,
    col::Symbol,
    i::Integer,
    mode::Symbol,
    reference::Symbol,
    digits::Integer,
    uncertainty_digits::Integer,
)
    c = getfield(s, :columns)
    latex = mode === :latex
    esc = latex ? latex_escape : identity
    dash = latex ? "--" : "–"
    if col === :reference
        reference === :key && return esc(c.key[i])
        reference === :cite && latex && return string("\\cite{", c.key[i], "}")
        return esc(c.citation[i])
    end
    col === :property && return esc(c.property[i])
    col === :system && return esc(c.system[i])
    col === :method && return esc(c.method[i])
    col === :phase && return esc(c.phase[i])
    col === :purity && return esc(c.purity[i])
    col === :purity_basis && return esc(c.purity_basis[i])
    col === :purity_method && return esc(c.purity_method[i])
    col === :purification && return esc(c.purification[i])
    col === :sample_source && return esc(c.sample_source[i])
    col === :supplier && return esc(c.supplier[i])
    col === :points && return string(c.n_points[i])
    col === :temperature && return format_range(c.T_min[i], c.T_max[i], digits, dash)
    col === :pressure && return format_range(c.p_min[i], c.p_max[i], digits, dash)
    col === :uncertainty && return format_number(c.unc_rel[i], uncertainty_digits)
    if col === :uncertainty_abs
        isnan(c.unc_abs[i]) && return "--"
        return string(format_number(c.unc_abs[i], uncertainty_digits), " ", esc(c.unit[i]))
    end
    throw(ArgumentError("unknown column :$col; choose from $(SUMMARY_COLUMNS)"))
end

function summary_cells(
    s::ReferenceSummary,
    columns,
    rows,
    mode::Symbol,
    reference::Symbol,
    digits::Integer,
    uncertainty_digits::Integer,
)
    header = String[column_header(s, col, mode === :latex) for col in columns]
    cells = [
        String[
            cell_value(s, col, i, mode, reference, digits, uncertainty_digits) for
            col in columns
        ] for i in rows
    ]
    return header, cells
end

function legend_text(s::ReferenceSummary, mode::Symbol)
    legend = getfield(s, :legend)
    isempty(legend) && return ""
    esc = mode === :latex ? latex_escape : identity
    return join((string(esc(a), ", ", esc(n)) for (a, n) in legend), "; ")
end

# ----------------------------------------------------------------------------------
# LaTeX, Markdown, CSV and the REPL
# ----------------------------------------------------------------------------------

function default_caption(s::ReferenceSummary)
    stat = getfield(s, :statistic) === :median ? "median" : "mean"
    return string(
        "Experimental data of the selected articles: number of points \$N\$, ranges of ",
        "temperature and pressure, and ",
        stat,
        " relative expanded uncertainty \$U_\\mathrm{r}\$ (\$k=2\$) of the points that state one.",
    )
end

# Whether the notice of the data is written with a summary: its points come from the archive.
notice_wanted(s::ReferenceSummary, notice::Bool) =
    notice && getfield(s, :bibliography).from_archive

"""
    latex_table(summary; columns, caption, label, reference = :cite, digits = 4,
                uncertainty_digits = 2, notice = true) -> String

The summary as a `longtable` with `booktabs` rules (load `longtable` and `booktabs`). The
reference column holds `\\cite{key}` with the keys of the BibTeX export
(`reference = :text` writes `Author et al. (year)` instead, `:key` the key). Abbreviated
methods are explained in a note at the end of the table. `columns` is a list taken from
`:reference, :property, :system, :method, :phase, :points, :temperature, :pressure,
:uncertainty, :uncertainty_abs, :purity, :purity_basis, :purity_method, :purification,
:sample_source, :supplier`; by default the property and the system appear only when they
vary, and the purity, its analysis and the purification only when an article states them. `digits` and `uncertainty_digits` are significant digits. The caption may use
LaTeX; the rest of the text is escaped.

Data from the ThermoML Archive come with a notice (origin, citation of the dataset and
conditions of use) as comments at the top of the text; `notice = false` leaves it out.
"""
function latex_table(
    s::ReferenceSummary;
    columns = default_columns(s),
    caption::AbstractString = default_caption(s),
    label::AbstractString = "tab:references",
    reference::Symbol = :cite,
    digits::Integer = 4,
    uncertainty_digits::Integer = 2,
    notice::Bool = true,
)
    header, cells = summary_cells(
        s,
        columns,
        1:length(s),
        :latex,
        reference,
        digits,
        uncertainty_digits,
    )
    n = length(columns)
    align = join((
        col === :method ? "p{3.4cm}" :
        col === :system ? "p{3.2cm}" :
        col in (:purity, :purity_method, :purification) ? "p{3cm}" :
        col in (:reference, :property, :phase, :purity_basis, :sample_source, :supplier) ?
        "l" : "c" for col in columns
    ),)
    io = IOBuffer()
    if notice_wanted(s, notice)
        for line in notice_lines()
            println(io, "% ", line)
        end
    end
    println(io, "% Requires: \\usepackage{booktabs} and \\usepackage{longtable}")
    println(io, "\\begin{longtable}{", align, "}")
    println(io, "\\caption{", caption, "}\\label{", label, "}\\\\")
    head = join(header, " & ") * " \\\\"
    println(io, "\\toprule\n", head, "\n\\midrule\n\\endfirsthead")
    println(io, "\\toprule\n", head, "\n\\midrule\n\\endhead")
    println(
        io,
        "\\midrule\n\\multicolumn{",
        n,
        "}{r}{\\footnotesize\\emph{continued on the next page}} \\\\\n\\endfoot",
    )
    note = :method in columns ? legend_text(s, :latex) : ""
    if isempty(note)
        println(io, "\\bottomrule\n\\endlastfoot")
    else
        println(
            io,
            "\\bottomrule\n\\multicolumn{",
            n,
            "}{p{0.95\\linewidth}}{\\footnotesize \\textbf{Methods:} ",
            note,
            ".} \\\\\n\\endlastfoot",
        )
    end
    for row in cells
        println(io, join(row, " & "), " \\\\")
    end
    println(io, "\\end{longtable}")
    return String(take!(io))
end

"""
    markdown_table(summary; columns, reference = :text, digits = 4, uncertainty_digits = 2,
                   notice = true) -> String

The summary as a Markdown (GitHub flavoured) table, with the explanation of abbreviated
methods below it. The arguments are those of [`latex_table`](@ref); the notice is an HTML
comment at the top.
"""
function markdown_table(
    s::ReferenceSummary;
    columns = default_columns(s),
    reference::Symbol = :text,
    digits::Integer = 4,
    uncertainty_digits::Integer = 2,
    notice::Bool = true,
)
    header, cells =
        summary_cells(s, columns, 1:length(s), :text, reference, digits, uncertainty_digits)
    pipe(x) = replace(x, "|" => "\\|")
    io = IOBuffer()
    if notice_wanted(s, notice)
        println(io, "<!--")
        foreach(line -> println(io, line), notice_lines())
        println(io, "-->\n")
    end
    println(io, "| ", join(pipe.(header), " | "), " |")
    println(io, "|", join(fill("---", length(columns)), "|"), "|")
    for row in cells
        println(io, "| ", join(pipe.(row), " | "), " |")
    end
    note = :method in columns ? legend_text(s, :text) : ""
    isempty(note) || println(io, "\nMethods: ", note, ".")
    return String(take!(io))
end

csv_field(x::AbstractString) =
    any(c -> c in (',', '"', '\n', '\r'), x) ?
    string('"', replace(x, "\"" => "\"\""), '"') : String(x)
csv_field(x::Real) = isnan(x) ? "" : string(x)

"""
    summary_fields(summary) -> Vector{Pair{String,Any}}

Every column of the summary with the header it has in the CSV and Excel exports: the units
are in the header (`T_min [K]`, `p_max [MPa]`, `unc_rel [%]`) and the method is written out.
"""
function summary_fields(s::ReferenceSummary)
    c = getfield(s, :columns)
    T, p = getfield(s, :temperature_unit), getfield(s, :pressure_unit)
    return Pair{String,Any}[
        "key"=>c.key,
        "doi"=>c.doi,
        "year"=>c.year,
        "month"=>c.month,
        "citation"=>c.citation,
        "property"=>c.property,
        "unit"=>c.unit,
        "system"=>c.system,
        "method"=>c.method_full,
        "phase"=>c.phase,
        "n_points"=>c.n_points,
        "n_uncertainty"=>c.n_uncertainty,
        string("T_min [", T, "]")=>c.T_min,
        string("T_max [", T, "]")=>c.T_max,
        string("p_min [", p, "]")=>c.p_min,
        string("p_max [", p, "]")=>c.p_max,
        "unc_abs [property unit]"=>c.unc_abs,
        "unc_rel [%]"=>c.unc_rel,
        "purity"=>c.purity,
        "purity_min [%]"=>c.purity_min,
        "purity_max [%]"=>c.purity_max,
        "purity_basis"=>c.purity_basis,
        "purity_method"=>c.purity_method,
        "purification"=>c.purification,
        "sample_source"=>c.sample_source,
        "supplier"=>c.supplier,
    ]
end

"""
    csv_table(summary; notice = true) -> String

All the columns of the summary as CSV, with full method names and the units in the
headers (`T_min [K]`, `p_max [MPa]`, `unc_rel [%]`). For data from the ThermoML Archive the
first line is the notice, a comment starting with `#`; skip it when reading
(`header = 2`), or pass `notice = false`.
"""
function csv_table(s::ReferenceSummary; notice::Bool = true)
    fields = summary_fields(s)
    io = IOBuffer()
    notice_wanted(s, notice) && println(io, "# ", notice_line())
    println(io, join((csv_field(first(f)) for f in fields), ","))
    for i = 1:length(s)
        println(io, join((csv_field(last(f)[i]) for f in fields), ","))
    end
    return String(take!(io))
end

function Base.show(io::IO, ::MIME"text/plain", s::ReferenceSummary; maxrows::Int = 12)
    n = length(s)
    println(io, "ReferenceSummary: ", n, n == 1 ? " row" : " rows")
    n == 0 && return nothing
    columns = default_columns(s)
    shown = 1:min(n, maxrows)
    header, cells = summary_cells(s, columns, shown, :text, :text, 4, 2)
    widths = [
        maximum(textwidth, [header[j]; [row[j] for row in cells]]) for
        j in eachindex(header)
    ]
    line(row) = join((rpad(x, widths[j]) for (j, x) in enumerate(row)), "  ")
    println(io, "  ", line(header))
    for row in cells
        println(io, "  ", line(row))
    end
    n > maxrows && println(io, "  ... ", n - maxrows, " more rows")
    note = :method in columns ? legend_text(s, :text) : ""
    isempty(note) || print(io, "  Methods: ", note)
    return nothing
end

Base.show(io::IO, s::ReferenceSummary) = print(io, "ReferenceSummary(", length(s), " rows)")

"""
    write_references(prefix, view; formats = (:bib, :tex, :md, :csv), table = (;), kwargs...)
        -> ReferenceSummary

Write the references of a selection in one go, so that the files agree: `prefix.bib` (the
entries of [`bibtex`](@ref)), `prefix.tex` ([`latex_table`](@ref)), `prefix.md`
([`markdown_table`](@ref)) and `prefix.csv` ([`csv_table`](@ref)); `formats` chooses
which. `table` holds the keywords of the table writers (`columns`, `digits`, ...) and the
rest, those of [`reference_summary`](@ref). The summary is returned.

# Examples
```julia
summary = write_references("water", v; pressure_unit = "kPa", statistic = :mean)
```
"""
function write_references(
    prefix::AbstractString,
    view::DataView;
    formats = (:bib, :tex, :md, :csv),
    table = (;),
    kwargs...,
)
    s = reference_summary(view; kwargs...)
    for format in formats
        if format === :bib
            write(string(prefix, ".bib"), bibtex(s))
        elseif format === :tex
            write(string(prefix, ".tex"), latex_table(s; table...))
        elseif format === :md
            write(string(prefix, ".md"), markdown_table(s; table...))
        elseif format === :csv
            write(string(prefix, ".csv"), csv_table(s))
        else
            throw(
                ArgumentError("unknown format :$format; choose from :bib, :tex, :md, :csv"),
            )
        end
    end
    return s
end

write_references(prefix::AbstractString, ds::Dataset; kwargs...) =
    write_references(prefix, DataView(ds); kwargs...)
