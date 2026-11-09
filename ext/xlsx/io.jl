# Reading a filled template and writing one, with the names that `layout.jl` defines.

const TD = ThermophysicalDB

# The value of a defined name: `nothing` when the file has no such name (`missing` is an empty cell).
function named(xf, name::AbstractString)
    try
        return xf[name]
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
end

# An empty text is an empty cell; other texts lose their spaces at the ends.
function cleaned(x)
    x isa AbstractString || return x
    t = strip(x)
    return isempty(t) ? missing : String(t)
end

scalar(x) = x isa AbstractArray ? (isempty(x) ? missing : cleaned(first(x))) : cleaned(x)
vector(x) = x isa AbstractArray ? Any[cleaned(v) for v in vec(x)] : Any[cleaned(x)]

function required_name(xf, name::AbstractString, path::AbstractString)
    value = named(xf, name)
    value === nothing && throw(
        ArgumentError(
            "$path is not a ThermophysicalDB template (it has no name \"$name\"); was it saved from another program?",
        ),
    )
    return value
end

function ThermophysicalDB.read_template(path::String)
    isfile(path) || throw(ArgumentError("there is no file $path"))
    xf = XLSX.readxlsx(path)
    format = scalar(required_name(xf, "template_format", path))
    (format isa Real && format <= TD.TEMPLATE_FORMAT) || throw(
        ArgumentError(
            "$path is a template of format $(repr(format)); this version of the package reads up to format $(TD.TEMPLATE_FORMAT)",
        ),
    )
    version = scalar(named(xf, "package_version"))
    one(name) = scalar(required_name(xf, name, path))
    authors =
        Any[cleaned(a) for a in vec(permutedims(required_name(xf, "ref_authors", path)))]
    reference = (;
        doi = one("ref_doi"),
        authors,
        title = one("ref_title"),
        journal = one("ref_journal"),
        year = one("ref_year"),
        volume = one("ref_volume"),
        pages = one("ref_pages"),
        other = one("ref_other"),
    )
    columns = [vector(required_name(xf, "comp_$(c)", path)) for c in TD.COMPOUND_COLUMNS]
    compounds = NamedTuple[]
    for i = 1:COMPOUND_ROWS
        values = [col[i] for col in columns]
        any(TD.isgiven, values) || continue
        push!(
            compounds,
            (;
                row = COMPOUNDS_FIRST + i - 1,
                NamedTuple{TD.COMPOUND_COLUMNS}(Tuple(values))...,
            ),
        )
    end
    experiments = TD.TemplateExperiment[]
    k = 1
    while named(xf, "exp$(k)_name") !== nothing
        table = required_name(xf, "pts$(k)_table", path)
        keep = [i for i in axes(table, 1) if any(TD.isgiven, view(table, i, :))]
        cells = Matrix{Any}(undef, length(keep), size(table, 2))
        for (a, i) in enumerate(keep), j in axes(table, 2)
            cells[a, j] = cleaned(table[i, j])
        end
        field(key) = scalar(required_name(xf, "exp$(k)_$key", path))
        push!(
            experiments,
            TD.TemplateExperiment(
                path,
                k,
                field("name"),
                field("property"),
                field("phase"),
                field("method"),
                field("purpose"),
                vector(required_name(xf, "exp$(k)_components", path)),
                field("scale"),
                field("source"),
                vector(required_name(xf, "exp$(k)_notes", path)),
                vector(required_name(xf, "pts$(k)_units", path)),
                vector(required_name(xf, "pts$(k)_unc_type", path)),
                vector(required_name(xf, "pts$(k)_k", path)),
                Int[POINTS_FIRST + i - 1 for i in keep],
                cells,
            ),
        )
        k += 1
    end
    return TD.TemplateData(
        path,
        Int(format),
        version === missing ? "" : String(version),
        one("target_database"),
        one("data_kind"),
        reference,
        compounds,
        experiments,
    )
end

