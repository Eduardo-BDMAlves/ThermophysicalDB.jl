# The types of the search for repeated points: the rules (how close two points must be to be the same
# one) and the report (which points are repeated, and which ones disagree). The search itself is in
# `duplicates.jl`; these come first because a `DatabaseView` can carry the report that made it.

"""
    DuplicateRules(; temperature = 0.1, pressure = 1.0, value = 1.0e-3, composition = 1.0e-3)

How close two points of different databases must be to count as the same point:

- `temperature`: largest difference (the default is 0.1 K);
- `pressure`: largest difference (the default is 1 kPa, that is 0.01 bar);
- `value`: largest relative difference of the measured value (0.1 %): `|a - b| <= value * max(|a|, |b|)`;
- `composition`: the same for the amount of each component, in the scale the points were given in.

A plain number is in K, in kPa, or a fraction. A text with a unit or a quantity of a units package is
converted here, once, and the rules keep plain numbers: `DuplicateRules(temperature = "0.1 degC",
pressure = "0.01 bar", value = "0.1 %")`. A temperature tolerance is a difference, so `"0.1 degF"`
is 0.0556 K, not a temperature.

They are given to [`points`](@ref) as `duplicate = DuplicateRules(...)`; `duplicate = false` uses the
defaults. A point is the same as another only when it is of the same work (see [`duplicates`](@ref)).
"""
struct DuplicateRules
    temperature::Float64
    pressure::Float64
    value::Float64
    composition::Float64
end

function DuplicateRules(;
    temperature = 0.1,
    pressure = 1.0,
    value = 1.0e-3,
    composition = 1.0e-3,
)
    t = input_named("the temperature tolerance", temperature, NativeTemperature(), true)
    p = input_named("the pressure tolerance", pressure, NativePressure(), true)
    v = relative_named("the value tolerance", value)
    c = relative_named("the composition tolerance", composition)
    for (name, x) in (:temperature => t, :pressure => p, :value => v, :composition => c)
        (isfinite(x) && x >= 0) || throw(
            ArgumentError(
                "the $name tolerance must be a number that is not negative, got $x",
            ),
        )
    end
    return DuplicateRules(t, p, v, c)
end

const DEFAULT_DUPLICATE_RULES = DuplicateRules()

function Base.show(io::IO, r::DuplicateRules)
    return print(
        io,
        "DuplicateRules(T ± ",
        r.temperature,
        " K, p ± ",
        r.pressure,
        " kPa, value ± ",
        100 * r.value,
        " %, composition ± ",
        100 * r.composition,
        " %)",
    )
end

"""
    DuplicateReport

The pairs of points of different databases that [`duplicates`](@ref) and [`conflicts`](@ref) found.
Each pair has the point of the database that wins (`database`, `row`, `value`, `temperature`,
`pressure`) and the other one (`other_*`), the work they come from (`work`, found by its DOI or by
its first author and year: `how`), the `property` and the `compounds`, and the criteria that could
not be checked because a side did not have them (`ignored`). `row` is the position in the table of
measurements of that database. A report is a table (Tables.jl); its `kind` column is `:duplicate`
(the points are the same) or `:conflict` (same reference, same conditions, different value).
`works`, `compared` and `skipped` count the works that are in several databases, the points
compared and the points without temperature, which are never compared.
"""
struct DuplicateReport
    rules::DuplicateRules
    kind::Vector{Symbol}
    work::Vector{String}
    how::Vector{Symbol}
    property::Vector{String}
    compounds::Vector{String}
    database::Vector{String}
    row::Vector{Int32}
    value::Vector{Float64}
    temperature::Vector{Float64}
    pressure::Vector{Float64}
    other_database::Vector{String}
    other_row::Vector{Int32}
    other_value::Vector{Float64}
    other_temperature::Vector{Float64}
    other_pressure::Vector{Float64}
    ignored::Vector{String}
    works::Int
    compared::Int
    skipped::Int
end

function DuplicateReport(rules::DuplicateRules = DEFAULT_DUPLICATE_RULES)
    return DuplicateReport(
        rules,
        Symbol[],
        String[],
        Symbol[],
        String[],
        String[],
        String[],
        Int32[],
        Float64[],
        Float64[],
        Float64[],
        String[],
        Int32[],
        Float64[],
        Float64[],
        Float64[],
        String[],
        0,
        0,
        0,
    )
end

const REPORT_COLUMNS = (
    :kind,
    :work,
    :how,
    :property,
    :compounds,
    :database,
    :row,
    :value,
    :temperature,
    :pressure,
    :other_database,
    :other_row,
    :other_value,
    :other_temperature,
    :other_pressure,
    :ignored,
)

Base.length(r::DuplicateReport) = length(r.kind)
Base.isempty(r::DuplicateReport) = isempty(r.kind)

# The pairs `idx` of a report, with the same counts.
function select_pairs(r::DuplicateReport, idx::AbstractVector{<:Integer})
    return DuplicateReport(
        r.rules,
        (getfield(r, k)[idx] for k in REPORT_COLUMNS)...,
        r.works,
        r.compared,
        r.skipped,
    )
end

"The number of pairs of each kind."
function pair_counts(r::DuplicateReport)
    repeated = count(==(:duplicate), r.kind)
    return (; repeated, conflicts = length(r) - repeated)
end

Tables.istable(::Type{DuplicateReport}) = true
Tables.columnaccess(::Type{DuplicateReport}) = true
Tables.columns(r::DuplicateReport) =
    NamedTuple{REPORT_COLUMNS}(map(k -> getfield(r, k), REPORT_COLUMNS))

function Base.show(io::IO, r::DuplicateReport)
    n = pair_counts(r)
    return print(
        io,
        "DuplicateReport(",
        n.repeated,
        " repeated, ",
        n.conflicts,
        " in conflict)",
    )
end

function Base.show(io::IO, ::MIME"text/plain", r::DuplicateReport; maxrows::Int = 12)
    n = pair_counts(r)
    println(
        io,
        "DuplicateReport: ",
        n.repeated,
        " repeated points, ",
        n.conflicts,
        " conflicts",
    )
    println(io, "  ", r.rules)
    println(
        io,
        "  ",
        r.works,
        r.works == 1 ? " work is" : " works are",
        " in more than one database; ",
        r.compared,
        " points compared, ",
        r.skipped,
        " without temperature not compared",
    )
    isempty(r) && return nothing
    shown = 1:min(length(r), maxrows)
    headers = [
        "kind",
        "work",
        "property",
        "T [K]",
        "p [kPa]",
        "value",
        "other value",
        "databases",
    ]
    cells = [
        [
            String(r.kind[i]),
            display_cell(r.work[i]),
            display_cell(r.property[i]),
            display_cell(r.temperature[i]),
            display_cell(r.pressure[i]),
            display_cell(r.value[i]),
            display_cell(r.other_value[i]),
            r.database[i] * " / " * r.other_database[i],
        ] for i in shown
    ]
    widths = [
        max(length(headers[j]), maximum(length(c[j]) for c in cells)) for
        j in eachindex(headers)
    ]
    left = Set([1, 2, 3, 8])
    pad(text, j) = j in left ? rpad(text, widths[j]) : lpad(text, widths[j])
    println(io)
    println(io, rstrip(join((pad(headers[j], j) for j in eachindex(headers)), "  ")))
    println(io, join((repeat("─", w) for w in widths), "  "))
    for c in cells
        println(io, rstrip(join((pad(c[j], j) for j in eachindex(headers)), "  ")))
    end
    hidden = length(r) - length(shown)
    hidden > 0 && println(io, "… and ", hidden, " more pairs")
    return nothing
end
