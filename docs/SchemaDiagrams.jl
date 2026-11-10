# Diagrams of the data model, drawn from the type definitions of the package.
#
# `ThermophysicalDB.schema_tables()` gives the tables, their columns and the relations
# between them; the functions below only decide what to show and where to put it. They
# return a `SchemaFigure`, which Documenter embeds as an image.

module SchemaDiagrams

using ThermophysicalDB: ThermophysicalDB

export SchemaFigure, provenance, meaning, purity, storage

struct SchemaFigure
    svg::String
end

Base.show(io::IO, ::MIME"image/svg+xml", figure::SchemaFigure) = print(io, figure.svg)
Base.show(io::IO, ::MIME"text/plain", figure::SchemaFigure) =
    print(io, "SchemaFigure(", length(figure.svg), " bytes of SVG)")

const COLORS = Dict(
    :references => "#2fe0ff",
    :compounds => "#58ff7a",
    :properties => "#ffb000",
    :samples => "#d98cff",
    :purity_steps => "#ff7ad9",
    :experiments => "#ff4a1c",
    :measurements => "#5c8dff",
    :extras => "#ffd36b",
    :conditions => "#7cf0c8",
    :uncertainties => "#ff9a5c",
)
const BADGE_COLORS =
    Dict("PK" => "#ffd36b", "UQ" => "#58ff7a", "FK" => "#ff8a4c", "FK*" => "#ff8a4c")
const BACKGROUND = "#090b17"
const TEXT = "#e8ecff"
const MUTED = "#9aa3c7"
const MONO = "ui-monospace,Consolas,monospace"

const NOTES = Dict(
    :references => "one row per publication",
    :compounds => "one row per chemical species",
    :properties => "one row per (label, unit) pair",
    :samples => "one row per sample described in a publication",
    :purity_steps => "one row per purification step of a sample",
    :experiments => "one row per system studied in a publication",
    :measurements => "one row per measured value",
    :extras => "one row per extra field",
    :conditions => "one row per condition, phase or constraint",
    :uncertainties => "one row per uncertainty term",
)

const ROW_HEIGHT = 22.0
const HEADER_HEIGHT = 32.0

