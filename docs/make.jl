# Build the documentation.
#
#   julia --project=docs docs/make.jl
#
# The tutorials execute real code against the NIST/TRC ThermoML Archive, so the first
# build downloads and parses the archive (a few minutes; it is cached afterwards). To
# build the pages without running any example, for instance while editing text:
#
#   THERMOPHYSICALDB_DOCS_DRAFT=true julia --project=docs docs/make.jl

using Documenter
using DocumenterCitations
using DocumenterVitepress
using ThermophysicalDB

include("DocsSetup.jl")
include("DocsCredits.jl")
include("SchemaDiagrams.jl")

DocMeta.setdocmeta!(
    ThermophysicalDB,
    :DocTestSetup,
    :(using ThermophysicalDB);
    recursive = true,
)

# DocumenterVitepress runs `npm` from NodeJS_20_jll, but the install scripts of some npm
# packages (esbuild) call `node` through the PATH. When no system Node.js is installed
# that call fails, so the directory of the bundled Node.js is put on the PATH here.
if Sys.which("node") === nothing
    try
        node_dir = dirname(DocumenterVitepress.NodeJS_20_jll.npm_path)
        ENV["PATH"] = string(node_dir, Sys.iswindows() ? ';' : ':', ENV["PATH"])
    catch err
        @warn "Could not expose the bundled Node.js on the PATH; install Node.js (LTS) instead." exception =
            err
    end
end

const DRAFT = get(ENV, "THERMOPHYSICALDB_DOCS_DRAFT", "false") == "true"

# Add titles of sections and overrides page titles
const titles = Dict(
    "20-tutorials" => "Tutorials",
    "30-manual" => "Manual",
    "40-about-data.md" => "Data",
    "90-contributing.md" => "Contributing",
    "91-developer.md" => "Developer docs",
)

# Pages that share one drop-down menu of the navigation bar, in the order of the menu. Without
# the groups the bar has too many entries and pushes the colour-mode switch off the screen.
const NAV_GROUPS = [
    "Project" => ["90-contributing.md", "91-developer.md", "92-roadmap.md"],
    "Reference" => ["95-reference.md", "96-data-credits.md", "99-bibliography.md"],
]

function recursively_list_pages(folder; path_prefix = "")
    pages_list = Any[]
    for file in readdir(folder)
        if file == "index.md"
            # We add index.md separately to make sure it is the first in the list
            continue
        end
        # this is the relative path according to our prefix, not @__DIR__, i.e., relative to `src`
        relpath = joinpath(path_prefix, file)
        # full path of the file
        fullpath = joinpath(folder, relpath)

        if isdir(fullpath)
            # If this is a folder, enter the recursion case
            subsection = recursively_list_pages(fullpath; path_prefix = relpath)

            # Ignore empty folders
            if length(subsection) > 0
                title = if haskey(titles, relpath)
                    titles[relpath]
                else
                    @error "Bad usage: '$relpath' does not have a title set. Fix in 'docs/make.jl'"
                    relpath
                end
                push!(pages_list, title => subsection)
            end

            continue
        end

        if splitext(file)[2] != ".md" # non .md files are ignored
            continue
        elseif haskey(titles, relpath) # case 'title => path'
            push!(pages_list, titles[relpath] => relpath)
        else # case 'title'
            push!(pages_list, relpath)
        end
    end

    return pages_list
end

# Path of a page entry (`"path"` or `"title" => "path"`); `nothing` for a section
entry_path(entry::AbstractString) = String(entry)
entry_path(entry::Pair) = entry.second isa AbstractString ? String(entry.second) : nothing

# Replace the pages listed in `NAV_GROUPS` by one `group title => [pages]` entry, placed where
# the first page of the group was.
function group_pages(pages_list)
    entries = Dict{String,Any}()
    for entry in pages_list
        path = entry_path(entry)
        path === nothing || (entries[path] = entry)
    end
    grouped = Any[]
    emitted = Set{String}()
    for entry in pages_list
        path = entry_path(entry)
        index = path === nothing ? nothing : findfirst(g -> path in g.second, NAV_GROUPS)
        if index === nothing
            push!(grouped, entry)
        elseif !(NAV_GROUPS[index].first in emitted)
            group_title, members = NAV_GROUPS[index]
            push!(emitted, group_title)
            push!(
                grouped,
                group_title => Any[entries[m] for m in members if haskey(entries, m)],
            )
        end
    end
    return grouped
end

function list_pages()
    root_dir = joinpath(@__DIR__, "src")
    pages_list = group_pages(recursively_list_pages(root_dir))

    return ["index.md"; pages_list]
end

# Every page of the navigation, as the path it is listed with.
page_paths(entry::AbstractString) = [String(entry)]
page_paths(entry::Pair) = page_paths(entry.second)
page_paths(entries::AbstractVector) = reduce(vcat, page_paths.(entries); init = String[])

# The pages show data and register it with `DocsCredits.credits`, in the order in which their
# examples run. The page of credits lists everything that was registered, so it has to be
# expanded last: Documenter expands the `expandfirst` pages in the order given and the others
# afterwards, and the other pages are all the ones that are not the page of credits.
const CREDITS_PAGE = "96-data-credits.md"
const NAVIGATION = list_pages()
CREDITS_PAGE in page_paths(NAVIGATION) || error("$CREDITS_PAGE is not in the navigation")
const EXPAND_FIRST = filter(!=(CREDITS_PAGE), page_paths(NAVIGATION))

# Bibliography, cited from any page as [key](@cite). The sources of the data and the articles
# about them are written once, in CITATION.cff; docs/src/refs.bib (not in git) is generated
# from it, followed by the literature of docs/src/refs-literature.bib.
const BIB_FILE = joinpath(@__DIR__, "src", "refs.bib")
ThermophysicalDB.write_documentation_bibliography(
    BIB_FILE;
    extra = joinpath(@__DIR__, "src", "refs-literature.bib"),
)
const BIB = CitationBibliography(BIB_FILE; style = :authoryear)

makedocs(;
    modules = [ThermophysicalDB],
    authors = "Eduardo Bader Dalfovo Mohr Alves <eduardo.alves@polo.ufsc.br>",
    repo = Documenter.Remotes.GitHub("Eduardo-BDMAlves", "ThermophysicalDB.jl"),
    sitename = "ThermophysicalDB.jl",
    format = DocumenterVitepress.MarkdownVitepress(;
        repo = "github.com/Eduardo-BDMAlves/ThermophysicalDB.jl",
        devbranch = "main",
        devurl = "dev",
        description = "Experimental thermophysical property data from the NIST/TRC ThermoML Archive, ready to filter, plot and analyse in Julia.",
    ),
    pages = NAVIGATION,
    expandfirst = EXPAND_FIRST,
    plugins = [BIB],
    draft = DRAFT,
    checkdocs = :exports,
    warnonly = [:missing_docs, :cross_references, :autodocs_block],
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/Eduardo-BDMAlves/ThermophysicalDB.jl",
    devbranch = "main",
    push_preview = true,
)
