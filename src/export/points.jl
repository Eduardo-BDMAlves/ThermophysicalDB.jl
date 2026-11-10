# Export of the points of a selection: one function (`export_points`) that writes a directory
# holding the formats that were asked for, and one internal writer per format. Every writer
# starts from the same `ExportData`, so the files of one export agree with each other: same
# columns, same units, same reference keys.
#
#   .csv           one table with the unit of every column in its header
#   .md            the same table as a Markdown (pipe) table
#   .tex           the same table as a LaTeX `longtable`
#   .json          one record per point
#   .jld2          columns, units and references as Julia data
#   .xlsx          one sheet per system, plus `references` and `origin` (needs the XLSX package)
#   .thermoml.json ThermoML in the JSON form of the archive (see thermoml.jl)
#   .thermoml/     one ThermoML XML document per article
#
# Tables hold only points. What describes an article lives in the references table, which
# is linked to the points by the `reference` column (BibTeX key, written-out citation or DOI).

const POINT_FORMATS = (:csv, :md, :tex, :json, :jld2, :xlsx, :thermoml, :thermoml_xml)
# What is written when `formats` is not given; `:xlsx` is added when the XLSX package is loaded.
const DEFAULT_FORMATS = (:csv, :md, :tex, :json, :jld2)
const REFERENCE_STYLES = (:key, :text, :doi)
const SHEET_LAYOUTS = (:system, :single)

# Excel allows 1,048,576 rows per sheet, one of them the header.
const EXCEL_MAX_ROWS = 1_048_575

const XLSX_MESSAGE = "writing .xlsx files needs the XLSX package: run `import Pkg; Pkg.add(\"XLSX\")` once and `using XLSX` before exporting"

"The two-part pair a sheet is made of: its name and (columns, column names)."
const SheetSpec = Pair{String,Tuple{Vector{Any},Vector{String}}}

"Method added by the XLSX package extension; absent until `using XLSX`."
function write_xlsx end

xlsx_available() = hasmethod(write_xlsx, Tuple{String,Vector{SheetSpec}})

# ----------------------------------------------------------------------------------
# Where the data come from
# ----------------------------------------------------------------------------------

"""
    DataOrigin

The note that travels with exported data from the ThermoML Archive: where the data come
from, which archive version they were read from, the citation of the dataset and the
conditions of use (see `notice.jl`, the one place that holds the wording). It is the first
line of a `.csv` (after `#`), the `origin` sheet of a `.xlsx`, the `origin` group of a
`.jld2`, a comment in a `.md` and a `.tex`, and the first entry of a `.json`.
"""
struct DataOrigin
    entries::Vector{Pair{String,String}}
end

origin_line(o::DataOrigin) = join((string(k, ": ", v) for (k, v) in o.entries), "; ")

function package_version_text()
    version = pkgversion(ThermophysicalDB)
    return version === nothing ? "unknown" : string(version)
end

function archive_manifest()
    try
        return read_manifest(thermoml_dir())
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
end

"""
    origin_note(view) -> Union{Nothing,DataOrigin}

The origin note of `view`, or `nothing` when no point comes from the ThermoML Archive.
"""
function origin_note(view::DataView)::Union{Nothing,DataOrigin}
    from_archive(view) || return nothing
    entries = Pair{String,String}[ORIGIN_HEAD...]
    manifest = archive_manifest()
    if manifest !== nothing
        push!(entries, "archive version" => manifest.version)
        push!(entries, "archive retrieved" => manifest.retrieved_at)
    end
    append!(entries, NOTICE_TAIL)
    push!(entries, "exported by" => string("ThermophysicalDB.jl ", package_version_text()))
    push!(entries, "exported at" => utc_timestamp())
    return DataOrigin(entries)
end

# ----------------------------------------------------------------------------------
# The common representation
# ----------------------------------------------------------------------------------

"""
    ExportData

The points of a selection as the writers see them: `columns` holds every column by its
internal name, `written` the ones that are not empty (and so appear in the files), with
their `headers` (`temperature [K]`) in the same order. `units` maps column names to units,
`system` and `ncomp` describe each point, and `summary` is the references table.
"""
struct ExportData
    columns::NamedTuple
    written::Vector{Symbol}
    headers::Vector{String}
    units::Vector{Pair{String,String}}
    system::Vector{String}
    ncomp::Vector{UInt8}
    summary::ReferenceSummary
    origin::Union{Nothing,DataOrigin}
    reference::Symbol
    unit_system::Symbol
    terms::Dict{Int,Vector{Any}}
end

