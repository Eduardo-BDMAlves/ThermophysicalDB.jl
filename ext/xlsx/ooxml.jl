# A small writer of OOXML spreadsheets (the `.xlsx` format) for the data entry template.
#
# XLSX.jl writes values, formulas and styles, but not data validation (drop-down lists), conditional
# formatting or sheet protection, which the template needs. An `.xlsx` file is a zip of XML parts, so
# this file writes those parts directly. It knows nothing about the template: `layout.jl` does.
#
# The order of the elements inside a worksheet follows the schema (CT_Worksheet); Excel is strict
# about it where LibreOffice is not.

# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------

function xml_escape(text::AbstractString)
    return replace(
        text,
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        # Characters that XML 1.0 does not allow are dropped.
        r"[\x00-\x08\x0b\x0c\x0e-\x1f]" => "",
    )
end

# The letters of a column, "A" for 1 and "XFD" for 16384, written straight into the bytes of the
# string: a cell reference is built for every cell of a sheet, so it must not go through an
# `IOBuffer` or a vector of characters. A column below 1 has no letters.
function column_letters(n::Integer)
    count = 0
    m = n
    while m > 0
        m = (m - 1) ÷ 26
        count += 1
    end
    bytes = Base.StringVector(count)
    m = n
    for i = count:-1:1
        m, r = divrem(m - 1, 26)
        @inbounds bytes[i] = UInt8('A') + UInt8(r)
    end
    return String(bytes)
end

# The reference of a cell, "B7" (the row is not negative), in one string.
function cell_ref(row::Integer, col::Integer)
    count = 0
    m = col
    while m > 0
        m = (m - 1) ÷ 26
        count += 1
    end
    bytes = Base.StringVector(count + ndigits(row))
    m = col
    for i = count:-1:1
        m, r = divrem(m - 1, 26)
        @inbounds bytes[i] = UInt8('A') + UInt8(r)
    end
    x = row
    for i = length(bytes):-1:(count+1)
        x, d = divrem(x, 10)
        @inbounds bytes[i] = UInt8('0') + UInt8(d)
    end
    return String(bytes)
end
range_ref(r1, c1, r2, c2) = string(cell_ref(r1, c1), ":", cell_ref(r2, c2))

# A formula, as opposed to a text.
struct Formula
    text::String
end

# A text with runs of different fonts: `[(text, font), ...]`.
struct RichText
    runs::Vector{Tuple{String,NamedTuple}}
end

# ---------------------------------------------------------------------------------------------
# Styles
# ---------------------------------------------------------------------------------------------

const STYLE_DEFAULTS = (
    font = "Calibri",
    size = 11.0,
    bold = false,
    italic = false,
    color = "141830",
    fill = "",
    border = :none,   # :none, :box or :bottom
    halign = :general,
    valign = :bottom,
    wrap = false,
    indent = 0,
    numfmt = "",
    locked = true,
)

const BORDER_COLOR = "BFC5DD"

"""
    make_style(; kwargs...)

A style of a cell as a `NamedTuple` with every field set (see `STYLE_DEFAULTS`).
"""
make_style(; kwargs...) = merge(STYLE_DEFAULTS, NamedTuple(kwargs))

# The styles of a workbook: each distinct style gets an index, in the order it is first asked for.
mutable struct StyleBook
    styles::Vector{NamedTuple}
    index::Dict{NamedTuple,Int}
    dxfs::Vector{NamedTuple}
    dxf_index::Dict{NamedTuple,Int}
end

function StyleBook()
    book = StyleBook(
        NamedTuple[],
        Dict{NamedTuple,Int}(),
        NamedTuple[],
        Dict{NamedTuple,Int}(),
    )
    style_id!(book, make_style())   # index 0 is the default style
    return book
end

function style_id!(book::StyleBook, style::NamedTuple)
    return get!(book.index, style) do
        push!(book.styles, style)
        length(book.styles) - 1
    end
end