function ThermophysicalDB.read_template_info(path::String)
    xf = XLSX.readxlsx(path)
    text(x) = ismissing(x) ? "" : String(x)
    whole(x) = ismissing(x) ? 0 : Int(x)
    databases = NamedTuple[]
    table = named(xf, "databases_table")
    if table isa AbstractMatrix
        for i in axes(table, 1)
            ismissing(table[i, 1]) && continue
            push!(
                databases,
                (;
                    name = text(table[i, 1]),
                    kind = text(table[i, 2]),
                    priority = whole(table[i, 3]),
                    points = whole(table[i, 4]),
                    saved = text(table[i, 5]) == "yes",
                ),
            )
        end
    end
    properties = NamedTuple[]
    table = named(xf, "properties_table")
    if table isa AbstractMatrix
        for i in axes(table, 1)
            ismissing(table[i, 1]) && continue
            push!(
                properties,
                (;
                    label = text(table[i, 1]),
                    unit = text(table[i, 2]),
                    points = whole(table[i, 3]),
                    found_in = text(table[i, 4]),
                ),
            )
        end
    end
    return TD.TemplateInfo(
        string(pkgversion(ThermophysicalDB)),
        TD.TEMPLATE_SCHEMA,
        string(Dates.today()),
        databases,
        properties,
    )
end

# ---------------------------------------------------------------------------------------------
# Writing, with what the person had already filled in
# ---------------------------------------------------------------------------------------------

# Puts a number or a text into a cell of the template, keeping its style; anything else (an empty
# cell, a truth value) is left alone.
function fill_cell!(sheet::Sheet, row::Integer, col::Integer, value)
    if value isa Real && !(value isa Bool) && isfinite(value)
        paint_value!(sheet, row, col, value)
    elseif value isa AbstractString && !isempty(value)
        paint_value!(sheet, row, col, String(value))
    end
    return nothing
end

function fill_template!(book::Book, data::TD.TemplateData)
    sheets = Dict(s.name => s for s in book.sheets)
    ref = sheets["Reference"]
    fill_cell!(ref, 5, 3, data.target)
    fill_cell!(ref, 6, 3, data.kind)
    fill_cell!(ref, 9, 3, data.reference.doi)
    for (i, a) in enumerate(first(data.reference.authors, 8))
        fill_cell!(ref, 10 + (i - 1) ÷ 4, 3 + (i - 1) % 4, a)
    end
    fill_cell!(ref, 12, 3, data.reference.title)
    fill_cell!(ref, 13, 3, data.reference.journal)
    fill_cell!(ref, 14, 3, data.reference.year)
    fill_cell!(ref, 15, 3, data.reference.volume)
    fill_cell!(ref, 16, 3, data.reference.pages)
    fill_cell!(ref, 17, 3, data.reference.other)
    length(data.compounds) <= COMPOUND_ROWS || throw(
        ArgumentError(
            "a template holds $COMPOUND_ROWS compounds, the file has $(length(data.compounds))",
        ),
    )
    for (i, c) in enumerate(data.compounds), (j, key) in enumerate(TD.COMPOUND_COLUMNS)
        fill_cell!(ref, COMPOUNDS_FIRST + i - 1, 1 + j, getfield(c, key))
    end
    for e in data.experiments
        exp = get(sheets, "EXP-$(e.sheet)", nothing)
        pts = get(sheets, "PTS-$(e.sheet)", nothing)
        (exp === nothing || pts === nothing) && continue
        for (row, v) in (
            (5, e.name),
            (6, e.property),
            (7, e.phase),
            (8, e.method),
            (9, e.purpose),
            (15, e.scale),
            (25, e.source),
        )
            fill_cell!(exp, row, 3, v)
        end
        for (i, c) in enumerate(first(e.components, 3))
            fill_cell!(exp, 12, 2 + i, c)
        end
        for (i, n) in enumerate(first(e.notes, 2))
            fill_cell!(exp, 25 + i, 3, n)
        end
        for j in (1, 2, 3, 7, 9, 11)
            fill_cell!(pts, 5, j + 1, e.units[j])
        end
        for j in (4, 5, 6, 8, 10, 12)
            fill_cell!(pts, 6, j + 1, e.unc_type[j])
            fill_cell!(pts, 7, j + 1, e.unc_k[j])
        end
        for (i, r) in enumerate(e.rows), j in axes(e.cells, 2)
            fill_cell!(pts, r, j + 1, e.cells[i, j])
        end
    end
    return book
end

function ThermophysicalDB.write_template(
    path::String,
    experiments::Int,
    info::TD.TemplateInfo;
    fill::Union{Nothing,TD.TemplateData} = nothing,
)
    book = build_template(experiments, info, read(joinpath(@__DIR__, "logo.png")))
    fill === nothing || fill_template!(book, fill)
    write_book(path, book)
    return path
end