# The uncertainty terms of the points of `view` (position in the view => records), in the
# units of the table: the terms of the point after those of its experiment. Empty, and
# free, for a database built from the ThermoML archive.
function point_uncertainties(ds::Dataset, view::DataView, units::Symbol)
    out = Dict{Int,Vector{Any}}()
    u = ds.uncertainties
    length(u) == 0 && return out
    m, pr = ds.measurements, ds.properties
    position = Dict{Int32,Int}(r => i for (i, r) in enumerate(view.rows))
    of_experiment = Dict{Int32,Vector{Int}}()
    if any(==(0x01), u.scope)
        for (i, r) in enumerate(view.rows)
            push!(get!(Vector{Int}, of_experiment, m.experiment[r]), i)
        end
    end
    record(i, r) = begin
        q = u.quantity[i]
        factor = 1.0
        if units === :si
            if q == 0x03
                factor = 1.0e3
            elseif q == 0x01
                spec = unit_spec(pr.unit[m.property[r]])
                spec === nothing || (factor = spec.to_si)
            end
        end
        o = JObject(
            "quantity" => UNCERTAINTY_QUANTITY_NAMES[q],
            "kind" => UNCERTAINTY_KIND_NAMES[u.kind[i]],
            "origin" => UNCERTAINTY_ORIGIN_NAMES[u.origin[i]],
            "value" => u.value[i] * factor,
            "k" => u.k[i],
        )
        isnan(u.level[i]) || add!(o, "level", u.level[i])
        text = pool_string(ds.unc_methods, u.method[i])
        isempty(text) || add!(o, "method", text)
        o
    end
    for scope in (0x01, 0x02), i in eachindex(u.row)
        u.scope[i] == scope || continue
        if scope == 0x01
            for p in get(of_experiment, u.row[i], Int[])
                o = record(i, view.rows[p])
                add!(o, "shared", true)
                push!(get!(Vector{Any}, out, p), o)
            end
        else
            p = get(position, u.row[i], 0)
            p == 0 || push!(get!(Vector{Any}, out, p), record(i, u.row[i]))
        end
    end
    return out
end

# Unit written in the header of a composition column: the unit of the kind when it has one
# (`Molality, mol/kg`), `-` for fractions, `see xkind` when the selection mixes kinds.
function composition_unit(ds::Dataset, ids)
    texts = unique(pool_string(ds.kinds, id) for id in ids)
    filter!(!isempty, texts)
    isempty(texts) && return "-"
    length(texts) > 1 && return "see xkind"
    _, spec = split_property_name(texts[1])
    return spec === nothing ? "-" : spec.native
end

function composition_units(view::DataView)
    ds = view.dataset
    m, ex = ds.measurements, ds.experiments
    seen = [Set{Int32}() for _ = 1:MAX_COMPONENTS]
    for r in view.rows
        e = m.experiment[r]
        for j = 1:Int(ex.ncomp[e])
            push!(seen[j], ex.kinds[j][e])
        end
    end
    return String[composition_unit(ds, seen[j]) for j = 1:MAX_COMPONENTS]
end

empty_column(column::AbstractVector{<:AbstractFloat}) = all(isnan, column)
empty_column(column::AbstractVector{<:AbstractString}) = all(isempty, column)

# Columns that are always written, even when empty.
const REQUIRED_COLUMNS = (:reference, :components, :property, :value, :unit)

function build_export_data(
    view::DataView;
    reference::Symbol = :key,
    units::Symbol = :native,
    policy::Symbol = :nominal,
    details::Bool = false,
    composition::Union{Nothing,Symbol} = nothing,
    solvent = nothing,
    molar_mass = nothing,
    compounds = nothing,
    density = nothing,
    fetch_molar_mass::Bool = false,
    strict::Bool = false,
    kwargs...,
)
    reference in REFERENCE_STYLES || throw(
        ArgumentError("reference must be one of $(REFERENCE_STYLES), got :$reference"),
    )
    isempty(view.rows) && throw(ArgumentError("the selection has no points to export"))
    ds = view.dataset
    m, ex, rf = ds.measurements, ds.experiments, ds.references

    summary = reference_summary(view; policy, kwargs...)
    bib = getfield(summary, :bibliography)
    t = table(
        view;
        units,
        policy,
        composition,
        solvent,
        molar_mass,
        compounds,
        density,
        fetch_molar_mass,
        strict,
    )

    label = fill("", length(rf))
    for (k, id) in enumerate(bib.ids)
        entry = bib.entries[k]
        label[id] =
            reference === :key ? entry.key :
            reference === :text ? citation_text(entry) :
            (isempty(rf.doi[id]) ? entry.key : rf.doi[id])
    end
    n = length(view.rows)
    reference_column = Vector{String}(undef, n)
    ncomp = Vector{UInt8}(undef, n)
    for (i, r) in enumerate(view.rows)
        e = m.experiment[r]
        ref = ex.reference[e]
        reference_column[i] = ref == NO_ID ? "" : label[ref]
        ncomp[i] = ex.ncomp[e]
    end

    value_units = unique(t.unit)
    mixed = length(value_units) > 1
    value_unit =
        mixed ? "see unit" :
        (isempty(value_units) || isempty(value_units[1]) ? "-" : value_units[1])
    pressure_unit = units === :si ? "Pa" : "kPa"
    x_units =
        composition === nothing ? composition_units(view) :
        fill(SCALE_UNITS[composition], MAX_COMPONENTS)

    # What the references table already tells (method, phase), and what is the same for the
    # whole selection (the system when there is one, the property when there is one), is not
    # repeated in every row: a blank column is left out of every format. `details` keeps it.
    blank = fill("", n)
    omitted = Symbol[]
    if !details
        allequal(t.components) && push!(omitted, :components)
        allequal(t.property) && push!(omitted, :property)
    end
    # (internal name, header text, unit or nothing, column)
    candidates = Tuple{Symbol,String,Union{Nothing,String},Any}[
        (:reference, "reference", nothing, reference_column),
        (:components, "components", nothing, :components in omitted ? blank : t.components),
        (:xkind, "xkind", nothing, t.xkind),
        (:property, "property", nothing, :property in omitted ? blank : t.property),
        (:method, "method", nothing, details ? t.method : blank),
        (:phase, "phase", nothing, details ? t.phase : blank),
        (:temperature, "temperature", "K", t.temperature),
        (:pressure, "pressure", pressure_unit, t.pressure),
        (:x1, "x1", x_units[1], t.x1),
        (:x2, "x2", x_units[2], t.x2),
        (:x3, "x3", x_units[3], t.x3),
        (:value, "value", value_unit, t.value),
        (:unit, "unit", nothing, t.unit),
        (:unc, "unc", value_unit, t.unc),
        (:unc_k, "unc_k", "-", t.unc_k),
        (:unc_level, "unc_level", "-", t.unc_level),
        (:unc_k2, "unc_k2", value_unit, t.unc_k2),
    ]
    names = Tuple(first.(candidates))
    columns = NamedTuple{names}(Tuple([last(c) for c in candidates]))

    written = Symbol[]
    headers = String[]
    unit_pairs = Pair{String,String}[]
    for (name, text, unit, column) in candidates
        name === :unit && !mixed && continue
        name in omitted && continue
        name in REQUIRED_COLUMNS || !empty_column(column) || continue
        push!(written, name)
        push!(headers, unit === nothing ? text : string(text, " [", unit, "]"))
        unit === nothing || push!(unit_pairs, text => unit)
    end
    return ExportData(
        columns,
        written,
        headers,
        unit_pairs,
        t.components,
        ncomp,
        summary,
        origin_note(view),
        reference,
        units,
        point_uncertainties(ds, view, units),
    )
