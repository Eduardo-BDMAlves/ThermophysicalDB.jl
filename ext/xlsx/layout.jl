# The layout of the data entry template: which sheet has what, where. `ooxml.jl` writes it.
#
# The defined names (`ref_doi`, `comp_name`, `exp1_property`, `pts1_table`...) are the contract with
# the importer: it finds the cells by name, never by address, so the layout may change without
# breaking files that people have already filled in.

# Palette of the package (docs/DocsSetup.jl and the theme of the site): the colours of discharge tubes.
const NAVY = "090B17"
const HELIUM = "3347FF"
const MERCURY = "4F6BFF"
const HYDROGEN = "FF2F3F"
const NEON = "FF7A1A"
const SODIUM = "FFB000"
const XENON = "2FE0FF"
const INK = "141830"
const MUTE = "5A6494"
const INPUT_FILL = "E6EAFF"
const INPUT_ALT = "EFF2FF"
const CALC_FILL = "F1F2F8"
const LABEL_FILL = "D5DCF7"
const BAND_FILL = "F5F6FD"
const ERROR_FILL = "FFE1DC"
const OK_FONT = "00963A"
const ERROR_FONT = "D12A00"
const CALC_FONT = "4A5380"
const GREY_FILL = "D3D6E2"

const POINT_ROWS = 200       # points of one experiment sheet
const COMPOUND_ROWS = 25     # compounds of one reference
const POINTS_FIRST = 8       # first row of points on a PTS sheet
const POINTS_LAST = POINTS_FIRST + POINT_ROWS - 1
const COMPOUNDS_FIRST = 21
const COMPOUNDS_LAST = COMPOUNDS_FIRST + COMPOUND_ROWS - 1

const LIST_VALUES = (
    kind = ["Literature", "User"],
    source = [
        "Commercial source",
        "Synthesized by the authors",
        "Other source",
        "Natural source",
        "Standard reference material",
        "Not described",
    ],
    basis = ["mass %", "mole %", "volume %", "unspecified %"],
    analysis = [
        "Stated by supplier",
        "Gas chromatography",
        "Karl Fischer",
        "NMR 1H",
        "HPLC",
        "Estimated by the compiler",
        "Not known",
        "Other",
    ],
    supplier = String[],
    purification = [
        "None used",
        "Fractional distillation",
        "Molecular sieve",
        "Dried by vacuum heating",
        "De-gassed",
        "Crystallization from solution",
        "Other",
    ],
    scale = [
        "Mole fraction",
        "Mass fraction",
        "Molality",
        "Amount concentration",
        "Volume fraction",
        "Not applicable (pure)",
    ],
    phase = [
        "Liquid",
        "Gas",
        "Crystal",
        "Glass",
        "Solution",
        "Ideal gas",
        "Fluid (supercritical or subcritical phases)",
    ],
    method = [
        "Vibrating-tube densimeter",
        "Pycnometer",
        "Capillary viscometer",
        "Rotational viscometer",
        "Transient hot wire",
        "Calorimetry",
        "Other",
    ],
    unitT = ["K", "degC", "degF"],
    unitP = ["kPa", "Pa", "MPa", "bar", "atm", "psi", "mmHg"],
    unitX = ["fraction", "%", "mol/kg", "mol/L", "mol/m3"],
    unctype = ["absolute", "relative (%)"],
)

# ---------------------------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------------------------

struct Painter
    book::Book
end

sid(p::Painter; kwargs...) = style_id!(p.book.styles, make_style(; kwargs...))

label_style(p) =
    sid(p; bold = true, fill = LABEL_FILL, border = :box, wrap = true, valign = :center)
input_style(p; alt = false, halign = :general, numfmt = "") = sid(
    p;
    fill = alt ? INPUT_ALT : INPUT_FILL,
    border = :box,
    wrap = true,
    valign = :center,
    locked = false,
    halign,
    numfmt,
)
calc_style(p; halign = :general, numfmt = "") = sid(
    p;
    fill = CALC_FILL,
    border = :box,
    wrap = true,
    valign = :center,
    color = CALC_FONT,
    halign,
    numfmt,
)
header_style(p) = sid(
    p;
    bold = true,
    color = "FFFFFF",
    fill = NAVY,
    border = :box,
    halign = :center,
    valign = :center,
    wrap = true,
)
note_style(p) =
    sid(p; size = 10.0, color = MUTE, italic = true, wrap = true, valign = :center)

function banner!(
    p::Painter,
    sh::Sheet,
    last_col::Int,
    text::AbstractString,
    height::Real = 34,
)
    s = sid(
        p;
        bold = true,
        size = 22.0,
        color = "FFFFFF",
        fill = NAVY,
        valign = :center,
        indent = 1,
    )
    fill_only = sid(p; fill = NAVY)
    for c = 1:last_col
        setcell!(sh, 1, c, nothing, fill_only)
    end
    setcell!(sh, 1, 1, String(text), s)
    merge_cells!(sh, 1, 1, 1, last_col)
    sh.heights[1] = max(height, 30) + 14
    sh.heights[2] = 7
    colors = (MERCURY, HELIUM, HYDROGEN, NEON)
    for c = 1:last_col
        setcell!(
            sh,
            2,
            c,
            nothing,
            sid(p; fill = colors[min(4, (c - 1) * 4 ÷ last_col + 1)]),
        )
    end
    return nothing