escape_xml(s) =
    replace(string(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

# ---------------------------------------------------------------------------- boxes

struct Row
    badge::String
    name::String
    type::String
    column::Union{Nothing,ThermophysicalDB.SchemaColumn}
end

struct Box
    table::Symbol
    x::Float64
    y::Float64
    w::Float64
    h::Float64
    rows::Vector{Row}
end

function badge_of(c)
    c.role === :unique && return "UQ"
    (c.role === :table || c.role === :pool) && return "FK"
    c.role === :any && return "FK*"
    return ""
end

column_label(c) = c.arity > 1 ? "$(c.name)[1..$(c.arity)]" : String(c.name)

function type_label(c)
    (c.role === :table || c.role === :pool) && return "$(c.eltype) → $(c.target)"
    c.role === :any && return "$(c.eltype) → any table"
    return c.eltype
end

schema_table(name::Symbol) =
    only(t for t in ThermophysicalDB.schema_tables() if t.name === name)

# `show` lists the columns to draw; the others are counted in a last row.
function box(name::Symbol, x, y, w; show = nothing)
    rows = Row[Row("PK", "row number", "Int32 · position", nothing)]
    hidden = 0
    for c in schema_table(name).columns
        if show !== nothing && !(c.name in show)
            hidden += 1
            continue
        end
        push!(rows, Row(badge_of(c), column_label(c), type_label(c), c))
    end
    hidden > 0 && push!(rows, Row("", "… $hidden more columns", "", nothing))
    h = HEADER_HEIGHT + length(rows) * ROW_HEIGHT + 8
    return Box(name, Float64(x), Float64(y), Float64(w), h, rows)
end

row_y(b::Box, i) = b.y + HEADER_HEIGHT + (i - 1) * ROW_HEIGHT + ROW_HEIGHT / 2

function row_index(b::Box, column::Symbol)
    i = findfirst(r -> r.column !== nothing && r.column.name === column, b.rows)
    i === nothing && error("`$column` is not drawn in the box of `$(b.table)`")
    return i
end

function draw_badge(io, x, y, badge)
    w = length(badge) < 3 ? 30 : 36
    color = BADGE_COLORS[badge]
    println(
        io,
        "<rect x=\"$x\" y=\"$(y - 8)\" width=\"$w\" height=\"16\" rx=\"4\" fill=\"$color\"/>",
    )
    println(
        io,
        "<text x=\"$(x + w / 2)\" y=\"$(y + 4)\" text-anchor=\"middle\" font-size=\"10\" font-weight=\"700\" fill=\"#06070d\">$badge</text>",
    )
    return w
end

function draw_box(io, b::Box)
    color = COLORS[b.table]
    x, y, w, h = b.x, b.y, b.w, b.h
    println(
        io,
        "<rect x=\"$x\" y=\"$y\" width=\"$w\" height=\"$h\" rx=\"12\" fill=\"$color\" fill-opacity=\"0.10\" stroke=\"$color\" stroke-width=\"2\"/>",
    )
    println(
        io,
        "<path d=\"M$x $(y + HEADER_HEIGHT) V$(y + 12) a12 12 0 0 1 12 -12 H$(x + w - 12) a12 12 0 0 1 12 12 V$(y + HEADER_HEIGHT) z\" fill=\"$color\" fill-opacity=\"0.92\"/>",
    )
    println(
        io,
        "<text x=\"$(x + w / 2)\" y=\"$(y + 21)\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"700\" fill=\"#06070d\">$(escape_xml(b.table))</text>",
    )
    for (i, r) in enumerate(b.rows)
        cy = row_y(b, i)
        isempty(r.badge) || draw_badge(io, x + 10, cy, r.badge)
        derived = r.column === nothing
        style = derived ? " font-style=\"italic\"" : ""
        fill = derived ? MUTED : TEXT
        println(
            io,
            "<text x=\"$(x + 52)\" y=\"$(cy + 5)\" font-size=\"13\" font-family=\"$MONO\" fill=\"$fill\"$style>$(escape_xml(r.name))</text>",
        )
        isempty(r.type) || println(
            io,
            "<text x=\"$(x + w - 12)\" y=\"$(cy + 5)\" text-anchor=\"end\" font-size=\"12\" font-family=\"$MONO\" fill=\"$MUTED\">$(escape_xml(r.type))</text>",
        )
    end
    return nothing
end

# An elbow from the row of `column` in `from` to the row-number row of `to`.
function draw_arrow(
    io,
    from::Box,
    column::Symbol,
    to::Box,
    side_from::Symbol,
    side_to::Symbol;
    xm = nothing,
)
    y1 = row_y(from, row_index(from, column))
    y2 = row_y(to, 1)
    x1 = side_from === :left ? from.x : from.x + from.w
    x2 = side_to === :left ? to.x : to.x + to.w
    xm === nothing && (xm = (x1 + x2) / 2)
    println(
        io,
        "<path d=\"M$x1 $y1 H$xm V$y2 H$x2\" fill=\"none\" stroke=\"$TEXT\" stroke-width=\"2\" marker-end=\"url(#arrow)\"/>",
    )
    println(io, "<circle cx=\"$x1\" cy=\"$y1\" r=\"3.5\" fill=\"$TEXT\"/>")
    return nothing
end

function draw_legend(io, y)
    items = (
        "PK" => "row number: position of the row, identifies it",
        "UQ" => "natural key: rows are deduplicated by it",
        "FK" => "row number of another table, or of a string pool",
    )
    for (badge, text) in items
        w = draw_badge(io, 20, y, badge)
        println(
            io,
            "<text x=\"$(20 + w + 8)\" y=\"$(y + 4)\" font-size=\"11.5\" fill=\"$MUTED\">$(escape_xml(text))</text>",
        )
        y += 22
    end
    return y
end

function draw_note(io, b::Box, x)
    println(
        io,
        "<text x=\"$x\" y=\"$(b.y + HEADER_HEIGHT + ROW_HEIGHT / 2 + 5)\" font-size=\"12.5\" fill=\"$MUTED\">$(escape_xml(NOTES[b.table]))</text>",
    )
    return nothing
end

function wrap(width, height, body, label)
    return SchemaFigure(
        """
<svg viewBox="0 0 $width $height" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="$(escape_xml(label))" font-family="system-ui,Segoe UI,Roboto,Arial,sans-serif">
<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="$TEXT"/></marker></defs>
<rect width="$width" height="$height" rx="14" fill="$BACKGROUND"/>
$body</svg>
""",
    )
end

# ---------------------------------------------------------------------------- figures

"""
    provenance()

The chain that ties a value to its publication: measurement, experiment, reference.
"""
function provenance()
    width, bw, x0 = 760.0, 380.0, 60.0
    references = box(:references, x0, 20, bw)
    experiments = box(:experiments, x0, references.y + references.h + 54, bw)
    measurements = box(
        :measurements,
        x0,
        experiments.y + experiments.h + 54,
        bw;
        show = (:experiment, :value, :unc, :temperature, :pressure),
    )
    io = IOBuffer()
    for b in (references, experiments, measurements)
        draw_box(io, b)
        draw_note(io, b, x0 + bw + 26)
    end
    draw_arrow(io, experiments, :reference, references, :left, :left; xm = x0 - 18)
    draw_arrow(io, measurements, :experiment, experiments, :left, :left; xm = x0 - 42)
    height = draw_legend(io, measurements.y + measurements.h + 30)
    return wrap(width, height, String(take!(io)), "From a measurement to its publication")
end

"""
    meaning()

What a measurement refers to: its property, and the compounds of its experiment.
"""
function meaning()
    width, bw, gap, x0 = 760.0, 300.0, 110.0, 25.0
    measurements = box(:measurements, x0, 20, bw; show = (:property, :value))
    properties = box(:properties, x0 + bw + gap, 20, bw)
    top = max(measurements.h, properties.h)
    experiments = box(:experiments, x0, 20 + top + 40, bw; show = (:components, :kinds))
    compounds = box(:compounds, x0 + bw + gap, experiments.y, bw)
    io = IOBuffer()
    for b in (measurements, properties, experiments, compounds)
        draw_box(io, b)
    end
    draw_arrow(io, measurements, :property, properties, :right, :left)
    draw_arrow(io, experiments, :components, compounds, :right, :left)
    height = draw_legend(io, experiments.y + max(experiments.h, compounds.h) + 30)
    return wrap(width, height, String(take!(io)), "What a measurement refers to")
end

"""
    purity()

How an experiment reaches the purity of its samples: experiment, sample, purification steps.
"""
function purity()
    width, bw, gap, x0 = 760.0, 320.0, 60.0, 25.0
    experiments = box(:experiments, x0, 20, bw; show = (:components, :samples, :purpose))
    samples = box(
        :samples,
        x0 + bw + gap,
        20,
        bw;
        show = (
            :reference,
            :compound,
            :origin,
            :purity,
            :purity_kind,
            :purity_basis,
            :analysis,
        ),
    )
    steps = box(
        :purity_steps,
        samples.x,
        samples.y + samples.h + 44,
        bw;
        show = (:sample, :step, :mass, :mole, :analysis),
    )
    io = IOBuffer()
    for b in (experiments, samples, steps)
        draw_box(io, b)
    end
    draw_arrow(io, experiments, :samples, samples, :right, :left)
    draw_arrow(io, steps, :sample, samples, :right, :right; xm = samples.x + bw + 18)
    height = draw_legend(io, steps.y + steps.h + 30)
    return wrap(
        width,
        height,
        String(take!(io)),
        "From an experiment to the purity of its samples",
    )
end

"""
    storage()

A table in full, and the string pools that its identifier columns share.
"""
function storage()
    width, bw, x0 = 760.0, 310.0, 20.0
    measurements = box(:measurements, x0, 20, bw)
    px = x0 + bw + 30
    pw = width - px - 20

    pools = ThermophysicalDB.schema_pools()
    users = Dict(p => Symbol[] for p in pools)
    for t in ThermophysicalDB.schema_tables(), c in t.columns
        c.role === :pool && push!(users[c.target], t.name)
    end
    pools_height = HEADER_HEIGHT + length(pools) * ROW_HEIGHT + 8

    io = IOBuffer()
    draw_box(io, measurements)
    println(
        io,
        "<rect x=\"$px\" y=\"20\" width=\"$pw\" height=\"$pools_height\" rx=\"12\" fill=\"$MUTED\" fill-opacity=\"0.10\" stroke=\"$MUTED\" stroke-width=\"2\" stroke-dasharray=\"6 4\"/>",
    )
    println(
        io,
        "<text x=\"$(px + pw / 2)\" y=\"41\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"700\" fill=\"$TEXT\">string pools</text>",
    )
    for (i, p) in enumerate(pools)
        cy = 20 + HEADER_HEIGHT + (i - 1) * ROW_HEIGHT + ROW_HEIGHT / 2
        println(
            io,
            "<text x=\"$(px + 12)\" y=\"$(cy + 5)\" font-size=\"13\" font-family=\"$MONO\" fill=\"$TEXT\">$p</text>",
        )
        println(
            io,
            "<text x=\"$(px + pw - 12)\" y=\"$(cy + 5)\" text-anchor=\"end\" font-size=\"11.5\" font-family=\"$MONO\" fill=\"$MUTED\">$(escape_xml(join(users[p], " · ")))</text>",
        )
    end
    extras = box(:extras, px, 20 + pools_height + 30, pw)
    draw_box(io, extras)
    conditions = box(:conditions, px, extras.y + extras.h + 30, pw)
    draw_box(io, conditions)
    uncertainties = box(:uncertainties, px, conditions.y + conditions.h + 30, pw)
    draw_box(io, uncertainties)
    height = draw_legend(
        io,
        max(measurements.y + measurements.h, uncertainties.y + uncertainties.h) + 30,
    )
    return wrap(width, height, String(take!(io)), "Columns of a table and the string pools")
end

end # module