end

# ----------------------------------------------------------------------------------
# CSV
# ----------------------------------------------------------------------------------

function write_csv_cell(io::IO, x::AbstractString)
    if any(c -> c in (',', '"', '\n', '\r'), x)
        write(io, '"', replace(x, "\"" => "\"\""), '"')
    else
        write(io, x)
    end
    return nothing
end

function write_csv_cell(io::IO, x::AbstractFloat)
    isfinite(x) && print(io, x)
    return nothing
end

write_csv_cell(io::IO, x::Integer) = (print(io, x); nothing)

# Unrolled over the tuple of columns, so every cell is written by a statically
# dispatched method and the loop allocates nothing.
@inline csv_row(::IO, ::Tuple{}, ::Int, ::Bool) = nothing
@inline function csv_row(io::IO, columns::Tuple, i::Int, first::Bool)
    first || write(io, ',')
    write_csv_cell(io, columns[1][i])
    return csv_row(io, Base.tail(columns), i, false)
end

function write_csv_body(io::IO, columns::Tuple, n::Int)
    for i = 1:n
        csv_row(io, columns, i, true)
        write(io, '\n')
    end
    return nothing
end

written_columns(data::ExportData) =
    Tuple([getfield(data.columns, name) for name in data.written])

function write_points_csv(path::AbstractString, data::ExportData)
    columns = written_columns(data)
    open(path, "w") do io
        data.origin === nothing || write(io, "# ", origin_line(data.origin), '\n')
        write(io, join(csv_field.(data.headers), ','), '\n')
        write_csv_body(io, columns, length(data.system))
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# LaTeX
# ----------------------------------------------------------------------------------

# The points as a `longtable` with `booktabs` rules, the same columns and headers as the
# CSV. With `reference = :key` the reference cells are `\cite{key}`, so the table and the
# `.bib` written with it are ready to be included in a text.
function write_points_tex(path::AbstractString, data::ExportData)
    columns = written_columns(data)
    align = join((c isa AbstractVector{<:AbstractString} ? 'l' : 'r' for c in columns))
    head = join((latex_escape(h) for h in data.headers), " & ") * " \\\\"
    open(path, "w") do io
        data.origin === nothing || write(io, "% ", origin_line(data.origin), '\n')
        write(io, "% Requires: \\usepackage{booktabs} and \\usepackage{longtable}\n")
        write(io, "\\begin{longtable}{", align, "}\n")
        write(io, "\\toprule\n", head, "\n\\midrule\n\\endfirsthead\n")
        write(io, "\\toprule\n", head, "\n\\midrule\n\\endhead\n")
        write(io, "\\bottomrule\n\\endlastfoot\n")
        for i in eachindex(data.system)
            for (j, column) in enumerate(columns)
                j > 1 && write(io, " & ")
                x = column[i]
                if x isa AbstractString
                    cite = data.reference === :key && data.written[j] === :reference
                    text = latex_escape(x)
                    write(io, cite && !isempty(x) ? string("\\cite{", x, "}") : text)
                elseif isfinite(x)
                    print(io, x)
                end
            end
            write(io, " \\\\\n")
        end
        write(io, "\\end{longtable}\n")
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Markdown
# ----------------------------------------------------------------------------------