end

function section!(p::Painter, sh::Sheet, row, c1, c2, text; color = HELIUM, ink = "FFFFFF")
    s = sid(
        p;
        bold = true,
        size = 12.0,
        color = ink,
        fill = color,
        valign = :center,
        indent = 1,
    )
    for c = c1:c2
        setcell!(sh, row, c, nothing, s)
    end
    setcell!(sh, row, c1, String(text), s)
    merge_cells!(sh, row, c1, row, c2)
    sh.heights[row] = 22
    return nothing
end

function label!(p::Painter, sh::Sheet, row, col, text; required = false)
    setcell!(sh, row, col, string(text, required ? " *" : ""), label_style(p))
end

# An input cell or a block of them; `hint` shows when the cell is selected.
function input!(
    p::Painter,
    sh::Sheet,
    row,
    c1,
    c2 = c1;
    value = nothing,
    alt = false,
    halign = :general,
    numfmt = "",
)
    s = input_style(p; alt, halign, numfmt)
    for c = c1:c2
        setcell!(sh, row, c, nothing, s)
    end
    setcell!(sh, row, c1, value, s)
    c2 > c1 && merge_cells!(sh, row, c1, row, c2)
    return nothing
end

function calc!(
    p::Painter,
    sh::Sheet,
    row,
    c1,
    c2 = c1,
    value = nothing;
    halign = :general,
    numfmt = "",
)
    s = calc_style(p; halign, numfmt)
    for c = c1:c2
        setcell!(sh, row, c, nothing, s)
    end
    setcell!(sh, row, c1, value, s)
    c2 > c1 && merge_cells!(sh, row, c1, row, c2)
    return nothing
end

formula(text) = Formula(String(text))

function note!(p::Painter, sh::Sheet, row, col, text, c2 = nothing)
    setcell!(sh, row, col, String(text), note_style(p))
    c2 === nothing || merge_cells!(sh, row, col, row, c2)
end

function list_check!(sh, sqref, source; strict = true, hint = "")
    add_validation!(
        sh,
        sqref;
        kind = :list,
        formula1 = source,
        strict,
        title = "Not in the list",
        message = "Pick one of the options of the list.",
        prompt = hint,
    )
end

function number_check!(
    sh,
    sqref;
    minimum = "0",
    message = "A number that is not negative.",
    hint = "",
)
    add_validation!(
        sh,
        sqref;
        kind = :decimal,
        formula1 = minimum,
        operator = "greaterThanOrEqual",
        title = "Number",
        message,
        prompt = hint,
    )
end

function hint!(sh, sqref, title, text)
    add_validation!(sh, sqref; kind = :any, title, prompt = text)
end

error_dxf(p) = dxf_id!(p.book.styles; fill = ERROR_FILL, color = ERROR_FONT, bold = true)
ok_dxf(p) = dxf_id!(p.book.styles; color = OK_FONT, bold = true)
grey_dxf(p) = dxf_id!(p.book.styles; fill = GREY_FILL)

function new_sheet!(p::Painter, name, widths, tab; last_col)
    sh = add_sheet!(p.book, name; tab)
    for (c, w) in widths
        sh.widths[c] = w
    end
    sh.protect = true
    sh.trim_rows = true
    sh.last_col = last_col
    return sh
end

# ---------------------------------------------------------------------------------------------
# The sheets
# ---------------------------------------------------------------------------------------------

# What the databases already use first, then the generic choices that they do not have yet.
function merged_list(key::Symbol, info::TemplateInfo)
    used = haskey(info.lists, key) ? String.(info.lists[key]) : String[]
    seen = Set(lowercase.(used))
    out = copy(used)
    for v in LIST_VALUES[key]
        lowercase(v) in seen && continue
        push!(out, v)
        push!(seen, lowercase(v))
    end
    return out
end

function lists_sheet!(p::Painter, info::TemplateInfo)
    sh = add_sheet!(p.book, "Lists"; tab = MUTE)
    sh.hidden = true
    bold = sid(p; bold = true)
    for (j, key) in enumerate(keys(LIST_VALUES))
        values = merged_list(key, info)
        setcell!(sh, 1, j, String(key), bold)
        sh.widths[j] = 28
        for (i, v) in enumerate(values)
            setcell!(sh, i + 1, j, v)
        end
        define_name!(
            p.book,
            "list_$key",
            "Lists!\$$(column_letters(j))\$2:\$$(column_letters(j))\$$(max(length(values), 1) + 1)",
        )
    end
    return sh
end

