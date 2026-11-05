# Credits and versions for the executable examples of the documentation.
#
# Every page that shows data of the ThermoML Archive ends with a folded block that calls
# `credits(views...)`: it lists the articles behind the points of the page and records the
# points in a registry. The page "Data credits" is expanded last (`expandfirst` in make.jl)
# and calls `credits_page()`: every article of the documentation, and the `.bib` of them for
# download. The front page calls `environment()`: the versions of Julia, of the package, of
# the archive and of the packages the examples use, and a file with them for download.
#
# Nothing here is written by hand: when an example or a package changes, the next build
# regenerates the lists. The files for download are written into `public/` of the page
# directory, which VitePress serves as they are.

module DocsCredits

using Base.Docs: HTML
using Dates
using Markdown: htmlesc
using Pkg
using TOML
using ThermophysicalDB
using ThermophysicalDB: DataView, DatabaseView, Dataset, parts

const BIB_FILE = "data-credits.bib"
const VERSIONS_FILE = "versions.toml"

# The DOI resolver is not contacted while the documentation is built, which takes minutes for
# hundreds of articles: the entries it delivered in an earlier run are read from the cache of
# the data directory and the archive fills in the rest. `THERMOPHYSICALDB_DOCS_ONLINE=true`
# asks the resolver for the entries that are not in the cache (for a release).
docs_online() = lowercase(get(ENV, "THERMOPHYSICALDB_DOCS_ONLINE", "false")) == "true"

# Packages that build the site, not the examples: listed in the file for download but not
# in the table of the front page.
const TOOLING = ("Documenter", "DocumenterCitations", "DocumenterVitepress", "LiveServer")

# ----------------------------------------------------------------------------------
# Registry of the points shown in the documentation
# ----------------------------------------------------------------------------------

mutable struct Registry
    dataset::Union{Nothing,Dataset}
    mask::BitVector      # one bit per measurement of the dataset
end

const REGISTRY = Registry(nothing, falses(0))

"Forget every registered selection (a new build starts from nothing)."
function reset!()
    REGISTRY.dataset = nothing
    REGISTRY.mask = falses(0)
    return nothing
end

# Two selections share a dataset when they read the same columns. The columns are compared,
# not the `Dataset` values: a view holds a copy of the (immutable) `Dataset`, and what
# matters is that both copies point at the same arrays.
same_dataset(a::Dataset, b::Dataset) =
    a === b || (
        a.measurements.value === b.measurements.value &&
        a.measurements.experiment === b.measurements.experiment
    )

function dataset_mismatch(a::Dataset, b::Dataset)
    return ArgumentError(
        "the selections come from different datasets " *
        "(measurements $(length(a.measurements)) and $(length(b.measurements)), " *
        "columns $(objectid(a.measurements.value)) and $(objectid(b.measurements.value)))",
    )
end

function check_same_dataset(views)
    ds = first(views).dataset
    for v in views
        same_dataset(v.dataset, ds) || throw(dataset_mismatch(v.dataset, ds))
    end
    return ds
end

# The points of all `views` as one selection, in row order and without repetitions.
function union_view(views)
    isempty(views) && throw(ArgumentError("give at least one selection"))
    ds = check_same_dataset(views)
    mask = falses(length(ds.measurements))
    for view in views, row in view.rows
        @inbounds mask[row] = true
    end
    return DataView(ds, Int32.(findall(mask)))
end

# The selection of a `Database` that has points of one database is used as its `DataView`.
as_view(view::DataView) = view
as_view(view::DatabaseView) = only(parts(view))

function register!(view::DataView)
    if REGISTRY.dataset === nothing
        REGISTRY.dataset = view.dataset
        REGISTRY.mask = falses(length(view.dataset.measurements))
    elseif !same_dataset(REGISTRY.dataset, view.dataset)
        throw(dataset_mismatch(REGISTRY.dataset, view.dataset))
    end
    mask = REGISTRY.mask
    for row in view.rows
        @inbounds mask[row] = true
    end
    return nothing
end

registered_view() =
    REGISTRY.dataset === nothing ? nothing :
    DataView(REGISTRY.dataset, Int32.(findall(REGISTRY.mask)))

# ----------------------------------------------------------------------------------
# HTML pieces. The VitePress writer puts the HTML of a result in a JavaScript template
# literal, so a backslash is written as a character reference; there is no blank line in
# the output, which would end an HTML block.
# ----------------------------------------------------------------------------------

esc(text::AbstractString) = replace(htmlesc(text), "\\" => "&#92;")

function doi_link(doi::AbstractString)
    isempty(doi) && return ""
    return string("<a href=\"https://doi.org/", esc(doi), "\">", esc(doi), "</a>")
end

plural(n::Integer, word::AbstractString) = string(n, ' ', word, n == 1 ? "" : "s")

