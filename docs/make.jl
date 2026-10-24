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
using DocumenterVitepress
using ThermophysicalDB

include("DocsSetup.jl")

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
    "91-developer.md" => "Developer docs",
)

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

function list_pages()
    root_dir = joinpath(@__DIR__, "src")
    pages_list = recursively_list_pages(root_dir)

    return ["index.md"; pages_list]
end

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
    pages = list_pages(),
    draft = DRAFT,
    checkdocs = :exports,
    warnonly = [:missing_docs, :cross_references, :autodocs_block],
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/Eduardo-BDMAlves/ThermophysicalDB.jl",
    devbranch = "main",
    push_preview = true,
)