function properties_sheet!(p::Painter, info::TemplateInfo)
    sh = new_sheet!(
        p,
        "Properties",
        Dict(1 => 2, 2 => 46, 3 => 20, 4 => 14, 5 => 40),
        MUTE;
        last_col = 5,
    )
    banner!(p, sh, 5, "Properties already in your databases", 30)
    note!(
        p,
        sh,
        3,
        2,
        "Filled by the package when the template is generated. Use the exact label and unit so your points join the property that already exists.",
        5,
    )
    sh.heights[3] = 30
    for (j, h) in enumerate((
        "Property (ThermoML label)",
        "Unit in the databases",
        "Points",
        "Found in",
    ))
        setcell!(sh, 5, j + 1, h, header_style(p))
    end
    rows = max(length(info.properties), 20)
    for i = 1:rows
        row = i + 5
        band = isodd(row) ? BAND_FILL : "FFFFFF"
        for (j, fmt) in enumerate(("", "", "#,##0", ""))
            setcell!(
                sh,
                row,
                j + 1,
                nothing,
                sid(p; fill = band, border = :box, numfmt = fmt),
            )
        end
        if i <= length(info.properties)
            x = info.properties[i]
            fmt_style(j, fmt) = sid(p; fill = band, border = :box, numfmt = fmt)
            setcell!(sh, row, 2, x.label, fmt_style(2, ""))
            setcell!(sh, row, 3, x.unit, fmt_style(3, ""))
            setcell!(sh, row, 4, x.points, fmt_style(4, "#,##0"))
            setcell!(sh, row, 5, x.found_in, fmt_style(5, ""))
        end
    end
    sh.freeze_row = 5
    define_name!(
        p.book,
        "list_property",
        "Properties!\$B\$6:\$B\$$(max(length(info.properties), 1) + 5)",
    )
    define_name!(p.book, "properties_table", "Properties!\$B\$6:\$E\$$(rows + 5)")
    return sh
end

const GUIDE_STEPS = (
    (
        "1",
        "Reference",
        MERCURY,
        "FFFFFF",
        "Where the data come from (DOI, authors) and the list of the compounds of the work with their samples (purity, supplier).",
    ),
    (
        "2",
        "EXP-n",
        NEON,
        NAVY,
        "One sheet per experiment: what was measured, which components (up to 3), how.",
    ),
    (
        "3",
        "PTS-n",
        HELIUM,
        "FFFFFF",
        "The points of that experiment: units and uncertainties above, then composition, T, p and value.",
    ),
    (
        "4",
        "Check",
        SODIUM,
        NAVY,
        "The Reference sheet summarises each experiment (points, status). Fix what is marked in red.",
    ),
    (
        "5",
        "Import",
        HYDROGEN,
        "FFFFFF",
        "In Julia, point the package at the file. Nothing is saved until you ask for it.",
    ),
)

const GUIDE_NOTICES = (
    "Units: write the unit in the unit cell; the package converts to its own (K, kPa, and the unit the databases already use for the property, or the SI when none has it). Temperature uncertainties are differences: 0.1 degC is 0.1 K.",
    "Empty means not given. Nothing is filled in for you, and a point with no temperature is never compared with the points of other databases.",
    "Paste values only (Paste Special > Values). A normal paste overwrites the menus and the checks of the cells.",
    "Do not rename sheets, delete rows or move cells: the package finds them by name. To add experiments, use the package function that adds EXP-n and PTS-n pairs to this file; copying the sheets by hand does not work.",
    "A work with more than 25 compounds: fill a second file with the same reference (same DOI). The package detects it and joins the two.",
    "The same article already in another database is detected after the import (DOI, or first author and year) and you are told which points repeat.",
)