md_cell(io::IO, x::AbstractString) = write(io, replace(x, "|" => "\\|"))
md_cell(io::IO, x::Real) = isfinite(x) && print(io, x)

# Same recursion over the tuple of columns as `csv_row`: one dispatched method per column.
@inline md_row(::IO, ::Tuple{}, ::Int) = nothing
@inline function md_row(io::IO, columns::Tuple, i::Int)
    write(io, ' ')
    md_cell(io, columns[1][i])
    write(io, " |")
    return md_row(io, Base.tail(columns), i)
end

# The points as a Markdown (pipe) table: text columns on the left, numbers on the right.
# The notice is an HTML comment, which renderers do not show.
function write_points_md(path::AbstractString, data::ExportData)
    columns = written_columns(data)
    align = join(
        (c isa AbstractVector{<:AbstractString} ? " :--- " : " ---: " for c in columns),
        "|",
    )
    open(path, "w") do io
        if data.origin !== nothing
            write(io, "<!--\n")
            for (k, v) in data.origin.entries
                write(io, k, ": ", v, '\n')
            end
            write(io, "-->\n\n")
        end
        write(
            io,
            "| ",
            join((replace(h, "|" => "\\|") for h in data.headers), " | "),
            " |\n",
        )
        write(io, "|", align, "|\n")
        for i in eachindex(data.system)
            write(io, '|')
            md_row(io, columns, i)
            write(io, '\n')
        end
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# JSON writer
# ----------------------------------------------------------------------------------

# A small ordered JSON writer. Objects keep the order in which they were built (the
# origin note must come first), numbers that are not finite are written as `null`, and
# everything from `inline_from` levels down is written on one line, so a point or a row
# of values takes one line of the file.

struct JObject
    pairs::Vector{Pair{String,Any}}
end

JObject(pairs::Pair...) = JObject(Pair{String,Any}[p for p in pairs])

add!(o::JObject, name::AbstractString, value) = (push!(o.pairs, String(name) => value); o)

function json_string(io::IO, s::AbstractString)
    write(io, '"')
    for c in String(s)
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif UInt32(c) < 0x20
            write(io, "\\u", string(UInt16(c); base = 16, pad = 4))
        else
            write(io, c)
        end
    end
    write(io, '"')
    return nothing
end

indent(io::IO, depth::Int) = write(io, " "^(2 * depth))

write_json(io::IO, ::Nothing, ::Int, ::Int) = (write(io, "null"); nothing)
write_json(io::IO, x::Bool, ::Int, ::Int) = (write(io, x ? "true" : "false"); nothing)
write_json(io::IO, x::Integer, ::Int, ::Int) = (print(io, x); nothing)
write_json(io::IO, x::AbstractString, ::Int, ::Int) = json_string(io, x)
function write_json(io::IO, x::AbstractFloat, ::Int, ::Int)
    isfinite(x) ? print(io, x) : write(io, "null")
    return nothing
end

function write_json(io::IO, o::JObject, depth::Int, inline_from::Int)
    isempty(o.pairs) && (write(io, "{}"); return nothing)
    inline = depth >= inline_from
    write(io, '{')
    for (k, (name, value)) in enumerate(o.pairs)
        k > 1 && write(io, inline ? ", " : ",")
        if !inline
            write(io, '\n')
            indent(io, depth + 1)
        end
        json_string(io, name)
        write(io, ": ")
        write_json(io, value, depth + 1, inline_from)
    end
    if !inline
        write(io, '\n')
        indent(io, depth)
    end
    write(io, '}')
    return nothing
end

function write_json(io::IO, x::AbstractVector, depth::Int, inline_from::Int)
    isempty(x) && (write(io, "[]"); return nothing)
    inline = depth >= inline_from
    write(io, '[')
    for (k, value) in enumerate(x)
        k > 1 && write(io, inline ? ", " : ",")
        if !inline
            write(io, '\n')
            indent(io, depth + 1)
        end
        write_json(io, value, depth + 1, inline_from)
    end
    if !inline
        write(io, '\n')
        indent(io, depth)
    end
    write(io, ']')
    return nothing
end

function origin_object(o::DataOrigin)
    return JObject(Pair{String,Any}[replace(k, ' ' => '_') => v for (k, v) in o.entries])
end

# ----------------------------------------------------------------------------------
# JSON: one record per point
# ----------------------------------------------------------------------------------

# Each member writer returns whether the next member is still the first of the record.
function json_member(io::IO, first::Bool, name::String, value::AbstractString)
    isempty(value) && return first
    first || write(io, ", ")
    json_string(io, name)
    write(io, ": ")
    json_string(io, value)
    return false
end