# One entry per article, from the rows of a `reference_summary` (one per article and
# property): the number of points is added over the properties.
function article_rows(s)
    index = Dict{String,Int}()
    key, doi, citation, points = String[], String[], String[], Int[]
    for i in eachindex(s.key)
        j = get!(index, s.key[i]) do
            push!(key, s.key[i])
            push!(doi, s.doi[i])
            push!(citation, s.citation[i])
            push!(points, 0)
            length(key)
        end
        points[j] += s.n_points[i]
    end
    return (; key, doi, citation, points)
end

function articles_table(rows, order; keys::Bool)
    io = IOBuffer()
    print(io, "<table><thead><tr>")
    keys && print(io, "<th>Key</th>")
    print(
        io,
        "<th>Article</th><th>DOI</th><th style=\"text-align:right\">Points</th></tr></thead><tbody>",
    )
    for i in order
        print(io, "<tr>")
        keys && print(io, "<td><code>", esc(rows.key[i]), "</code></td>")
        print(
            io,
            "<td>",
            esc(rows.citation[i]),
            "</td><td>",
            doi_link(rows.doi[i]),
            "</td>",
        )
        print(io, "<td style=\"text-align:right\">", rows.points[i], "</td></tr>")
    end
    print(io, "</tbody></table>")
    return String(take!(io))
end

# ----------------------------------------------------------------------------------
# The block at the end of a page
# ----------------------------------------------------------------------------------

"""
    credits(views...; top = 8) -> HTML

Register the points of `views` (the selections a page shows) for the page "Data credits"
and describe them: how many points and articles, and a table of the `top` articles with
the most points. The articles come from the metadata of the archive, so no network is
needed.
"""
function credits(views::Union{DataView,DatabaseView}...; top::Integer = 8)
    view = union_view(map(as_view, views))
    register!(view)
    isempty(view) && return HTML("<p>The selections of this page have no points.</p>")
    s = ThermophysicalDB.reference_summary(
        view;
        online = false,
        cache = false,
        include_source = false,
        include_package = false,
        progress = false,
    )
    rows = article_rows(s)
    order = sortperm(rows.points; rev = true)
    shown = order[1:min(top, length(order))]
    io = IOBuffer()
    print(
        io,
        "<p>This page uses <strong>",
        plural(length(view), "point"),
        "</strong> from <strong>",
        plural(length(order), "article"),
        "</strong> of the ThermoML Archive",
        length(order) > length(shown) ? "; the ones with the most points are listed." : ".",
        "</p>",
    )
    print(io, articles_table(rows, shown; keys = false))
    return HTML(String(take!(io)))
end

# ----------------------------------------------------------------------------------
# The page "Data credits"
# ----------------------------------------------------------------------------------

"""
    credits_page(; path = joinpath("public", BIB_FILE), online = docs_online(), cache = true) -> HTML

Every article behind the points registered by `credits`: how many entries are the ones the
DOI resolver delivered and how many come only from the archive, the table of all of them,
and the `.bib` written to `path` with the entries of `ThermophysicalDB.bibtex`. With
`online = false` (the default) the resolver is not contacted: the entries it delivered
earlier are read from the cache and the archive fills in the rest. `cache = false` ignores
the cache.
"""
function credits_page(;
    path::AbstractString = joinpath("public", BIB_FILE),
    online::Bool = docs_online(),
    cache::Bool = true,
)
    view = registered_view()
    view === nothing && return HTML("<p>No page has registered points yet.</p>")
    s = ThermophysicalDB.reference_summary(
        view;
        online,
        cache,
        include_package = false,
        progress = false,
    )
    mkpath(dirname(abspath(path)))
    write(path, ThermophysicalDB.bibtex(s))
    report = getfield(getfield(s, :bibliography), :report)
    rows = article_rows(s)
    order = sortperm(rows.citation)
    io = IOBuffer()
    print(
        io,
        "<p>The examples of this documentation use <strong>",
        plural(length(view), "point"),
        "</strong> from <strong>",
        plural(length(order), "article"),
        "</strong>. ",
    )
    print(
        io,
        plural(report.resolved, "entry"),
        " of the file ",
        report.resolved == 1 ? "is" : "are",
        " the ",
        report.resolved == 1 ? "one" : "ones",
        " delivered by the DOI resolver",
        online ? "" :
        " (read from the cache, as the resolver is not contacted while the documentation is built)",
        " and ",
        length(report.archive_only),
        " come only from the metadata of the archive.",
    )
    @info string(
        "Data credits: ",
        plural(length(order), "article"),
        ", ",
        report.resolved,
        " entries from the DOI resolver (online = ",
        online,
        "), ",
        length(report.archive_only),
        " from the archive alone",
    )
    print(io, "</p>")
    print(io, articles_table(rows, order; keys = true))
    return HTML(String(take!(io)))
end

# ----------------------------------------------------------------------------------
# The versions on the front page
# ----------------------------------------------------------------------------------

# Commit of the repository that holds the package, and whether files are modified.
function git_state(root::AbstractString)
    try
        commit = readchomp(pipeline(`git -C $root rev-parse HEAD`; stderr = devnull))
        changes = readchomp(
            pipeline(
                `git -C $root status --porcelain --untracked-files=no`;
                stderr = devnull,
            ),
        )
        return (; commit, dirty = !isempty(changes))
    catch
        return nothing
    end