function guide_sheet!(p::Painter, experiments::Int, info::TemplateInfo, logo::Vector{UInt8})
    sh = new_sheet!(
        p,
        "Guide",
        Dict(1 => 2, 2 => 26, 3 => 26, 4 => 26, 5 => 26, 6 => 26),
        NAVY;
        last_col = 6,
    )
    fill_navy = sid(p; fill = NAVY)
    for c = 1:6
        setcell!(sh, 1, c, nothing, fill_navy)
    end
    run(text, size, bold, color) =
        (text, (font = "Calibri", size = Float64(size), bold = bold, color = color))
    setcell!(
        sh,
        1,
        3,
        RichText([
            run("ThermophysicalDB", 30, true, "FFFFFF"),
            run(".jl", 30, true, NEON),
            run(
                "\nData entry template  ·  literature and laboratory measurements",
                15,
                false,
                "9AA3C7",
            ),
        ]),
        sid(p; fill = NAVY, valign = :center, wrap = true, indent = 2),
    )
    merge_cells!(sh, 1, 3, 1, 6)
    sh.heights[1] = 118
    sh.heights[2] = 8
    strip = (MERCURY, HELIUM, HYDROGEN, NEON, SODIUM, XENON)
    for c = 1:6
        setcell!(sh, 2, c, nothing, sid(p; fill = strip[c]))
    end
    sh.image = SheetImage(logo, 0, 1, 132, 120)
    note!(
        p,
        sh,
        3,
        2,
        "Fill the light blue cells, save the file and import it in Julia. Everything is checked before anything enters the database.",
        6,
    )
    sh.heights[3] = 28
    for (j, (_, name, color, ink, _)) in enumerate(GUIDE_STEPS)
        setcell!(
            sh,
            4,
            j + 1,
            name,
            sid(
                p;
                bold = true,
                size = 13.0,
                color = ink,
                fill = color,
                halign = :center,
                valign = :center,
                wrap = true,
            ),
        )
    end
    sh.heights[4] = 30
    section!(p, sh, 5, 2, 6, "How it works")
    for (i, (n, name, color, ink, text)) in enumerate(GUIDE_STEPS)
        row = i + 5
        setcell!(
            sh,
            row,
            2,
            "$n   $name",
            sid(
                p;
                bold = true,
                size = 12.0,
                color = ink,
                fill = color,
                border = :box,
                valign = :center,
                indent = 1,
            ),
        )
        s = sid(
            p;
            fill = iseven(row) ? INPUT_FILL : BAND_FILL,
            border = :box,
            wrap = true,
            valign = :center,
        )
        for c = 3:6
            setcell!(sh, row, c, nothing, s)
        end
        setcell!(sh, row, 3, text, s)
        merge_cells!(sh, row, 3, row, 6)
        sh.heights[row] = 32
    end
    section!(p, sh, 12, 2, 6, "Colours"; color = NEON, ink = NAVY)
    legend = (
        (INPUT_FILL, "Blue: you fill it in"),
        (CALC_FILL, "Grey with slate text: calculated, locked"),
        (LABEL_FILL, "Dark blue label (a * marks what is required)"),
        (ERROR_FILL, "Red: a value that cannot be read or is missing"),
    )
    for (i, (color, text)) in enumerate(legend)
        setcell!(sh, 12 + i, 2, nothing, sid(p; fill = color, border = :box))
        setcell!(sh, 12 + i, 3, text, sid(p))
        merge_cells!(sh, 12 + i, 3, 12 + i, 6)
    end
    section!(p, sh, 18, 2, 6, "Notices"; color = HYDROGEN)
    for (i, text) in enumerate(GUIDE_NOTICES)
        row = 18 + i
        s = sid(
            p;
            size = 10.5,
            wrap = true,
            valign = :center,
            fill = isodd(row) ? "FFF1E8" : "FFF8F3",
            border = :bottom,
        )
        for c = 2:6
            setcell!(sh, row, c, nothing, s)
        end
        setcell!(sh, row, 2, "•  " * text, s)
        merge_cells!(sh, row, 2, row, 6)
        sh.heights[row] = 44
    end
    section!(p, sh, 26, 2, 6, "This template"; color = MERCURY)
    rows = (
        ("package_version", "Package version", info.package_version, ""),
        ("xlsx_version", "XLSX.jl version", string(pkgversion(XLSX)), ""),
        ("julia_version", "Julia version", string(VERSION), ""),
        ("", "ThermoML schema", info.schema, ""),
        ("template_format", "Template format", TEMPLATE_FORMAT, "0"),
        ("generated_at", "Generated at (UTC)", info.generated, ""),
        ("experiment_count", "Experiments", experiments, "0"),
    )
    for (i, (key, name, value, fmt)) in enumerate(rows)
        label!(p, sh, 26 + i, 2, name)
        calc!(p, sh, 26 + i, 3, 4, value; numfmt = fmt, halign = :left)
        isempty(key) || define_name!(p.book, key, "Guide!\$C\$$(26 + i)")
    end
    top = 26 + length(rows) + 2
    section!(p, sh, top, 2, 6, "Databases on this computer"; color = SODIUM, ink = NAVY)
    for (j, h) in enumerate(("Name", "Kind", "Priority", "Points", "Saved"))
        setcell!(sh, top + 1, j + 1, h, header_style(p))
    end
    slots = max(length(info.databases), 6)
    for i = 1:slots
        row = top + 1 + i
        band = isodd(row) ? BAND_FILL : "FFFFFF"
        for (j, fmt) in enumerate(("", "", "", "#,##0", ""))
            setcell!(
                sh,
                row,
                j + 1,
                nothing,
                sid(
                    p;
                    fill = band,
                    border = :box,
                    numfmt = fmt,
                    halign = j in (3, 4) ? :right : :general,
                ),
            )
        end
        if i <= length(info.databases)
            d = info.databases[i]
            values = (d.name, d.kind, d.priority, d.points, d.saved ? "yes" : "no")
            for (j, v) in enumerate(values)
                paint_value!(sh, row, j + 1, v)
            end
        end
    end
    define_name!(p.book, "list_database", "Guide!\$B\$$(top + 2):\$B\$$(top + 1 + slots)")
    define_name!(p.book, "databases_table", "Guide!\$B\$$(top + 2):\$F\$$(top + 1 + slots)")
    note!(
        p,
        sh,
        top + 3 + slots,
        2,
        "Properties already in these databases are on the Properties sheet.",
        6,
    )
    return sh
end

# Writes a value into a cell keeping its style.
function paint_value!(sh::Sheet, row, col, value)
    old = sh.cells[(row, col)]
    sh.cells[(row, col)] = Cell(value, old.style)
    return nothing
end

