# Shared plotting setup for the executable examples of the documentation.
#
# Every page starts with a hidden `@setup` block that calls `Main.DocsSetup.activate!()`,
# so all figures use the same colours. They are drawn on a transparent background with
# light text and lines, and the site puts every figure on a dark panel (see style.css).

module DocsSetup

using CairoMakie

# Neon palette. The colours are those of gas-discharge tubes: the emission of the noble
# gases (neon, helium, krypton, argon, xenon) and of a few contrasting gases (mercury
# vapour, hydrogen, nitrogen, oxygen, sodium vapour). The figures sit on a dark panel in
# both the light and the dark mode of the site (see style.css), where these colours read
# best.
const COLORS = (
    mercury = "#2fe0ff",
    neon = "#ff4a1c",
    krypton = "#c8ff4d",
    hydrogen = "#ff4fd0",
    xenon = "#5c8dff",
    sodium = "#ffb000",
    oxygen = "#58ff7a",
    argon = "#a98bff",
    helium = "#ffd36b",
    nitrogen = "#ff6fae",
)

# Order of the colour cycle: neighbouring colours differ in hue and brightness.
# Warm colours (neon, helium, sodium) come early, since this is thermodynamics; mercury
# and xenon keep the cold side.
const CYCLE = [
    COLORS.mercury,
    COLORS.neon,
    COLORS.helium,
    COLORS.xenon,
    COLORS.sodium,
    COLORS.krypton,
    COLORS.hydrogen,
    COLORS.oxygen,
]

# Colormap for continuous colours (scatter points coloured by temperature, deviation maps,
# fields): cold to hot, from blue through cyan and a white midpoint to amber and red. The
# bright midpoint marks zero in diverging data (no deviation) and reads well on the dark
# panel. Temperature-like and signed quantities use it; positive means hotter or larger.
const FIELD = cgrad(["#3b6bff", "#2fe0ff", "#f2f5ff", "#ffb000", "#ff3a14"])

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
    activate!()

Select the PNG backend of CairoMakie (twice the resolution, so figures stay sharp on
high-density screens) and apply the theme of the documentation.
"""
function activate!()
    CairoMakie.activate!(; type = "png", px_per_unit = 2.0)
    set_theme!(THEME)
    return nothing
end

end # module