function json_member(io::IO, first::Bool, name::String, value::Float64)
    isfinite(value) || return first
    first || write(io, ", ")
    json_string(io, name)
    write(io, ": ")
    print(io, value)
    return false
end

function write_json_point(io::IO, c::NamedTuple, ncomp::UInt8, i::Int, terms = nothing)
    write(io, '{')
    first = true
    first = json_member(io, first, "reference", c.reference[i])
    first = json_member(io, first, "components", c.components[i])
    first = json_member(io, first, "xkind", c.xkind[i])
    first = json_member(io, first, "property", c.property[i])
    first = json_member(io, first, "method", c.method[i])
    first = json_member(io, first, "phase", c.phase[i])
    first = json_member(io, first, "temperature", c.temperature[i])
    first = json_member(io, first, "pressure", c.pressure[i])
    n = Int(ncomp)
    xs = (c.x1, c.x2, c.x3)
    if n > 0 && any(j -> isfinite(xs[j][i]), 1:n)
        first || write(io, ", ")
        write(io, "\"x\": [")
        for j = 1:n
            j > 1 && write(io, ", ")
            write_json(io, xs[j][i], 0, 0)
        end
        write(io, ']')
        first = false
    end
    first = json_member(io, first, "value", c.value[i])
    first = json_member(io, first, "unit", c.unit[i])
    first = json_member(io, first, "unc", c.unc[i])
    first = json_member(io, first, "unc_k", c.unc_k[i])
    first = json_member(io, first, "unc_level", c.unc_level[i])
    first = json_member(io, first, "unc_k2", c.unc_k2[i])
    if terms !== nothing
        first || write(io, ", ")
        write(io, "\"uncertainties\": ")
        write_json(io, terms, 0, 0)
    end
    write(io, '}')
    return nothing
end

# Function barrier: `c` has a concrete type here, so every access below is type stable.
function write_json_points(
    io::IO,
    c::NamedTuple,
    ncomp::Vector{UInt8},
    terms::Dict{Int,Vector{Any}},
)
    for i in eachindex(ncomp)
        write(io, i == 1 ? "\n    " : ",\n    ")
        write_json_point(io, c, ncomp[i], i, get(terms, i, nothing))
    end
    return nothing
end

# Blank cells of the references table are left out of its JSON records.
json_blank(x::AbstractString) = isempty(x)
json_blank(x::AbstractFloat) = !isfinite(x)
json_blank(x::Integer) = false

function references_object(s::ReferenceSummary)
    c = getfield(s, :columns)
    rows = Any[]
    for i = 1:length(s)
        row = JObject()
        for name in keys(c)
            name === :method && continue            # the abbreviated form; method_full is written
            value = c[name][i]
            (name in (:year, :month) && value == 0) && continue
            json_blank(value) && continue
            add!(row, name === :method_full ? "method" : String(name), value)
        end
        push!(rows, row)
    end
    return JObject(
        "temperature_unit" => getfield(s, :temperature_unit),
        "pressure_unit" => getfield(s, :pressure_unit),
        "rows" => rows,
    )
end

function metadata_object(data::ExportData, format::AbstractString)
    return JObject(
        "format" => format,
        "version" => 1,
        "exported_at" => utc_timestamp(),
        "package_version" => package_version_text(),
        "reference_style" => String(data.reference),
        "unit_system" => String(data.unit_system),
        "points" => length(data.system),
    )
end

function write_points_json(path::AbstractString, data::ExportData)
    open(path, "w") do io
        write(io, "{\n")
        origin = data.origin
        if origin !== nothing
            write(io, "  \"origin\": ")
            write_json(io, origin_object(origin), 1, 2)
            write(io, ",\n")
        end
        write(io, "  \"metadata\": ")
        write_json(io, metadata_object(data, "ThermophysicalDB points"), 1, 2)
        write(io, ",\n  \"units\": ")
        units = JObject(Pair{String,Any}[k => v for (k, v) in data.units])
        write_json(io, units, 1, 2)
        write(io, ",\n  \"points\": [")
        write_json_points(io, data.columns, data.ncomp, data.terms)
        write(io, "\n  ],\n  \"references\": ")
        write_json(io, references_object(data.summary), 1, 3)
        write(io, "\n}\n")
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# JLD2
# ----------------------------------------------------------------------------------

function write_points_jld2(path::AbstractString, data::ExportData)
    JLD2.jldopen(path, "w") do file
        for name in data.written
            file[string("points/", name)] = getfield(data.columns, name)
        end
        file["points/ncomp"] = data.ncomp
        for (name, unit) in data.units
            file[string("units/", name)] = unit
        end
        file["metadata/columns"] = String.(data.written)
        file["metadata/headers"] = data.headers
        file["metadata/exported_at"] = utc_timestamp()
        file["metadata/package_version"] = package_version_text()
        file["metadata/reference_style"] = String(data.reference)
        file["metadata/unit_system"] = String(data.unit_system)
        c = getfield(data.summary, :columns)
        for name in keys(c)
            file[string("references/", name)] = c[name]
        end
        file["references/temperature_unit"] = getfield(data.summary, :temperature_unit)
        file["references/pressure_unit"] = getfield(data.summary, :pressure_unit)
        if data.origin !== nothing
            for (k, v) in data.origin.entries
                file[string("origin/", replace(k, ' ' => '_'))] = v
            end
        end
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# XLSX: the sheets are built here, the file is written by the extension
# ----------------------------------------------------------------------------------