function reference_sheet!(p::Painter, experiments::Int)
    widths = Dict(
        1 => 5,
        2 => 28,
        3 => 18,
        4 => 26,
        5 => 20,
        6 => 24,
        7 => 11,
        8 => 14,
        9 => 13,
        10 => 13,
        11 => 24,
        12 => 26,
        13 => 30,
    )
    sh = new_sheet!(p, "Reference", widths, HELIUM; last_col = 13)
    banner!(p, sh, 13, "Reference and samples", 34)
    section!(p, sh, 4, 1, 13, "Where the data go")
    function field!(row, text, hint; required = false, c2 = 6, numfmt = "")
        label!(p, sh, row, 1, text; required)
        paint_label_pair!(p, sh, row)
        input!(p, sh, row, 3, c2; numfmt)
        isempty(hint) || hint!(sh, "C$row", text, hint)
    end
    field!(5, "Target database", ""; required = true)
    list_check!(
        sh,
        "C5",
        "list_database";
        strict = false,
        hint = "Pick an existing database or write the name of a new one (letters, digits, - and _).",
    )
    field!(6, "Kind of data", ""; required = true)
    list_check!(
        sh,
        "C6",
        "list_kind";
        hint = "Literature: points taken from articles. User: your own measurements.",
    )
    define_name!(p.book, "target_database", "Reference!\$C\$5")
    define_name!(p.book, "data_kind", "Reference!\$C\$6")
    section!(p, sh, 8, 1, 13, "Reference")
    field!(
        9,
        "DOI",
        "Preferred: the DOI identifies the work. Without it the first author and the year are used.",
    )
    define_name!(p.book, "ref_doi", "Reference!\$C\$9")
    label!(p, sh, 10, 1, "Authors ('Surname, A.')"; required = true)
    paint_label_pair!(p, sh, 10)
    label!(p, sh, 11, 1, "   more authors")
    paint_label_pair!(p, sh, 11)
    for row in (10, 11), col = 3:6
        input!(p, sh, row, col)
    end
    hint!(
        sh,
        "C10:F11",
        "Authors",
        "First author first, one per cell, as 'Surname, A.'. Use the second row for more.",
    )
    define_name!(p.book, "ref_authors", "Reference!\$C\$10:\$F\$11")
    for (i, (text, required, name)) in enumerate((
        ("Title", false, "ref_title"),
        ("Journal", false, "ref_journal"),
        ("Year", true, "ref_year"),
        ("Volume", false, "ref_volume"),
        ("Pages", false, "ref_pages"),
    ))
        row = 11 + i
        field!(row, text, ""; required, numfmt = text == "Year" ? "0" : "")
        define_name!(p.book, name, "Reference!\$C\$$row")
    end
    add_validation!(
        sh,
        "C14";
        kind = :decimal,
        formula1 = "1800",
        formula2 = "2100",
        operator = "between",
        title = "Year",
        message = "A year between 1800 and 2100.",
    )
    field!(
        17,
        "Other information to cite the work",
        "Report number, thesis, website, access date...",
    )
    sh.heights[17] = 40
    define_name!(p.book, "ref_other", "Reference!\$C\$17")

    section!(
        p,
        sh,
        19,
        1,
        13,
        "Compounds and samples of the work (up to $COMPOUND_ROWS; each experiment uses up to 3 of them)",
    )
    columns = (
        ("#", ""),
        ("Name", "comp_name"),
        ("CAS", "comp_cas"),
        ("InChIKey", "comp_inchikey"),
        ("Supplier", "comp_supplier"),
        ("Source", "comp_source"),
        ("Purity", "comp_purity"),
        ("Basis", "comp_basis"),
        ("Purity unc.", "comp_purity_unc"),
        ("Water (mass %)", "comp_water"),
        ("How the purity was checked", "comp_analysis"),
        ("Purification", "comp_purification"),
        ("Notes", "comp_notes"),
    )
    for (j, (h, _)) in enumerate(columns)
        setcell!(sh, 20, j, j == 2 ? "Name *" : h, header_style(p))
    end
    sh.heights[20] = 32
    number_style(alt) = input_style(p; alt)
    for row = COMPOUNDS_FIRST:COMPOUNDS_LAST
        setcell!(
            sh,
            row,
            1,
            formula("IF(B$row<>\"\",ROW()-$(COMPOUNDS_FIRST - 1),\"\")"),
            calc_style(p; halign = :center),
        )
        for col = 2:13
            setcell!(
                sh,
                row,
                col,
                nothing,
                input_style(p; alt = isodd(row - COMPOUNDS_FIRST)),
            )
        end
    end
    for (j, (_, name)) in enumerate(columns)
        isempty(name) || define_name!(
            p.book,
            name,
            "Reference!\$$(column_letters(j))\$$COMPOUNDS_FIRST:\$$(column_letters(j))\$$COMPOUNDS_LAST",
        )
    end
    span(c) = "$c$COMPOUNDS_FIRST:$c$COMPOUNDS_LAST"
    hint!(
        sh,
        span("B"),
        "Name",
        "Common name. With a CAS or an InChIKey the package resolves the compound; a name alone must match the compound database exactly.",
    )
    hint!(
        sh,
        span("C"),
        "CAS",
        "Used to identify the compound when the InChIKey is unknown.",
    )
    hint!(sh, span("D"), "InChIKey", "The identity of the compound when you have it.")
    list_check!(
        sh,
        span("E"),
        "list_supplier";
        strict = false,
        hint = "Pick a supplier that the databases already have, or write yours.",
    )
    list_check!(sh, span("F"), "list_source")
    list_check!(sh, span("H"), "list_basis")
    list_check!(sh, span("K"), "list_analysis")
    list_check!(sh, span("L"), "list_purification")
    number_check!(sh, span("G"); hint = "Number only; the basis goes in the next column.")
    number_check!(sh, span("I"))
    number_check!(sh, span("J"))
    define_name!(
        p.book,
        "list_component",
        "Reference!\$B\$$COMPOUNDS_FIRST:INDEX(Reference!\$B\$$COMPOUNDS_FIRST:\$B\$$COMPOUNDS_LAST,MAX(1,COUNTA(Reference!\$B\$$COMPOUNDS_FIRST:\$B\$$COMPOUNDS_LAST)))",
    )
    bad = error_dxf(p)
    add_format!(
        sh,
        "B$COMPOUNDS_FIRST:B$COMPOUNDS_LAST",
        "AND(B$COMPOUNDS_FIRST=\"\",COUNTA(C$COMPOUNDS_FIRST:M$COMPOUNDS_FIRST)>0)",
        bad,
    )
    note!(
        p,
        sh,
        COMPOUNDS_LAST + 1,
        1,
        "Up to $COMPOUND_ROWS compounds here. A work with more: use a second file with the same reference; the package joins them.",
        13,
    )

    first = COMPOUNDS_LAST + 3
    section!(p, sh, first, 1, 13, "Summary of the experiments (calculated)")
    for (c1, c2, h) in (
        (1, 2, "Experiment"),
        (3, 4, "Property"),
        (5, 6, "Points · components"),
        (7, 11, "Status"),
    )
        for c = c1:c2
            setcell!(sh, first + 1, c, nothing, header_style(p))
        end
        setcell!(sh, first + 1, c1, h, header_style(p))
        merge_cells!(sh, first + 1, c1, first + 1, c2)
    end
    for k = 1:experiments
        row = first + 1 + k
        calc!(
            p,
            sh,
            row,
            1,
            2,
            formula("IF('EXP-$k'!\$C\$5=\"\",\"EXP-$k (no name yet)\",'EXP-$k'!\$C\$5)"),
        )
        calc!(p, sh, row, 3, 4, formula("IF('EXP-$k'!\$C\$6=\"\",\"\",'EXP-$k'!\$C\$6)"))
        calc!(
            p,
            sh,
            row,
            5,
            6,
            formula("'EXP-$k'!\$C\$21&\" points · \"&'EXP-$k'!\$C\$13&\" component(s)\""),
        )
        calc!(p, sh, row, 7, 11, formula("'EXP-$k'!\$C\$22"))
    end
    status = "G$(first + 2):G$(first + 1 + experiments)"
    add_format!(sh, status, "LEFT(G$(first + 2),5)=\"check\"", bad)
    add_format!(sh, status, "G$(first + 2)=\"ok\"", ok_dxf(p))
    return sh
