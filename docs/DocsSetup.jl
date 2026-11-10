# Shared plotting setup for the executable examples of the documentation.
#
# Every page starts with a hidden `@setup` block that calls `Main.DocsSetup.activate!()`,
# so all figures use the same colours. They are drawn on a transparent background with
# light text and lines, and the site puts every figure on a dark panel (see style.css).

module DocsSetup

using CairoMakie
using DocumenterVitepress

# DocumenterVitepress ranks PNG above SVG, and a Makie figure offers both, so it would keep
# writing PNG files whatever backend is active. Rank SVG first: the figures are vector files.
DocumenterVitepress.mime_priority(::MIME"image/svg+xml") = 4.5

# Neon palette. The colours are those of gas-discharge tubes: the emission of the noble
# gases (neon, helium, krypton, argon, xenon) and of a few contrasting gases (mercury
# vapour, hydrogen, nitrogen, oxygen, sodium vapour). They follow the colours of the site
# and of the laboratory logo (navy blue and orange): mercury blue (Hg 435.83 nm), helium
# blue (He I 447.15 nm), neon orange (Ne I 614.31 nm) and hydrogen red (H-alpha 656.28 nm).
# The figures sit on a dark panel in both the light and the dark mode of the site (see
# style.css), where these colours read best.
const COLORS = (
    mercury = "#4f6bff",
    helium_blue = "#3347ff",
    neon = "#ff7a1a",
    krypton = "#c8ff4d",
    hydrogen = "#ff2f3f",
    xenon = "#2fe0ff",
    sodium = "#ffb000",
    oxygen = "#58ff7a",
    argon = "#a98bff",
    helium = "#ffd36b",
    nitrogen = "#ff6fae",
)

# Order of the colour cycle: neighbouring colours differ in hue and brightness, and the
# yellow and the green, which are hard to tell apart in red-green colour blindness, are far
# apart. Blue and orange (the safest pair for colour blindness) come first.
const CYCLE = [
    COLORS.mercury,
    COLORS.neon,
    COLORS.xenon,
    COLORS.helium,
    COLORS.hydrogen,
    COLORS.krypton,
    COLORS.argon,
    COLORS.oxygen,
]

# Colormap for continuous colours (scatter points coloured by temperature, deviation maps,
# fields): cold to hot, from helium blue and mercury blue through a white midpoint to neon
# orange and hydrogen red. Blue against orange stays distinguishable in the usual forms of
# colour blindness. The bright midpoint marks zero in diverging data (no deviation) and
# reads well on the dark panel. Temperature-like and signed quantities use it; positive
# means hotter or larger.
const FIELD =
    cgrad([COLORS.helium_blue, "#6f8cff", "#f2f5ff", COLORS.neon, COLORS.hydrogen])

# Light grey-blue for text, ticks and spines: legible on the dark panel.
const NEUTRAL = "#9aa3c7"

const THEME = Theme(;
    fontsize = 15,
    backgroundcolor = :transparent,
    textcolor = NEUTRAL,
    linecolor = NEUTRAL,
    colormap = FIELD,
    palette = (
        color = CYCLE,
        marker = [:circle, :utriangle, :rect, :diamond, :dtriangle, :star5],
    ),
    Axis = (
        backgroundcolor = :transparent,
        xgridcolor = (NEUTRAL, 0.16),
        ygridcolor = (NEUTRAL, 0.16),
        topspinevisible = false,
        rightspinevisible = false,
        xtickcolor = NEUTRAL,
        ytickcolor = NEUTRAL,
        bottomspinecolor = NEUTRAL,
        leftspinecolor = NEUTRAL,
        xlabelcolor = NEUTRAL,
        ylabelcolor = NEUTRAL,
        xticklabelcolor = NEUTRAL,
        yticklabelcolor = NEUTRAL,
        titlecolor = NEUTRAL,
    ),
    Legend = (framevisible = false, labelcolor = NEUTRAL, titlecolor = NEUTRAL),
    Colorbar = (
        labelcolor = NEUTRAL,
        ticklabelcolor = NEUTRAL,
        tickcolor = NEUTRAL,
        spinewidth = 0,
    ),
)

"""
    year_scale(years) -> NamedTuple

Keyword arguments (`colormap`, `colorrange`) that colour points by publication year with
one discrete colour per year, sampled from [`FIELD`](@ref). Each year is a band of its own
(the range is widened by half a year on each side), so a colour in the plot can be matched
to a year in the colour bar. Use it as `scatter!(...; color = years, year_scale(years)...)`.
"""
function year_scale(years)
    first_year, last_year = floor(Int, minimum(years)), ceil(Int, maximum(years))
    n = last_year - first_year + 1
    colors = [FIELD[(i-1)/max(n-1, 1)] for i = 1:n]
    return (
        colormap = cgrad(colors; categorical = true),
        colorrange = (first_year - 0.5, last_year + 0.5),
    )
end

"""
    year_ticks(years)

Decades inside the range of `years`: the ticks of the colour bar of [`year_scale`](@ref).
They sit at the centre of the band of that year.
"""
function year_ticks(years)
    first_year, last_year = floor(Int, minimum(years)), ceil(Int, maximum(years))
    return (10*cld(first_year, 10)):10:last_year
end

"""
    activate!()

Select the SVG backend of CairoMakie (vector figures stay sharp at any zoom and on
high-density screens) and apply the theme of the documentation.
"""
function activate!()
    CairoMakie.activate!(; type = "svg")
    set_theme!(THEME)
    return nothing
end

end # module