# The format of a conditional rule: a fill and/or a font colour, and bold.
function dxf_id!(book::StyleBook; fill::String = "", color::String = "", bold::Bool = false)
    key = (; fill, color, bold)
    return get!(book.dxf_index, key) do
        push!(book.dxfs, key)
        length(book.dxfs) - 1
    end
end

argb(hex::AbstractString) = "FF" * uppercase(hex)

function styles_xml(book::StyleBook)
    fonts = unique((s.font, s.size, s.bold, s.italic, s.color) for s in book.styles)
    fills = unique(s.fill for s in book.styles if !isempty(s.fill))
    borders = [:none, :box, :bottom]
    numfmts = unique(s.numfmt for s in book.styles if !isempty(s.numfmt))
    io = IOBuffer()
    print(io, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
    print(
        io,
        "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">",
    )
    if !isempty(numfmts)
        print(io, "<numFmts count=\"", length(numfmts), "\">")
        for (i, code) in enumerate(numfmts)
            print(
                io,
                "<numFmt numFmtId=\"",
                163 + i,
                "\" formatCode=\"",
                xml_escape(code),
                "\"/>",
            )
        end
        print(io, "</numFmts>")
    end
    print(io, "<fonts count=\"", length(fonts), "\">")
    for (name, size, bold, italic, color) in fonts
        print(io, "<font>", bold ? "<b/>" : "", italic ? "<i/>" : "")
        print(io, "<sz val=\"", size, "\"/><color rgb=\"", argb(color), "\"/>")
        print(io, "<name val=\"", xml_escape(name), "\"/></font>")
    end
    print(io, "</fonts>")
    # The first two fills are fixed by the format: none and gray125.
    print(io, "<fills count=\"", length(fills) + 2, "\">")
    print(io, "<fill><patternFill patternType=\"none\"/></fill>")
    print(io, "<fill><patternFill patternType=\"gray125\"/></fill>")
    for color in fills
        print(io, "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"", argb(color))
        print(io, "\"/><bgColor indexed=\"64\"/></patternFill></fill>")
    end
    print(io, "</fills>")
    side(kind) = "<$kind style=\"thin\"><color rgb=\"$(argb(BORDER_COLOR))\"/></$kind>"
    print(io, "<borders count=\"3\">")
    print(io, "<border><left/><right/><top/><bottom/><diagonal/></border>")
    print(
        io,
        "<border>",
        side("left"),
        side("right"),
        side("top"),
        side("bottom"),
        "<diagonal/></border>",
    )
    print(io, "<border><left/><right/><top/>", side("bottom"), "<diagonal/></border>")
    print(io, "</borders>")
    print(
        io,
        "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>",
    )
    print(io, "<cellXfs count=\"", length(book.styles), "\">")
    for s in book.styles
        font = findfirst(==((s.font, s.size, s.bold, s.italic, s.color)), fonts) - 1
        fill = isempty(s.fill) ? 0 : findfirst(==(s.fill), fills) + 1
        border = findfirst(==(s.border), borders) - 1
        numfmt = isempty(s.numfmt) ? 0 : 163 + findfirst(==(s.numfmt), numfmts)
        print(
            io,
            "<xf numFmtId=\"$numfmt\" fontId=\"$font\" fillId=\"$fill\" borderId=\"$border\" xfId=\"0\"",
        )
        print(
            io,
            " applyNumberFormat=\"1\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\"",
        )
        print(io, " applyAlignment=\"1\" applyProtection=\"1\">")
        print(io, "<alignment horizontal=\"", s.halign, "\" vertical=\"", s.valign, "\"")
        print(
            io,
            s.wrap ? " wrapText=\"1\"" : "",
            s.indent > 0 ? " indent=\"$(s.indent)\"" : "",
            "/>",
        )
        print(io, "<protection locked=\"", s.locked ? 1 : 0, "\"/></xf>")
    end
    print(io, "</cellXfs>")
    print(
        io,
        "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>",
    )
    print(io, "<dxfs count=\"", length(book.dxfs), "\">")
    for d in book.dxfs
        print(io, "<dxf>")
        if !isempty(d.color) || d.bold
            print(io, "<font>", d.bold ? "<b/>" : "")
            print(
                io,
                isempty(d.color) ? "" : "<color rgb=\"$(argb(d.color))\"/>",
                "</font>",
            )
        end
        if !isempty(d.fill)
            print(
                io,
                "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"",
                argb(d.fill),
            )
            print(io, "\"/><bgColor rgb=\"", argb(d.fill), "\"/></patternFill></fill>")
        end
        print(io, "</dxf>")
    end
    print(io, "</dxfs></styleSheet>")
    return take!(io)
end

# ---------------------------------------------------------------------------------------------
# Sheets
# ---------------------------------------------------------------------------------------------

struct Cell
    value::Any            # nothing, a String, a Real, a Formula or a RichText
    style::Int
end

# A drop-down list, a number check or only a prompt on some cells.
struct Validation
    sqref::String
    kind::Symbol          # :list, :decimal or :any
    formula1::String
    formula2::String
    operator::String
    strict::Bool
    title::String
    message::String
    prompt::String
end

struct ConditionalFormat
    sqref::String
    formula::String
    dxf::Int
end

struct SheetImage
    png::Vector{UInt8}
    row::Int              # zero based anchor
    col::Int
    width::Int            # in pixels
    height::Int
end

mutable struct Sheet
    name::String
    tab::String
    cells::Dict{Tuple{Int,Int},Cell}
    merges::Vector{String}
    widths::Dict{Int,Float64}
    heights::Dict{Int,Float64}
    last_col::Int                 # the columns after it are hidden (0: none)
    trim_rows::Bool               # the rows after the last one used are hidden
    freeze_row::Int               # rows above it are frozen (0: none)
    protect::Bool
    hidden::Bool
    landscape::Bool
    validations::Vector{Validation}
    formats::Vector{ConditionalFormat}
    image::Union{Nothing,SheetImage}
end

function Sheet(name::AbstractString; tab::AbstractString = "")
    return Sheet(
        String(name),
        String(tab),
        Dict{Tuple{Int,Int},Cell}(),
        String[],
        Dict{Int,Float64}(),
        Dict{Int,Float64}(),
        0,
        false,
        0,
        false,
        false,
        false,
        Validation[],
        ConditionalFormat[],
        nothing,
    )
end

function setcell!(sheet::Sheet, row::Integer, col::Integer, value, style::Int = 0)
    sheet.cells[(Int(row), Int(col))] = Cell(value, style)
    return nothing
end

# Sets the style of a cell without changing its value.
function paint!(sheet::Sheet, row::Integer, col::Integer, style::Int)
    old = get(sheet.cells, (Int(row), Int(col)), nothing)
    sheet.cells[(Int(row), Int(col))] = Cell(old === nothing ? nothing : old.value, style)
    return nothing
end

merge_cells!(sheet::Sheet, r1, c1, r2, c2) = push!(sheet.merges, range_ref(r1, c1, r2, c2))

function add_validation!(
    sheet::Sheet,
    sqref::AbstractString;
    kind::Symbol,
    formula1::AbstractString = "",
    formula2::AbstractString = "",
    operator::AbstractString = "between",
    strict::Bool = true,
    title::AbstractString = "",
    message::AbstractString = "",
    prompt::AbstractString = "",
)
    push!(
        sheet.validations,
        Validation(
            sqref,
            kind,
            formula1,
            formula2,
            operator,
            strict,
            title,
            message,
            prompt,
        ),
    )
    return nothing
end

function add_format!(
    sheet::Sheet,
    sqref::AbstractString,
    formula::AbstractString,
    dxf::Integer,
)
    push!(sheet.formats, ConditionalFormat(sqref, formula, dxf))
    return nothing
end

function number_text(x::Real)
    isfinite(x) || throw(ArgumentError("a cell cannot hold $x"))
    x isa Integer && return string(x)
    return string(Float64(x))
end

function write_cell(io::IO, row::Int, col::Int, cell::Cell)
    ref = cell_ref(row, col)
    v = cell.value
    s = cell.style
    if v === nothing
        print(io, "<c r=\"", ref, "\" s=\"", s, "\"/>")
    elseif v isa Formula
        print(io, "<c r=\"", ref, "\" s=\"", s, "\"><f>", xml_escape(v.text), "</f></c>")
    elseif v isa Real
        print(io, "<c r=\"", ref, "\" s=\"", s, "\"><v>", number_text(v), "</v></c>")
    elseif v isa RichText
        print(io, "<c r=\"", ref, "\" s=\"", s, "\" t=\"inlineStr\"><is>")
        for (text, f) in v.runs
            print(io, "<r><rPr>", f.bold ? "<b/>" : "")
            print(io, "<sz val=\"", f.size, "\"/><color rgb=\"", argb(f.color), "\"/>")
            print(io, "<rFont val=\"", xml_escape(f.font), "\"/></rPr>")
            print(io, "<t xml:space=\"preserve\">", xml_escape(text), "</t></r>")
        end
        print(io, "</is></c>")
    else
        print(
            io,
            "<c r=\"",
            ref,
            "\" s=\"",
            s,
            "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">",
        )
        print(io, xml_escape(String(v)), "</t></is></c>")
    end
    return nothing
end

function validation_xml(io::IO, v::Validation)
    print(io, "<dataValidation type=\"", v.kind === :any ? "none" : v.kind, "\"")
    v.kind === :decimal && print(io, " operator=\"", v.operator, "\"")
    print(io, " allowBlank=\"1\"")
    isempty(v.prompt) || print(
        io,
        " showInputMessage=\"1\" promptTitle=\"",
        xml_escape(first(v.title, 32)),
        "\" prompt=\"",
        xml_escape(first(v.prompt, 255)),
        "\"",
    )
    if v.kind !== :any
        print(
            io,
            " showErrorMessage=\"",
            v.strict ? 1 : 0,
            "\" errorTitle=\"",
            xml_escape(first(v.title, 32)),
            "\" error=\"",
            xml_escape(first(v.message, 255)),
            "\"",
        )
    end
    print(io, " sqref=\"", v.sqref, "\">")
    isempty(v.formula1) || print(io, "<formula1>", xml_escape(v.formula1), "</formula1>")
    isempty(v.formula2) || print(io, "<formula2>", xml_escape(v.formula2), "</formula2>")
    print(io, "</dataValidation>")
    return nothing
end

function sheet_xml(sheet::Sheet, selected::Bool, has_image::Bool)
    io = IOBuffer()
    print(io, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
    print(
        io,
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"",
    )
    print(
        io,
        " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">",
    )
    print(
        io,
        "<sheetPr>",
        isempty(sheet.tab) ? "" : "<tabColor rgb=\"$(argb(sheet.tab))\"/>",
    )
    print(io, "<pageSetUpPr fitToPage=\"1\"/></sheetPr>")
    print(
        io,
        "<sheetViews><sheetView showGridLines=\"0\"",
        selected ? " tabSelected=\"1\"" : "",
        " workbookViewId=\"0\">",
    )
    if sheet.freeze_row > 0
        top = cell_ref(sheet.freeze_row + 1, 1)
        print(
            io,
            "<pane ySplit=\"",
            sheet.freeze_row,
            "\" topLeftCell=\"",
            top,
            "\" activePane=\"bottomLeft\" state=\"frozen\"/>",
        )
        print(
            io,
            "<selection pane=\"bottomLeft\" activeCell=\"",
            top,
            "\" sqref=\"",
            top,
            "\"/>",
        )
    end
    print(io, "</sheetView></sheetViews>")
    last_row = isempty(sheet.cells) ? 1 : maximum(first, keys(sheet.cells))
    last_row = max(last_row, isempty(sheet.heights) ? 1 : maximum(keys(sheet.heights)))
    print(
        io,
        "<sheetFormatPr defaultRowHeight=\"15\"",
        sheet.trim_rows ? " zeroHeight=\"1\"" : "",
        "/>",
    )
    # Columns: the widths, and the hidden block after the last column in use.
    widths = sort!(collect(sheet.widths); by = first)
    if !isempty(widths) || sheet.last_col > 0
        print(io, "<cols>")
        for (c, w) in widths
            print(
                io,
                "<col min=\"",
                c,
                "\" max=\"",
                c,
                "\" width=\"",
                w,
                "\" customWidth=\"1\"/>",
            )
        end
        sheet.last_col > 0 && print(
            io,
            "<col min=\"",
            sheet.last_col + 1,
            "\" max=\"16384\" width=\"9\" hidden=\"1\"/>",
        )
        print(io, "</cols>")
    end
    by_row = Dict{Int,Vector{Int}}()
    for (r, c) in keys(sheet.cells)
        push!(get!(by_row, r, Int[]), c)
    end
    print(io, "<sheetData>")
    rows =
        sheet.trim_rows ? (1:last_row) :
        sort!(collect(union(keys(by_row), keys(sheet.heights))))
    for r in rows
        print(io, "<row r=\"", r, "\"")
        h = get(sheet.heights, r, nothing)
        if h !== nothing
            print(io, " ht=\"", h, "\" customHeight=\"1\"")
        elseif sheet.trim_rows
            print(io, " ht=\"15\" customHeight=\"1\"")
        end
        print(io, ">")
        for c in sort!(get(by_row, r, Int[]))
            write_cell(io, r, c, sheet.cells[(r, c)])
        end
        print(io, "</row>")
    end
    print(io, "</sheetData>")
    if sheet.protect
        print(
            io,
            "<sheetProtection sheet=\"1\" objects=\"1\" scenarios=\"1\" formatCells=\"0\" formatColumns=\"0\" formatRows=\"0\"/>",
        )
    end
    if !isempty(sheet.merges)
        print(io, "<mergeCells count=\"", length(sheet.merges), "\">")
        for m in sheet.merges
            print(io, "<mergeCell ref=\"", m, "\"/>")
        end
        print(io, "</mergeCells>")
    end
    for (priority, f) in enumerate(sheet.formats)
        print(
            io,
            "<conditionalFormatting sqref=\"",
            f.sqref,
            "\"><cfRule type=\"expression\" dxfId=\"",
            f.dxf,
        )
        print(
            io,
            "\" priority=\"",
            priority,
            "\"><formula>",
            xml_escape(f.formula),
            "</formula></cfRule></conditionalFormatting>",
        )
    end
    if !isempty(sheet.validations)
        print(io, "<dataValidations count=\"", length(sheet.validations), "\">")
        for v in sheet.validations
            validation_xml(io, v)
        end
        print(io, "</dataValidations>")
    end
    print(
        io,
        "<pageMargins left=\"0.5\" right=\"0.5\" top=\"0.6\" bottom=\"0.6\" header=\"0.3\" footer=\"0.3\"/>",
    )
    print(
        io,
        "<pageSetup orientation=\"",
        sheet.landscape ? "landscape" : "portrait",
        "\" fitToWidth=\"1\" fitToHeight=\"0\"/>",
    )
    has_image && print(io, "<drawing r:id=\"rId1\"/>")
    print(io, "</worksheet>")
    return take!(io)
end

function drawing_xml(image::SheetImage)
    emu(px) = round(Int, px * 9525)
    return Vector{UInt8}(
        string(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n",
            "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" ",
            "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" ",
            "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">",
            "<xdr:oneCellAnchor><xdr:from><xdr:col>",
            image.col,
            "</xdr:col><xdr:colOff>",
            emu(8),
            "</xdr:colOff><xdr:row>",
            image.row,
            "</xdr:row><xdr:rowOff>",
            emu(6),
            "</xdr:rowOff></xdr:from>",
            "<xdr:ext cx=\"",
            emu(image.width),
            "\" cy=\"",
            emu(image.height),
            "\"/>",
            "<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"2\" name=\"Logo\" descr=\"ThermophysicalDB.jl\"/>",
            "<xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr></xdr:nvPicPr>",
            "<xdr:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>",
            "<xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"",
            emu(image.width),
            "\" cy=\"",
            emu(image.height),
            "\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/>",
            "</xdr:oneCellAnchor></xdr:wsDr>",
        ),
    )
end

# ---------------------------------------------------------------------------------------------
# Workbook
# ---------------------------------------------------------------------------------------------

mutable struct Book
    sheets::Vector{Sheet}
    names::Vector{Tuple{String,String}}     # defined names: (name, reference)
    styles::StyleBook
    meta::Dict{String,String}               # title, creator, description, created (document properties)
end

Book() = Book(Sheet[], Tuple{String,String}[], StyleBook(), Dict{String,String}())

function add_sheet!(book::Book, name::AbstractString; tab::AbstractString = "")
    sheet = Sheet(name; tab)
    push!(book.sheets, sheet)
    return sheet
end

define_name!(book::Book, name::AbstractString, ref::AbstractString) =
    push!(book.names, (String(name), String(ref)))

const XML_HEAD = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
const NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
const NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
const NS_PKG_REL = "http://schemas.openxmlformats.org/package/2006/relationships"

# The parts of the package as `path => bytes`, in the order they are written.
function package_parts(book::Book; title::AbstractString = "")
    parts = Pair{String,Vector{UInt8}}[]
    bytes(s) = Vector{UInt8}(s)
    n = length(book.sheets)
    images = [s.image for s in book.sheets]
    drawn = findall(!isnothing, images)
    content = IOBuffer()
    print(
        content,
        XML_HEAD,
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">",
    )
    print(
        content,
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
    )
    print(content, "<Default Extension=\"xml\" ContentType=\"application/xml\"/>")
    print(content, "<Default Extension=\"png\" ContentType=\"image/png\"/>")
    if !isempty(book.meta)
        print(
            content,
            "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>",
        )
        print(
            content,
            "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>",
        )
    end
    print(
        content,
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>",
    )
    print(
        content,
        "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>",
    )
    for i = 1:n
        print(
            content,
            "<Override PartName=\"/xl/worksheets/sheet$i.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>",
        )
    end
    for (k, _) in enumerate(drawn)
        print(
            content,
            "<Override PartName=\"/xl/drawings/drawing$k.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>",
        )
    end
    print(content, "</Types>")
    push!(parts, "[Content_Types].xml" => take!(content))
    docs =
        isempty(book.meta) ? "" :
        string(
            "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>",
            "<Relationship Id=\"rId3\" Type=\"",
            NS_REL,
            "/extended-properties\" Target=\"docProps/app.xml\"/>",
        )
    push!(
        parts,
        "_rels/.rels" => bytes(
            string(
                XML_HEAD,
                "<Relationships xmlns=\"",
                NS_PKG_REL,
                "\">",
                "<Relationship Id=\"rId1\" Type=\"",
                NS_REL,
                "/officeDocument\" Target=\"xl/workbook.xml\"/>",
                docs,
                "</Relationships>",
            ),
        ),
    )
    if !isempty(book.meta)
        get_meta(k) = xml_escape(get(book.meta, k, ""))
        when = get_meta("created")
        push!(
            parts,
            "docProps/core.xml" => bytes(
                string(
                    XML_HEAD,
                    "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" ",
                    "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" ",
                    "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">",
                    "<dc:title>",
                    get_meta("title"),
                    "</dc:title><dc:creator>",
                    get_meta("creator"),
                    "</dc:creator>",
                    "<dc:description>",
                    get_meta("description"),
                    "</dc:description>",
                    "<dcterms:created xsi:type=\"dcterms:W3CDTF\">",
                    when,
                    "</dcterms:created>",
                    "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">",
                    when,
                    "</dcterms:modified></cp:coreProperties>",
                ),
            ),
        )
        push!(
            parts,
            "docProps/app.xml" => bytes(
                string(
                    XML_HEAD,
                    "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">",
                    "<Application>ThermophysicalDB.jl</Application></Properties>",
                ),
            ),
        )
    end
    wb = IOBuffer()
    print(wb, XML_HEAD, "<workbook xmlns=\"", NS_MAIN, "\" xmlns:r=\"", NS_REL, "\">")
    print(wb, "<bookViews><workbookView activeTab=\"0\"/></bookViews><sheets>")
    for (i, s) in enumerate(book.sheets)
        print(
            wb,
            "<sheet name=\"",
            xml_escape(s.name),
            "\" sheetId=\"",
            i,
            "\"",
            s.hidden ? " state=\"hidden\"" : "",
            " r:id=\"rId",
            i,
            "\"/>",
        )
    end
    print(wb, "</sheets>")
    if !isempty(book.names)
        print(wb, "<definedNames>")
        for (name, ref) in sort(book.names; by = first)
            print(
                wb,
                "<definedName name=\"",
                name,
                "\">",
                xml_escape(ref),
                "</definedName>",
            )
        end
        print(wb, "</definedNames>")
    end
    print(wb, "<calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>")
    push!(parts, "xl/workbook.xml" => take!(wb))
    rels = IOBuffer()
    print(rels, XML_HEAD, "<Relationships xmlns=\"", NS_PKG_REL, "\">")
    for i = 1:n
        print(
            rels,
            "<Relationship Id=\"rId$i\" Type=\"",
            NS_REL,
            "/worksheet\" Target=\"worksheets/sheet$i.xml\"/>",
        )
    end
    print(
        rels,
        "<Relationship Id=\"rId$(n + 1)\" Type=\"",
        NS_REL,
        "/styles\" Target=\"styles.xml\"/></Relationships>",
    )
    push!(parts, "xl/_rels/workbook.xml.rels" => take!(rels))
    push!(parts, "xl/styles.xml" => styles_xml(book.styles))
    for (i, s) in enumerate(book.sheets)
        has_image = s.image !== nothing
        push!(parts, "xl/worksheets/sheet$i.xml" => sheet_xml(s, i == 1, has_image))
        if has_image
            k = findfirst(==(i), drawn)
            push!(
                parts,
                "xl/worksheets/_rels/sheet$i.xml.rels" => bytes(
                    string(
                        XML_HEAD,
                        "<Relationships xmlns=\"",
                        NS_PKG_REL,
                        "\"><Relationship Id=\"rId1\" Type=\"",
                        NS_REL,
                        "/drawing\" Target=\"../drawings/drawing$k.xml\"/></Relationships>",
                    ),
                ),
            )
            push!(parts, "xl/drawings/drawing$k.xml" => drawing_xml(s.image))
            push!(
                parts,
                "xl/drawings/_rels/drawing$k.xml.rels" => bytes(
                    string(
                        XML_HEAD,
                        "<Relationships xmlns=\"",
                        NS_PKG_REL,
                        "\"><Relationship Id=\"rId1\" Type=\"",
                        NS_REL,
                        "/image\" Target=\"../media/image$k.png\"/></Relationships>",
                    ),
                ),
            )
            push!(parts, "xl/media/image$k.png" => s.image.png)
        end
    end
    return parts
end

function write_book(path::AbstractString, book::Book)
    parts = package_parts(book)
    tmp = string(path, ".tmp-", getpid())
    try
        ZipArchives.ZipWriter(tmp) do zip
            for (name, data) in parts
                ZipArchives.zip_newfile(zip, name; compress = true)
                write(zip, data)
            end
        end
        mv(tmp, path; force = true)
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
    return path
end