excel_column(v::AbstractVector{<:AbstractFloat}) =
    Union{Missing,Float64}[isfinite(x) ? Float64(x) : missing for x in v]
excel_column(v::AbstractVector{<:AbstractString}) =
    Union{Missing,String}[isempty(x) ? missing : String(x) for x in v]
excel_column(v::AbstractVector{<:Integer}) = Int[x for x in v]

const SHEET_FORBIDDEN = r"[\[\]:*?/\\]"

# A legal, unique sheet name of at most 31 characters. Excel compares names without case.
function sheet_name(label::AbstractString, used::Set{String})
    base = String(strip(replace(label, SHEET_FORBIDDEN => "-"), '\''))
    isempty(base) && (base = "points")
    name = first(base, 31)
    k = 1
    while lowercase(name) in used
        k += 1
        suffix = string(" ", k)
        name = string(first(base, 31 - length(suffix)), suffix)
    end
    push!(used, lowercase(name))
    return name
end

function sheet_columns(data::ExportData, rows::AbstractVector{Int})
    names = String[]
    columns = Any[]
    for (name, header) in zip(data.written, data.headers)
        column = getfield(data.columns, name)[rows]
        name in REQUIRED_COLUMNS || !empty_column(column) || continue
        push!(names, header)
        push!(columns, excel_column(column))
    end
    return columns, names
end

function xlsx_sheets(data::ExportData; sheets::Symbol = :system)
    sheets in SHEET_LAYOUTS ||
        throw(ArgumentError("sheets must be one of $(SHEET_LAYOUTS), got :$sheets"))
    groups = Dict{String,Vector{Int}}()
    order = String[]
    for i in eachindex(data.system)
        key = sheets === :system ? data.system[i] : "points"
        bucket = get!(groups, key) do
            push!(order, key)
            Int[]
        end
        push!(bucket, i)
    end
    used = Set{String}(["references", "origin"])
    result = SheetSpec[]
    for key in order
        rows = groups[key]
        length(rows) > EXCEL_MAX_ROWS && throw(
            ArgumentError(
                "$(length(rows)) points do not fit in one Excel sheet (limit $EXCEL_MAX_ROWS); " *
                "use sheets = :system, or export to .csv or .jld2",
            ),
        )
        columns, names = sheet_columns(data, rows)
        push!(result, sheet_name(key, used) => (columns, names))
    end
    fields = summary_fields(data.summary)
    push!(
        result,
        "references" =>
            (Any[excel_column(last(f)) for f in fields], String[first(f) for f in fields]),
    )
    if data.origin !== nothing
        entries = data.origin.entries
        push!(
            result,
            "origin" => (
                Any[String[first(e) for e in entries], String[last(e) for e in entries]],
                ["field", "value"],
            ),
        )
    end
    return result
end

# ----------------------------------------------------------------------------------
# The report
# ----------------------------------------------------------------------------------

"""
    ExportReport

What [`export_points`](@ref) did: the `files` it wrote, the number of `points` and
`articles`, and the `bibtex` report of the references (`nothing` when only a ThermoML JSON
was written, which needs no references).
"""
struct ExportReport
    files::Vector{String}
    points::Int
    articles::Int
    bibtex::Union{Nothing,BibtexReport}
end

function Base.show(io::IO, ::MIME"text/plain", r::ExportReport)
    println(io, "ExportReport: ", r.points, " points from ", r.articles, " articles")
    for file in r.files
        println(io, "  wrote ", file)
    end
    return nothing
end

Base.show(io::IO, r::ExportReport) =
    print(io, "ExportReport(", length(r.files), " files, ", r.points, " points)")

function article_count(view::DataView)
    ds = view.dataset
    seen = Set{Int32}()
    for r in view.rows
        push!(seen, ds.experiments.reference[ds.measurements.experiment[r]])
    end
    return length(seen)
end

# ----------------------------------------------------------------------------------
# The export
# ----------------------------------------------------------------------------------

# The directory to write. A name with an extension is almost surely a file name, which
# this function no longer writes; a trailing separator says it is a directory anyway.
function export_directory(path::AbstractString)
    text = String(path)
    as_directory = endswith(text, '/') || endswith(text, '\\')
    text = String(rstrip(text, ['/', '\\']))
    isempty(text) && throw(ArgumentError("the destination path is empty"))
    extension = splitext(text)[2]
    if !as_directory && !isempty(extension) && !isdir(text)
        throw(
            ArgumentError(
                "export_points writes a directory of tables, so the path is a directory " *
                "name, not a file name: got \"$text\" with the extension \"$extension\". " *
                "Pass \"$(first(splitext(text)))\" and choose the files with `formats`, or end " *
                "the path with a slash to keep the dot in the name of the directory.",
            ),
        )
    end
    return text