end

# The label cell of a field spans columns A and B.
function paint_label_pair!(p::Painter, sh::Sheet, row)
    setcell!(sh, row, 2, nothing, label_style(p))
    merge_cells!(sh, row, 1, row, 2)
end

function experiment_sheets!(p::Painter, k::Int)
    e = new_sheet!(
        p,
        "EXP-$k",
        Dict(1 => 2, 2 => 40, 3 => 28, 4 => 28, 5 => 28),
        NEON;
        last_col = 5,
    )
    banner!(p, e, 5, "Experiment $k", 34)
    note!(p, e, 3, 2, "Its points are on the sheet PTS-$k.", 5)
    section!(p, e, 4, 2, 5, "What was measured")
    label!(p, e, 5, 2, "Experiment name"; required = true)
    input!(p, e, 5, 3, 5)
    hint!(
        e,
        "C5",
        "Experiment name",
        "A short name, for example 'Density, NaCl(aq), 0.1 MPa'.",
    )
    label!(p, e, 6, 2, "Property measured"; required = true)
    input!(p, e, 6, 3, 5)
    list_check!(
        e,
        "C6",
        "list_property";
        strict = false,
        hint = "Pick the label already in the databases, or type a new one. Its unit is on PTS-$k.",
    )
    label!(p, e, 7, 2, "Phase")
    input!(p, e, 7, 3, 5)
    list_check!(e, "C7", "list_phase"; hint = "The phases that the databases already use.")
    label!(p, e, 8, 2, "Measurement method")
    input!(p, e, 8, 3, 5)
    list_check!(e, "C8", "list_method"; strict = false, hint = "Pick or type your own.")
    label!(p, e, 9, 2, "Purpose of the measurement")
    input!(p, e, 9, 3, 5)
    section!(p, e, 11, 2, 5, "System")
    label!(p, e, 12, 2, "Components (up to 3)"; required = true)
    for c = 3:5
        input!(p, e, 12, c)
    end
    list_check!(
        e,
        "C12:E12",
        "list_component";
        hint = "Pick from the compounds of the Reference sheet, in the order of x1, x2, x3.",
    )
    label!(p, e, 13, 2, "Number of components")
    calc!(p, e, 13, 3, 3, formula("COUNTA(C12:E12)"); numfmt = "0")
    label!(p, e, 14, 2, "Mixture?")
    calc!(p, e, 14, 3, 3, formula("IF(C13>1,\"Yes\",\"No\")"))
    label!(p, e, 15, 2, "Composition scale")
    input!(p, e, 15, 3, 5)
    list_check!(
        e,
        "C15",
        "list_scale";
        hint = "Used when there is more than one component.",
    )
    section!(p, e, 17, 2, 5, "Coverage of the data (calculated from the points)")
    pts = "'PTS-$k'"
    rg(col) = "$(pts)!\$$col\$$POINTS_FIRST:\$$col\$$POINTS_LAST"
    function range_text(col, unit_cell, digits)
        return formula(
            "IF(COUNT($(rg(col)))=0,\"\",ROUND(MIN($(rg(col))),$digits)&\" to \"&ROUND(MAX($(rg(col))),$digits)&IF($(pts)!\$$unit_cell=\"\",\"\",\" \"&$(pts)!\$$unit_cell))",
        )
    end
    label!(p, e, 18, 2, "Temperature range")
    calc!(p, e, 18, 3, 5, range_text("H", "H\$5", 6))
    label!(p, e, 19, 2, "Pressure range")
    calc!(p, e, 19, 3, 5, range_text("J", "J\$5", 6))
    label!(p, e, 20, 2, "Value range")
    calc!(p, e, 20, 3, 5, range_text("L", "L\$5", 6))
    label!(p, e, 21, 2, "Number of points")
    calc!(p, e, 21, 3, 3, formula("COUNT($(rg("A")))"); numfmt = "0")
    label!(p, e, 22, 2, "Status")
    calc!(
        p,
        e,
        22,
        3,
        5,
        formula(
            "IF(C21=0,\"empty\",IF(OR(C5=\"\",C6=\"\",C13=0),\"check: name, property or components missing\",IF(COUNT($(rg("H")))<C21,\"check: some points have no temperature\",IF(COUNT($(rg("L")))<C21,\"check: some points have no value\",\"ok\"))))",
        ),
    )
    add_format!(e, "C22", "LEFT(\$C\$22,5)=\"check\"", error_dxf(p))
    add_format!(e, "C22", "\$C\$22=\"ok\"", ok_dxf(p))
    section!(p, e, 24, 2, 5, "Notes")
    label!(p, e, 25, 2, "Where in the article")
    input!(p, e, 25, 3, 5)
    hint!(e, "C25", "Where in the article", "Table 3, Figure 2, supplementary file...")
    label!(p, e, 26, 2, "Description and notes")
    input!(p, e, 26, 3, 5)
    e.heights[26] = 70
    label!(p, e, 27, 2, "Anything else worth keeping")
    input!(p, e, 27, 3, 5)
    e.heights[27] = 44
    for (key, ref) in (
        ("name", "\$C\$5"),
        ("property", "\$C\$6"),
        ("phase", "\$C\$7"),
        ("method", "\$C\$8"),
        ("purpose", "\$C\$9"),
        ("components", "\$C\$12:\$E\$12"),
        ("scale", "\$C\$15"),
        ("source", "\$C\$25"),
        ("notes", "\$C\$26:\$C\$27"),
    )
        define_name!(p.book, "exp$(k)_$key", "'EXP-$k'!$ref")
    end
    points_sheet!(p, k)
    return nothing
