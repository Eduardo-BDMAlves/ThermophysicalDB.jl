# Shared plotting setup for the executable examples of the documentation.
#
# Every page starts with a hidden `@setup` block that calls `Main.DocsSetup.activate!()`,
# so all figures use the same colours. They are drawn on a transparent background with
# light text and lines, and the site puts every figure on a dark panel (see style.css).

module DocsSetup

using CairoMakie

# Neon palette, matching the colours of the site (docs/src/.vitepress/theme). The figures
# sit on a dark panel in both the light and the dark mode of the site, where these
# colours read best.
const COLORS = (
    cyan = "#00e5ff",
    magenta = "#ff2bd6",
    lime = "#b8ff00",
    yellow = "#ffe600",
    orange = "#ff8a00",
    violet = "#9b5cff",
    green = "#39ff88",
    pink = "#ff4d8d",
)

const CYCLE = [
    COLORS.cyan,
    COLORS.magenta,
    COLORS.lime,
    COLORS.yellow,
    COLORS.orange,
    COLORS.violet,
    COLORS.green,
    COLORS.pink,
]

# Colormap for continuous colours: scatter points coloured by year or pressure, and
# fields (heatmaps, contours). It is the reverse of `:managua`.
const FIELD = Reverse(:managua)

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
