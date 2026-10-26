# Export of the points of a selection: one dispatcher (`export_points`) that picks the
# writer from the extension of the path, and one internal writer per format. Every writer
# starts from the same `ExportData`, so the files of one export agree with each other: same
# columns, same units, same reference keys.
#
#   .csv      one table with the unit of every column in its header
#   .xlsx     one sheet per system, plus `references` and `origin` (needs the XLSX package)
#   .json     one record per point, or (json_layout = :thermoml) a subset of the ThermoML schema
#   .jld2     columns, units and references as Julia data
#   (no extension) a directory holding all of the above
#
# Tables hold only points. What describes an article lives in the references table, which
# is linked to the points by the `reference` column (BibTeX key, written-out citation or DOI).

const POINT_FORMATS = (:csv, :xlsx, :json, :jld2, :tex, :thermoml)
const DIRECTORY_FORMATS = (:csv, :xlsx, :json, :jld2, :tex)
const REFERENCE_STYLES = (:key, :text, :doi)
const SHEET_LAYOUTS = (:system, :single)
const JSON_LAYOUTS = (:records, :thermoml)

const FORMAT_EXTENSIONS = Dict(
    ".csv" => :csv,
    ".xlsx" => :xlsx,
    ".json" => :json,
    ".jld2" => :jld2,
    ".tex" => :tex,
)

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
from, which archive version they were read from, and that they were modified. It is the
first line of a `.csv` (after `#`), the `origin` sheet of a `.xlsx`, and the first entry
of a `.json`.
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
    ds = view.dataset
    source = get(ds.sources.index, "thermoml", NO_ID)
    source == NO_ID && return nothing
    m, ex, rf = ds.measurements, ds.experiments, ds.references
    found = false
    for r in view.rows
        ref = ex.reference[m.experiment[r]]
        if ref != NO_ID && rf.source[ref] == source
            found = true
            break
        end
    end
    found || return nothing
    entries = Pair{String,String}[
        "data origin"=>"NIST/TRC ThermoML Archive",
        "archive url"=>"https://trc.nist.gov/ThermoML/",
        "dataset doi"=>"10.18434/mds2-2422",
    ]
    manifest = archive_manifest()
    if manifest !== nothing
        push!(entries, "archive version" => manifest.version)
        push!(entries, "archive retrieved" => manifest.retrieved_at)
    end
    push!(
        entries,
        "notice" => "modified data (reformatted by ThermophysicalDB.jl, possibly converted to other units, not evaluated by NIST/TRC). Cite the articles of the points and the archive",
    )
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
    t = table(view; units, policy)

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
    x_units = composition_units(view)

    # (internal name, header text, unit or nothing, column)
    candidates = Tuple{Symbol,String,Union{Nothing,String},Any}[
        (:reference, "reference", nothing, reference_column),
        (:components, "components", nothing, t.components),
        (:xkind, "xkind", nothing, t.xkind),
        (:property, "property", nothing, t.property),
        (:method, "method", nothing, t.method),
        (:phase, "phase", nothing, t.phase),
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
    for c in s
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
        elseif c < ' '
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

function write_json_point(io::IO, c::NamedTuple, ncomp::UInt8, i::Int)
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
    json_member(io, first, "unc_k2", c.unc_k2[i])
    write(io, '}')
    return nothing
end

# Function barrier: `c` has a concrete type here, so every access below is type stable.
function write_json_points(io::IO, c::NamedTuple, ncomp::Vector{UInt8})
    for i in eachindex(ncomp)
        write(io, i == 1 ? "\n    " : ",\n    ")
        write_json_point(io, c, ncomp[i], i)
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
        if data.origin !== nothing
            write(io, "  \"origin\": ")
            write_json(io, origin_object(data.origin), 1, 2)
            write(io, ",\n")
        end
        write(io, "  \"metadata\": ")
        write_json(io, metadata_object(data, "ThermophysicalDB points"), 1, 2)
        write(io, ",\n  \"units\": ")
        units = JObject(Pair{String,Any}[k => v for (k, v) in data.units])
        write_json(io, units, 1, 2)
        write(io, ",\n  \"points\": [")
        write_json_points(io, data.columns, data.ncomp)
        write(io, "\n  ],\n  \"references\": ")
        write_json(io, references_object(data.summary), 1, 3)
        write(io, "\n}\n")
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# JSON: a subset of the ThermoML schema
# ----------------------------------------------------------------------------------

function thermoml_property(ds::Dataset, key, number::Int)
    property, method, phase, level = key
    pr = ds.properties
    group = pool_string(ds.groups, pr.group[property])
    isempty(group) && (group = "Property")
    unit = pr.unit[property]
    name = isempty(unit) ? pr.label[property] : string(pr.label[property], ", ", unit)
    named = JObject("ePropName" => name)
    method_name = pool_string(ds.methods, method)
    isempty(method_name) || add!(named, "eMethodName", method_name)
    p = JObject("nPropNumber" => number)
    add!(p, "Property-MethodID", JObject("PropertyGroup" => JObject(group => named)))
    phase_name = pool_string(ds.phases, phase)
    isempty(phase_name) || add!(p, "PropPhaseID", JObject("ePropPhase" => phase_name))
    add!(p, "ePresentation", "Direct value, X")
    isnan(level) || add!(
        p,
        "CombinedUncertainty",
        JObject("nCombUncertLevOfConfid" => round(100 * level; digits = 10)),
    )
    return p
end

function thermoml_citation(rf::ReferenceTable, ref::Int32)
    citation = JObject()
    ref == NO_ID && return citation
    isempty(rf.title[ref]) || add!(citation, "sTitle", rf.title[ref])
    isempty(rf.journal[ref]) || add!(citation, "sPubName", rf.journal[ref])
    rf.year[ref] > 0 && add!(citation, "yrPubYr", Int(rf.year[ref]))
    isempty(rf.volume[ref]) || add!(citation, "sVol", rf.volume[ref])
    isempty(rf.pages[ref]) || add!(citation, "sPage", rf.pages[ref])
    isempty(rf.authors[ref]) || add!(citation, "sAuthor", Any[a for a in rf.authors[ref]])
    isempty(rf.doi[ref]) || add!(citation, "sDOI", rf.doi[ref])
    return citation
end

# One ThermoML article (Citation, Compound, PureOrMixtureData) holding the points `rows`,
# which all belong to the reference `ref`. Compounds are numbered per article, as in the
# archive, and each point becomes one row of NumValues.
function thermoml_article(ds::Dataset, ref::Int32, rows::Vector{Int32})
    m, ex, ct = ds.measurements, ds.experiments, ds.compounds

    by_experiment = Dict{Int32,Vector{Int32}}()
    order = Int32[]
    for r in rows
        e = m.experiment[r]
        bucket = get!(by_experiment, e) do
            push!(order, e)
            Int32[]
        end
        push!(bucket, r)
    end

    local_number = Dict{Int32,Int}()
    compound_order = Int32[]
    for e in order, i = 1:Int(ex.ncomp[e])
        c = ex.components[i][e]
        if !haskey(local_number, c)
            push!(compound_order, c)
            local_number[c] = length(compound_order)
        end
    end
    compounds = Any[]
    for c in compound_order
        o = JObject("RegNum" => JObject("nOrgNum" => local_number[c]))
        isempty(ct.inchikey[c]) || add!(o, "sStandardInChIKey", ct.inchikey[c])
        isempty(ct.inchi[c]) || add!(o, "sStandardInChI", ct.inchi[c])
        isempty(ct.formula[c]) || add!(o, "sFormulaMolec", ct.formula[c])
        isempty(ct.names[c]) || add!(o, "sCommonName", Any[s for s in ct.names[c]])
        push!(compounds, o)
    end

    blocks = Any[]
    for (k, e) in enumerate(order)
        rs = by_experiment[e]
        n = Int(ex.ncomp[e])
        block = JObject("nPureOrMixtureDataNumber" => k)
        add!(
            block,
            "Component",
            Any[
                JObject(
                    "RegNum" => JObject("nOrgNum" => local_number[ex.components[i][e]]),
                ) for i = 1:n
            ],
        )

        # Variables: only the conditions the points actually have.
        kinds = String[pool_string(ds.kinds, ex.kinds[i][e]) for i = 1:n]
        has_T = any(r -> !isnan(m.temperature[r]), rs)
        has_P = any(r -> !isnan(m.pressure[r]), rs)
        has_x = Bool[
            !isempty(kinds[i]) && any(r -> !isnan(m.composition[i][r]), rs) for i = 1:n
        ]
        variables = Any[]
        var_T = var_P = 0
        var_x = zeros(Int, n)
        if has_T
            var_T = length(variables) + 1
            push!(
                variables,
                JObject(
                    "nVarNumber" => var_T,
                    "VariableID" => JObject(
                        "VariableType" => JObject("eTemperature" => "Temperature, K"),
                    ),
                ),
            )
        end
        if has_P
            var_P = length(variables) + 1
            push!(
                variables,
                JObject(
                    "nVarNumber" => var_P,
                    "VariableID" =>
                        JObject("VariableType" => JObject("ePressure" => "Pressure, kPa")),
                ),
            )
        end
        for i = 1:n
            has_x[i] || continue
            var_x[i] = length(variables) + 1
            push!(
                variables,
                JObject(
                    "nVarNumber" => var_x[i],
                    "VariableID" => JObject(
                        "RegNum" =>
                            JObject("nOrgNum" => local_number[ex.components[i][e]]),
                        "VariableType" => JObject("eComponentComposition" => kinds[i]),
                    ),
                ),
            )
        end

        # Properties: one per (property, method, phase, level of confidence).
        property_number = Dict{Tuple{Int32,Int32,Int32,Float64},Int}()
        properties = Any[]
        property_of_row = Vector{Int}(undef, length(rs))
        for (j, r) in enumerate(rs)
            key = (m.property[r], m.method[r], m.phase[r], m.unc_level[r])
            number = get(property_number, key, 0)
            if number == 0
                number = length(property_number) + 1
                property_number[key] = number
                push!(properties, thermoml_property(ds, key, number))
            end
            property_of_row[j] = number
        end
        add!(block, "Property", properties)
        isempty(variables) || add!(block, "Variable", variables)

        numvalues = Any[]
        for (j, r) in enumerate(rs)
            values = Any[]
            has_T &&
                !isnan(m.temperature[r]) &&
                push!(
                    values,
                    JObject("nVarNumber" => var_T, "nVarValue" => m.temperature[r]),
                )
            has_P &&
                !isnan(m.pressure[r]) &&
                push!(values, JObject("nVarNumber" => var_P, "nVarValue" => m.pressure[r]))
            for i = 1:n
                (has_x[i] && !isnan(m.composition[i][r])) || continue
                push!(
                    values,
                    JObject("nVarNumber" => var_x[i], "nVarValue" => m.composition[i][r]),
                )
            end
            pv = JObject("nPropNumber" => property_of_row[j], "nPropValue" => m.value[r])
            isnan(m.unc[r]) || add!(
                pv,
                "CombinedUncertainty",
                JObject("nCombExpandUncertValue" => m.unc[r]),
            )
            row = JObject()
            isempty(values) || add!(row, "VariableValue", values)
            add!(row, "PropertyValue", Any[pv])
            push!(numvalues, row)
        end
        add!(block, "NumValues", numvalues)
        push!(blocks, block)
    end

    article = JObject("Citation" => thermoml_citation(ds.references, ref))
    add!(article, "Compound", compounds)
    add!(article, "PureOrMixtureData", blocks)
    return article
end

function write_points_thermoml(
    path::AbstractString,
    view::DataView;
    origin::Union{Nothing,DataOrigin} = origin_note(view),
)
    ds = view.dataset
    groups = Dict{Int32,Vector{Int32}}()
    for r in view.rows
        ref = ds.experiments.reference[ds.measurements.experiment[r]]
        push!(get!(Vector{Int32}, groups, ref), r)
    end
    open(path, "w") do io
        write(io, "{\n")
        if origin !== nothing
            write(io, "  \"origin\": ")
            write_json(io, origin_object(origin), 1, 2)
            write(io, ",\n")
        end
        write(
            io,
            "  \"format\": \"subset of ThermoML (JSON form of the NIST/TRC archive), one object per article; units are those of the archive\",\n",
        )
        write(io, "  \"articles\": [")
        for (k, ref) in enumerate(sort!(collect(keys(groups))))
            write(io, k == 1 ? "\n    " : ",\n    ")
            write_json(io, thermoml_article(ds, ref, groups[ref]), 2, 6)
        end
        write(io, "\n  ]\n}\n")
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
`articles`, the formats it `skipped` (with the reason), and the `bibtex` report of the
references (`nothing` when only a ThermoML JSON was written, which needs no references).
"""
struct ExportReport
    files::Vector{String}
    points::Int
    articles::Int
    skipped::Vector{Pair{Symbol,String}}
    bibtex::Union{Nothing,BibtexReport}
end

function Base.show(io::IO, ::MIME"text/plain", r::ExportReport)
    println(io, "ExportReport: ", r.points, " points from ", r.articles, " articles")
    for file in r.files
        println(io, "  wrote ", file)
    end
    for (format, reason) in r.skipped
        println(io, "  skipped :", format, " (", reason, ")")
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
# The dispatcher
# ----------------------------------------------------------------------------------

# (kind, format, path): a file with a known extension, or a directory (no extension, or a
# path that ends with a separator).
function export_target(path::AbstractString)
    text = String(path)
    as_directory = endswith(text, '/') || endswith(text, '\\')
    text = String(rstrip(text, ['/', '\\']))
    isempty(text) && throw(ArgumentError("the destination path is empty"))
    if !as_directory
        endswith(lowercase(text), ".thermoml.json") && return (:file, :thermoml, text)
        _, extension = splitext(text)
        format = get(FORMAT_EXTENSIONS, lowercase(extension), nothing)
        format === nothing || return (:file, format, text)
        isempty(extension) ||
            isdir(text) ||
            throw(
                ArgumentError(
                    "unknown extension \"$extension\"; use .csv, .xlsx, .json, .jld2 or " *
                    ".thermoml.json, or end the path with a slash to name a directory",
                ),
            )
    end
    return (:directory, :all, text)
end

file_extension(format::Symbol) =
    format === :thermoml ? ".thermoml.json" : string('.', format)

function write_points_xlsx(path::AbstractString, data::ExportData; sheets::Symbol)
    xlsx_available() || throw(ArgumentError(XLSX_MESSAGE))
    write_xlsx(String(path), xlsx_sheets(data; sheets))
    return nothing
end

function write_point_file(
    format::Symbol,
    path::AbstractString,
    data::Union{Nothing,ExportData},
    view::DataView;
    sheets::Symbol,
    json_layout::Symbol,
)
    mkpath(dirname(abspath(path)))
    if format === :thermoml || (format === :json && json_layout === :thermoml)
        origin = data === nothing ? origin_note(view) : data.origin
        write_points_thermoml(path, view; origin)
    elseif format === :csv
        write_points_csv(path, data)
    elseif format === :json
        write_points_json(path, data)
    elseif format === :jld2
        write_points_jld2(path, data)
    elseif format === :tex
        write_points_tex(path, data)
    elseif format === :xlsx
        write_points_xlsx(path, data; sheets)
    else
        throw(ArgumentError("unknown format :$format; choose from $(POINT_FORMATS)"))
    end
    return nothing
end

function write_reference_files(stem::AbstractString, data::ExportData)
    files = String[
        string(stem, "_references.csv"),
        string(stem, ".bib"),
        string(stem, "_references.tex"),
    ]
    write(files[1], csv_table(data.summary))
    write(files[2], bibtex(data.summary))
    write(
        files[3],
        latex_table(data.summary; reference = data.reference === :key ? :cite : :text),
    )
    return files
end

"""
    export_points(path, view; formats = nothing, reference = :key, units = :native,
                  policy = :nominal, sheets = :system, json_layout = :records,
                  references = true, online = true, cache = true, refresh = false,
                  progress = true) -> ExportReport

Write the points of `view` (a [`DataView`](@ref), or a [`Dataset`](@ref) for all of them)
to `path`. The extension of `path` chooses the format:

- `.csv`: one table. Every header carries the unit of its column in brackets
  (`temperature [K]`, `value [kg/m3]`). The first line is a comment on the origin of the data
  when they come from the ThermoML Archive; skip it when reading (`header = 2`).
- `.xlsx`: one sheet per system (`sheets = :system`, or all points in one sheet with
  `:single`), a `references` sheet and, for ThermoML data, an `origin` sheet. It needs the
  XLSX package: `using XLSX` first.
- `.json`: one record per point, with the origin as its first entry. With
  `json_layout = :thermoml`, or when the path ends with `.thermoml.json`, the file holds
  a subset of the ThermoML schema instead (see below).
- `.jld2`: the columns, units and references as Julia data.
- `.tex`: the same table as a `longtable`, with `\\cite{key}` in the reference column when
  `reference = :key`. The references written with it (`name_references.tex`, a table of the ranges
  of each article, and `name.bib`) use the same keys.
- no extension (or a path ending with `/`): a directory with that name holding
  `name.csv`, `name.xlsx`, `name.json`, `name.jld2` and `name.tex` (`formats` chooses; `:thermoml`
  is also accepted), plus `name_references.csv`, `name_references.tex` and `name.bib`.

The tables hold points only. The articles are described in the references table, linked
through the `reference` column: `reference = :key` writes the BibTeX key (the same keys as
[`bibtex`](@ref)), `:text` a written-out citation (`Chirico et al. (2003)`) and `:doi` the
DOI. A `.csv` or `.tex` has no room for the references table, so `references = true` writes it
next to the file as `name_references.csv`, with `name.bib`; the other formats hold it.
Columns that are empty for the whole selection are left out.

`units = :si` converts values, uncertainties and pressure to SI (see [`table`](@ref)); the
ThermoML layout always keeps the units of the archive. The uncertainty columns are `unc`
(as reported) and `unc_k2` (at ``k = 2``, see `policy` in [`table`](@ref)). `online`,
`cache`, `refresh` and `progress` act as in [`bibtex`](@ref).

The ThermoML layout holds, for every article of the selection, its `Citation`, the
`Compound`s and the `PureOrMixtureData` with the selected points only, in the structure
the archive uses, and so can be read back with the same code. It is a subset: fields
the package does not keep (such as the apparatus or the evaluator) are absent.

# Examples
```julia
v = points(db; component = "water", exact = true, property = "Mass density")
export_points("data/water.csv", v)
export_points("data/water", v)               # data/water/water.csv, .json, .jld2, ...
export_points("data/water.thermoml.json", v)
```
"""
function export_points(
    path::AbstractString,
    view::DataView;
    formats = nothing,
    sheets::Symbol = :system,
    json_layout::Symbol = :records,
    references::Bool = true,
    reference::Symbol = :key,
    units::Symbol = :native,
    policy::Symbol = :nominal,
    kwargs...,
)
    sheets in SHEET_LAYOUTS ||
        throw(ArgumentError("sheets must be one of $(SHEET_LAYOUTS), got :$sheets"))
    json_layout in JSON_LAYOUTS || throw(
        ArgumentError("json_layout must be one of $(JSON_LAYOUTS), got :$json_layout"),
    )
    isempty(view.rows) && throw(ArgumentError("the selection has no points to export"))
    kind, format, target = export_target(path)

    chosen = if kind === :directory
        formats === nothing ? DIRECTORY_FORMATS : Tuple(Symbol.(formats))
    else
        formats === nothing || throw(
            ArgumentError(
                "formats applies to directories; the extension of $path already chooses",
            ),
        )
        (format,)
    end
    for f in chosen
        f in POINT_FORMATS ||
            throw(ArgumentError("unknown format :$f; choose from $(POINT_FORMATS)"))
    end
    thermoml_only =
        all(f -> f === :thermoml || (f === :json && json_layout === :thermoml), chosen)
    # A ThermoML-only export reads nothing but the dataset: no references, no network.
    data =
        thermoml_only ? nothing :
        build_export_data(view; reference, units, policy, kwargs...)

    files = String[]
    skipped = Pair{Symbol,String}[]
    if kind === :file
        write_point_file(format, target, data, view; sheets, json_layout)
        push!(files, target)
        if format in (:csv, :tex) && references
            append!(files, write_reference_files(first(splitext(target)), data))
        end
    else
        name = basename(target)
        mkpath(target)
        for f in chosen
            if f === :xlsx && !xlsx_available()
                formats === nothing || throw(ArgumentError(XLSX_MESSAGE))
                @warn "Skipping the .xlsx file: $XLSX_MESSAGE"
                push!(skipped, :xlsx => XLSX_MESSAGE)
                continue
            end
            file = joinpath(target, name * file_extension(f))
            write_point_file(f, file, data, view; sheets, json_layout)
            push!(files, file)
        end
        if references && data !== nothing
            append!(files, write_reference_files(joinpath(target, name), data))
        end
    end
    return ExportReport(
        files,
        length(view.rows),
        article_count(view),
        skipped,
        data === nothing ? nothing : getfield(data.summary, :bibliography).report,
    )
end

export_points(path::AbstractString, ds::Dataset; kwargs...) =
    export_points(path, DataView(ds); kwargs...)