end

file_extension(format::Symbol) =
    format === :thermoml ? ".thermoml.json" :
    format === :thermoml_xml ? ".thermoml" : string('.', format)

# The formats to write: the ones asked for, or the defaults plus Excel when it is available.
function export_formats(formats)
    if formats === nothing
        return xlsx_available() ? (DEFAULT_FORMATS..., :xlsx) : DEFAULT_FORMATS
    end
    chosen = Tuple(unique(Symbol.(formats isa Symbol ? (formats,) : formats)))
    isempty(chosen) && throw(ArgumentError("formats is empty"))
    for f in chosen
        f in POINT_FORMATS ||
            throw(ArgumentError("unknown format :$f; choose from $(POINT_FORMATS)"))
    end
    :xlsx in chosen && !xlsx_available() && throw(ArgumentError(XLSX_MESSAGE))
    return chosen
end

function write_points_xlsx(path::AbstractString, data::ExportData; sheets::Symbol)
    xlsx_available() || throw(ArgumentError(XLSX_MESSAGE))
    write_xlsx(String(path), xlsx_sheets(data; sheets))
    return nothing
end

function export_data(data::Union{Nothing,ExportData})
    data === nothing && throw(ArgumentError("this format needs the data of the export"))
    return data
end

function write_point_file(
    format::Symbol,
    path::AbstractString,
    data::Union{Nothing,ExportData},
    view::DataView;
    sheets::Symbol,
)
    if format === :thermoml
        origin = data === nothing ? origin_note(view) : data.origin
        write_points_thermoml(path, view; origin)
    elseif format === :thermoml_xml
        origin = data === nothing ? origin_note(view) : data.origin
        write_points_thermoml_xml(path, view; origin)
    elseif format === :csv
        write_points_csv(path, export_data(data))
    elseif format === :md
        write_points_md(path, export_data(data))
    elseif format === :json
        write_points_json(path, export_data(data))
    elseif format === :jld2
        write_points_jld2(path, export_data(data))
    elseif format === :tex
        write_points_tex(path, export_data(data))
    elseif format === :xlsx
        write_points_xlsx(path, export_data(data); sheets)
    else
        throw(ArgumentError("unknown format :$format; choose from $(POINT_FORMATS)"))
    end
    return nothing
end

# The references that go with the points: the table of the articles in each of the table
# formats that were chosen (`.csv`, `.md`, `.tex`) and the `.bib` the keys refer to.
function write_reference_files(stem::AbstractString, data::ExportData, formats)
    files = String[]
    summary = data.summary
    keyed = data.reference === :key
    for format in (:csv, :md, :tex)
        format in formats || continue
        file = string(stem, "_references", file_extension(format))
        text =
            format === :csv ? csv_table(summary) :
            format === :md ? markdown_table(summary; reference = keyed ? :key : :text) :
            latex_table(summary; reference = keyed ? :cite : :text)
        write(file, text)
        push!(files, file)
    end
    bib = string(stem, ".bib")
    write(bib, bibtex(summary))
    push!(files, bib)
    return files
end