end

const PTS_HEADERS = (
    "#",
    "x1",
    "x2",
    "x3",
    "u(x1)",
    "u(x2)",
    "u(x3)",
    "T",
    "u(T)",
    "P",
    "u(P)",
    "value",
    "u(value)",
    "Note",
)

function points_sheet!(p::Painter, k::Int)
    widths = Dict(
        1 => 11,
        2 => 13,
        3 => 13,
        4 => 13,
        5 => 13,
        6 => 13,
        7 => 13,
        8 => 15,
        9 => 13,
        10 => 15,
        11 => 13,
        12 => 17,
        13 => 15,
        14 => 30,
    )
    q = new_sheet!(p, "PTS-$k", widths, MERCURY; last_col = 14)
    q.landscape = true
    banner!(p, q, 14, "Points of experiment $k", 30)
    e = "'EXP-$k'"
    setcell!(
        q,
        3,
        1,
        formula(
            "\"Experiment: \"&IF($(e)!\$C\$5=\"\",\"(name it on EXP-$k)\",$(e)!\$C\$5)&\"   ·   Property: \"&IF($(e)!\$C\$6=\"\",\"(not chosen)\",$(e)!\$C\$6)&\"   ·   Components: \"&$(e)!\$C\$13",
        ),
        sid(p; bold = true, color = HELIUM, valign = :center, indent = 1),
    )
    merge_cells!(q, 3, 1, 3, 14)
    for (j, h) in enumerate(PTS_HEADERS)
        setcell!(q, 4, j, h, header_style(p))
    end
    q.heights[4] = 22
    side = sid(
        p;
        bold = true,
        size = 10.0,
        fill = LABEL_FILL,
        border = :box,
        halign = :center,
        valign = :center,
        wrap = true,
    )
    for (row, text) in ((5, "unit"), (6, "u given as"), (7, "k"))
        setcell!(q, row, 1, text, side)
    end
    parent = Dict(5 => 2, 6 => 3, 7 => 4, 9 => 8, 11 => 10, 13 => 12)
    quantity = Dict(
        2 => ("list_unitX", "fraction"),
        3 => ("list_unitX", "fraction"),
        4 => ("list_unitX", "fraction"),
        8 => ("list_unitT", "K"),
        10 => ("list_unitP", "kPa"),
        12 => ("", ""),
    )
    for j = 2:14
        if j == 14
            for row in (5, 6, 7)
                setcell!(q, row, j, nothing, calc_style(p))
            end
            continue
        end
        letter = column_letters(j)
        if haskey(quantity, j)
            source, default = quantity[j]
            input!(
                p,
                q,
                5,
                j;
                value = isempty(default) ? nothing : default,
                halign = :center,
            )
            isempty(source) || list_check!(q, "$(letter)5", source; strict = false)
            for row in (6, 7)
                calc!(p, q, row, j, j, "–"; halign = :center)
            end
        else
            pc = column_letters(parent[j])
            calc!(
                p,
                q,
                5,
                j,
                j,
                formula(
                    "IF(LEFT($(letter)6,8)=\"relative\",\"%\",IF($(pc)5=\"\",\"\",$(pc)5))",
                );
                halign = :center,
            )
            input!(p, q, 6, j; value = "absolute", halign = :center)
            list_check!(q, "$(letter)6", "list_unctype")
            input!(p, q, 7, j; value = 2, halign = :center)
        end
    end
    hint!(
        q,
        "L5",
        "Unit of the value",
        "Unit of the measured value, for example kg/m3 or g/cm3. The package converts it to the unit the databases use for this property (the SI when none has it).",
    )
    hint!(
        q,
        "E7",
        "Coverage factor",
        "Coverage factor of the uncertainty: k = 1 standard uncertainty, k = 2 about 95 %. Leave the u(...) column empty when you do not have it.",
    )
    add_validation!(
        q,
        "E7:G7 I7 K7 M7";
        kind = :decimal,
        formula1 = "0",
        operator = "greaterThan",
        title = "Coverage factor",
        message = "k must be a positive number (k = 1: standard uncertainty, k = 2: about 95 %).",
    )
    counter = calc_style(p; halign = :center)
    for row = POINTS_FIRST:POINTS_LAST
        setcell!(
            q,
            row,
            1,
            formula("IF(COUNTA(B$row:N$row)>0,ROW()-$(POINTS_FIRST - 1),\"\")"),
            counter,
        )
        for col = 2:14
            setcell!(q, row, col, nothing, input_style(p; alt = isodd(row - POINTS_FIRST)))
        end
    end
    span(c) = "$c$POINTS_FIRST:$c$POINTS_LAST"
    number_check!(
        q,
        join((span(c) for c in "BCDEFGIKM"), " ");
        message = "x, u(x), u(T), u(P) and u(value) must be numbers that are not negative.",
    )
    add_validation!(
        q,
        join((span(c) for c in "HJL"), " ");
        kind = :decimal,
        formula1 = "-1E+300",
        formula2 = "1E+300",
        operator = "between",
        title = "Number",
        message = "This cell must be a number.",
    )
    bad = error_dxf(p)
    f = POINTS_FIRST
    add_format!(q, "B$f:M$POINTS_LAST", "AND(B$f<>\"\",NOT(ISNUMBER(B$f)))", bad)
    ex = "$(e)!\$C\$13"
    grey = grey_dxf(p)
    for (cols, below) in (
        ("B$f:C$POINTS_LAST", 2),
        ("E$f:F$POINTS_LAST", 2),
        ("D$f:D$POINTS_LAST", 3),
        ("G$f:G$POINTS_LAST", 3),
    )
        add_format!(q, cols, "$ex<$below", grey)
    end
    add_format!(q, "H$f:H$POINTS_LAST", "AND(\$L$f<>\"\",\$H$f=\"\")", bad)
    add_format!(q, "L$f:L$POINTS_LAST", "AND(\$L$f=\"\",COUNTA(\$B$f:\$K$f)>0)", bad)
    q.freeze_row = 7
    define_name!(p.book, "pts$(k)_units", "'PTS-$k'!\$B\$5:\$M\$5")
    define_name!(p.book, "pts$(k)_unc_type", "'PTS-$k'!\$B\$6:\$M\$6")
    define_name!(p.book, "pts$(k)_k", "'PTS-$k'!\$B\$7:\$M\$7")
    define_name!(p.book, "pts$(k)_table", "'PTS-$k'!\$B\$$POINTS_FIRST:\$N\$$POINTS_LAST")
    return nothing
end

"""
    build_template(experiments, info, logo) -> Book

The whole template with `experiments` pairs of EXP-n and PTS-n sheets.
"""
function build_template(experiments::Int, info::TemplateInfo, logo::Vector{UInt8})
    book = Book()
    book.meta["title"] = "ThermophysicalDB.jl data entry template"
    book.meta["creator"] = "ThermophysicalDB.jl " * info.package_version
    book.meta["description"] = string(
        "Template format ",
        TEMPLATE_FORMAT,
        "; ThermophysicalDB.jl ",
        info.package_version,
        "; XLSX.jl ",
        pkgversion(XLSX),
        "; Julia ",
        VERSION,
        "; ThermoML schema ",
        info.schema,
    )
    book.meta["created"] = info.generated
    p = Painter(book)
    guide_sheet!(p, experiments, info, logo)
    reference_sheet!(p, experiments)
    for k = 1:experiments
        experiment_sheets!(p, k)
    end
    properties_sheet!(p, info)
    lists_sheet!(p, info)
    return book
end