end

function archive_manifest()
    try
        return ThermophysicalDB.installed_manifest(ThermophysicalDB.thermoml_dir())
    catch
        return nothing
    end
end

function is_stdlib(uuid)
    try
        return Pkg.Types.is_stdlib(uuid)
    catch
        return false
    end
end

# `name => version` of the direct dependencies of the active environment, split into the
# packages of the examples and the packages that build the site; the standard libraries
# have no version of their own to pin and are marked `nothing`.
function direct_dependencies()
    examples = Pair{String,Union{Nothing,String}}[]
    tooling = Pair{String,Union{Nothing,String}}[]
    for (uuid, info) in Pkg.dependencies()
        info.is_direct_dep || continue
        info.name == "ThermophysicalDB" && continue
        version =
            is_stdlib(uuid) || info.version === nothing ? nothing : string(info.version)
        push!(info.name in TOOLING ? tooling : examples, info.name => version)
    end
    return sort!(examples; by = first), sort!(tooling; by = first)
end

function install_snippet(examples, git, repository)
    io = IOBuffer()
    println(io, "using Pkg")
    println(io, "Pkg.activate(; temp = true)")
    pinned = [p for p in examples if p.second !== nothing]
    if !isempty(pinned)
        println(io, "Pkg.add([")
        for (name, version) in pinned
            println(
                io,
                "    PackageSpec(name = \"",
                name,
                "\", version = \"=",
                version,
                "\"),",
            )
        end
        println(io, "])")
    end
    if git === nothing
        println(io, "Pkg.add(url = \"", repository, "\")")
    else
        println(io, "Pkg.add(url = \"", repository, "\", rev = \"", git.commit, "\")")
    end
    return String(take!(io))
end

"""
    environment(; path = joinpath("public", VERSIONS_FILE)) -> HTML

The versions behind the examples: Julia, this package (with the commit of the repository),
the ThermoML Archive (version and SHA-256) and the packages the examples use, as a table
and as the commands that install them. The same information is written to `path` as a TOML
file, for download. It is read from the active environment, so it is always the one that
built the page.
"""
function environment(; path::AbstractString = joinpath("public", VERSIONS_FILE))
    examples, tooling = direct_dependencies()
    root = pkgdir(ThermophysicalDB)
    git = git_state(root)
    manifest = archive_manifest()
    repository = string(
        get(
            ThermophysicalDB.CFF,
            "repository-code",
            "https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl",
        ),
    )
    version = pkgversion(ThermophysicalDB)

    package = Dict{String,Any}("version" => string(version))
    if git !== nothing
        package["commit"] = git.commit
        package["uncommitted_changes"] = git.dirty
    end
    data = Dict{String,Any}(
        "built" => Dates.format(now(UTC), "yyyy-mm-dd"),
        "julia" => string(VERSION),
        "thermophysicaldb" => package,
        "packages" => Dict{String,Any}(
            n => something(v, "standard library") for (n, v) in examples
        ),
        "documentation_tooling" => Dict{String,Any}(
            n => something(v, "standard library") for (n, v) in tooling
        ),
    )
    if manifest !== nothing
        data["archive"] = Dict{String,Any}(
            "version" => manifest.version,
            "file" => manifest.archive_name,
            "sha256" => manifest.sha256,
            "retrieved" => manifest.retrieved_at,
        )
    end
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        println(io, "# Versions used to build the examples of the documentation.")
        println(
            io,
            "# Generated by docs/make.jl; the commands that install them are on the front page.",
        )
        TOML.print(io, data; sorted = true)
    end

    io = IOBuffer()
    print(io, "<table><thead><tr><th>Component</th><th>Version</th></tr></thead><tbody>")
    row(name, text) = print(io, "<tr><td>", esc(name), "</td><td>", text, "</td></tr>")
    row("Julia", string("<code>", esc(string(VERSION)), "</code>"))
    commit =
        git === nothing ? "" :
        string(
            " (commit <code>",
            esc(first(git.commit, 10)),
            "</code>",
            git.dirty ? ", with uncommitted changes" : "",
            ")",
        )
    row("ThermophysicalDB.jl", string("<code>", esc(string(version)), "</code>", commit))
    if manifest !== nothing
        row(
            "ThermoML Archive",
            string(
                "<code>",
                esc(manifest.version),
                "</code>, SHA-256 <code>",
                esc(first(manifest.sha256, 16)),
                "…</code>",
            ),
        )
    end
    for (name, v) in examples
        row(
            name,
            v === nothing ? "standard library of Julia" :
            string("<code>", esc(v), "</code>"),
        )
    end
    print(io, "</tbody></table>")
    print(
        io,
        "<pre><code>",
        esc(install_snippet(examples, git, repository)),
        "</code></pre>",
    )
    return HTML(String(take!(io)))
end

end # module