"""
    export_points(directory, view; formats = nothing, reference = :key, units = :native,
                  policy = :nominal, details = false, sheets = :system, references = true,
                  include_package = true, online = true, cache = true, refresh = false,
                  progress = true) -> ExportReport

Write the points of `view` (a [`DataView`](@ref), or a [`Dataset`](@ref) for all of them)
to the directory `directory`, which is created if it does not exist, with one file per
format: for `export_points("data/water", v)`, `data/water/water.csv`, `water.md` and so on.
`formats` is a tuple of symbols; the default is `(:csv, :md, :tex, :json, :jld2)`, plus
`:xlsx` when the XLSX package is loaded (`using XLSX`).

| Format | File | Content |
|---|---|---|
| `:csv` | `name.csv` | one table; every header carries the unit of its column in brackets |
| `:md` | `name.md` | the same table as a Markdown table |
| `:tex` | `name.tex` | the same table as a LaTeX `longtable` with `booktabs` rules |
| `:json` | `name.json` | one record per point, with the origin as its first entry and the separate uncertainty terms of the points that have them |
| `:jld2` | `name.jld2` | the columns, units and references as Julia data |
| `:xlsx` | `name.xlsx` | one sheet per system (`sheets = :system`, or `:single`), a `references` sheet and an `origin` sheet |
| `:thermoml` | `name.thermoml.json` | the JSON form of ThermoML, one `DataReport` per article (see below) |
| `:thermoml_xml` | `name.thermoml/` | ThermoML XML, one document per article, valid against the schema |

The path is a directory name, not a file name: `"data/water.csv"` is an error, so a
leftover extension never silently creates a directory with a dot in its name. End the path
with a slash to keep a dot in the name (`"data/water.v2/"`).

The tables hold points only. The articles are described in the references table, linked
through the `reference` column: `reference = :key` writes the BibTeX key (the same keys as
[`bibtex`](@ref); in the `.tex` it is `\\cite{key}`), `:text` a written-out citation
(`Chirico et al. (2003)`) and `:doi` the DOI. With `references = true` the references are
written next to the points: `name_references.csv`, `name_references.md` and
`name_references.tex` for each of those formats that was chosen, and `name.bib`. The
`.json`, `.jld2` and `.xlsx` hold the references table inside the file. The `.bib` also
holds the entry of this package (see [`bibtex`](@ref); `include_package = false` leaves it
out).

Columns that are empty for the whole selection are left out. So are the ones that repeat
what the references table says or what is the same in every row: the `method` and the
`phase` of each point, the `components` when the selection has a single system and the
`property` when it has a single property. `details = true` writes them all.

Data from the ThermoML Archive carry a notice in every format (the first line of a `.csv`,
a comment in a `.md` and a `.tex`, the `origin` entry of a `.json`, an `origin` sheet in a
`.xlsx`, the `origin` group of a `.jld2`, and an `@comment` in the `.bib`): where the data
come from, the citation of the dataset, that they are modified and not endorsed by NIST/TRC,
and that the articles must be credited. With `references = false` and `reference = :key` a
table keeps no way back to the DOIs, and a warning says so.

`units = :si` converts values, uncertainties and pressure to SI (see [`table`](@ref)); the
ThermoML formats always keep the units of the archive and the composition as the source gave it.
`composition` converts the amounts `x1..x3` of the tables to another scale of
[`COMPOSITION_SCALES`](@ref), with `solvent`, `molar_mass`, `compounds`, `density`,
`fetch_molar_mass` and `strict` of [`convert_composition`](@ref); the header of the column then
tells the unit of the new scale. The uncertainty columns are `unc`
(as reported) and `unc_k2` (at ``k = 2``, see `policy` in [`table`](@ref)). `online`,
`cache`, `refresh` and `progress` act as in [`bibtex`](@ref).

The ThermoML formats hold, for every article of the selection, its `Citation`, the
`Compound`s with their samples and the `PureOrMixtureData` with the selected points only,
in the element order of the standard (the XML validates against `ThermoML.xsd`). What the
standard requires and the archive lacks is derived: the significant digits of a value are
counted when not stored, and a property without a method is written as "method not
stated". The constraints (temperature, pressure, composition, frequency, ...), the phases and the solvent are
written as the source stated them, and what a constraint fixes is not repeated as a variable of
every point. An incomplete `TRCRefID` is left out. `ReactionData` is not supported. A directory with only
ThermoML formats needs neither references nor network.

# Examples
```julia
v = points(db; component = "water", exact = true, property = "Mass density")
export_points("data/water", v)                                # csv, md, tex, json, jld2
export_points("data/water", v; formats = (:csv, :thermoml, :thermoml_xml))
```
"""
function export_points(
    path::AbstractString,
    view::DataView;
    formats = nothing,
    sheets::Symbol = :system,
    references::Bool = true,
    reference::Symbol = :key,
    units::Symbol = :native,
    policy::Symbol = :nominal,
    composition::Union{Nothing,Symbol} = nothing,
    solvent = nothing,
    molar_mass = nothing,
    compounds = nothing,
    density = nothing,
    fetch_molar_mass::Bool = false,
    strict::Bool = false,
    kwargs...,
)
    sheets in SHEET_LAYOUTS ||
        throw(ArgumentError("sheets must be one of $(SHEET_LAYOUTS), got :$sheets"))
    isempty(view.rows) && throw(ArgumentError("the selection has no points to export"))
    directory = export_directory(path)
    chosen = export_formats(formats)

    # A table holds the BibTeX key only; without the `.bib` written next to it the DOI of
    # the article, which credits its authors, cannot be recovered from the files.
    if !references && reference === :key && any(f -> f in (:csv, :md, :tex), chosen)
        @warn(
            "references = false with reference = :key: the files hold BibTeX keys but no " *
            "`.bib` is written, so the DOI of each article cannot be recovered from them. " *
            "Use `reference = :doi` or keep `references = true`."
        )
    end
    # A ThermoML-only export reads nothing but the dataset: no references, no network.
    data =
        all(in((:thermoml, :thermoml_xml)), chosen) ? nothing :
        build_export_data(
            view;
            reference,
            units,
            policy,
            composition,
            solvent,
            molar_mass,
            compounds,
            density,
            fetch_molar_mass,
            strict,
            kwargs...,
        )

    mkpath(directory)
    name = basename(directory)
    files = String[]
    for format in chosen
        file = joinpath(directory, name * file_extension(format))
        write_point_file(format, file, data, view; sheets)
        push!(files, file)
    end
    if references && data !== nothing
        append!(files, write_reference_files(joinpath(directory, name), data, chosen))
    end
    return ExportReport(
        files,
        length(view.rows),
        article_count(view),
        data === nothing ? nothing : getfield(data.summary, :bibliography).report,
    )
end

export_points(path::AbstractString, ds::Dataset; kwargs...) =
    export_points(path, DataView(ds); kwargs...)
