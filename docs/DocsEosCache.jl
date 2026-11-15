# Cache for the cells of the tutorials that are slow only because of the packages they call.
#
# The pages of the equations of state call Clapeyron.jl, and compiling its solvers takes more
# than two minutes of every documentation build. The code of those cells is written in the page
# as plain ```julia blocks, so it is shown but not executed. A hidden `@setup` block that follows
# each of them calls `DocsEosCache.provide!`, which puts the results of the cell in the page:
#
#   - from the cache file when it is current, without loading Clapeyron at all;
#   - otherwise by running the blocks of the page itself (the code the reader sees is the code
#     that computes the numbers) and writing the cache again.
#
# The cache of a cell is current when three things are the same as when it was written: the text
# of the blocks up to that cell, the version of Clapeyron in the Manifest of the documentation,
# and the values of the inputs of the cell (the selected points), so a new archive, an edit of
# the page and an update of Clapeyron each refresh it. THERMOPHYSICALDB_DOCS_REFRESH=true
# refreshes it by force. The file is a build product (`*.jld2` is ignored by git).

module DocsEosCache

using JLD2
using Pkg
using SHA
using Unitful

const DOCS = dirname(@__FILE__)
const CACHE = joinpath(DOCS, "cache", "eos-comparison.jld2")

# How many blocks of the page were already run in the sandbox module of the page.
const RUN = Dict{Module,Int}()

# Version of a package of the active environment, without loading the package. Pkg reads the
# Manifest wherever it is (next to the project, or at the root of a workspace).
function dependency_version(name::AbstractString)
    try
        for info in values(Pkg.dependencies())
            info.name == name || continue
            return string(
                info.version === nothing ? "dev" : info.version,
                "/",
                something(info.tree_hash, ""),
            )
        end
    catch err
        @warn "Could not read the version of $name from the environment" exception = err
    end
    return "unknown"
end

# The plain ```julia blocks of a page (the ones Documenter shows and does not run), in order.
function code_blocks(text::AbstractString)
    text = replace(text, "\r\n" => "\n")
    return String[
        m.captures[1] for m in eachmatch(r"^```julia[ \t]*\n(.*?)^```[ \t]*$"ms, text)
    ]
end

# A variable of the sandbox module, also one that was defined after this function started.
variable(mod::Module, name::Symbol) = Base.invokelatest(getglobal, mod, name)

# The values of an input as numbers (a column of a table has units, a year has none).
numbers(x::Number) = Float64[ustrip(x)]
numbers(x) = Float64[ustrip(y) for y in x]

function fingerprint(version::AbstractString, blocks, inputs)
    context = SHA.SHA256_CTX()
    SHA.update!(context, codeunits(version))
    for block in blocks
        SHA.update!(context, codeunits(block))
        SHA.update!(context, UInt8[0])
    end
    for values in inputs
        SHA.update!(context, reinterpret(UInt8, values))
        SHA.update!(context, UInt8[0])
    end
    return bytes2hex(SHA.digest!(context))
end

# A result as plain numbers in `unit`, and back. A result can be a number, a vector, a tuple or a
# named tuple of them, nested at will. A single unit applies to everything inside; a named tuple of
# units with the same names as a named tuple of results gives one unit to each field. A model that
# did not converge gives a `NaN` without unit.
pack(x::Unitful.AbstractQuantity, unit) = Float64(ustrip(unit, x))
pack(x::Real, unit) = Float64(x)
pack(x::AbstractVector, unit) = Float64[pack(y, unit) for y in x]
pack(x::Tuple, unit) = map(v -> pack(v, unit), x)
pack(x::NamedTuple, unit) = map(v -> pack(v, unit), x)
pack(x::NamedTuple, unit::NamedTuple) =
    keys(x) == keys(unit) ? map(pack, x, unit) : map(v -> pack(v, unit), x)

unpack(x::Float64, unit) = x * unit
unpack(x::Vector{Float64}, unit) = x .* unit
unpack(x::Tuple, unit) = map(v -> unpack(v, unit), x)
unpack(x::NamedTuple, unit) = map(v -> unpack(v, unit), x)
unpack(x::NamedTuple, unit::NamedTuple) =
    keys(x) == keys(unit) ? map(unpack, x, unit) : map(v -> unpack(v, unit), x)

function read_store()
    isfile(CACHE) || return Dict{String,Any}()
    try
        return JLD2.jldopen(CACHE, "r") do file
            Dict{String,Any}(name => file[name] for name in keys(file))
        end
    catch err
        @warn "The cache of the documentation could not be read; it is made again." CACHE exception =
            err
        return Dict{String,Any}()
    end
end

function write_store(store::Dict{String,Any})
    mkpath(dirname(CACHE))
    part = CACHE * ".part"
    JLD2.jldopen(part, "w") do file
        for (name, entry) in store
            file[name] = entry
        end
    end
    mv(part, CACHE; force = true)
    return nothing
end

# Run the blocks of the page that this sandbox has not run yet, up to block number `upto`.
function run_blocks!(mod::Module, page::AbstractString, blocks, upto::Integer)
    for i = (get(RUN, mod, 0)+1):upto
        include_string(mod, blocks[i], "$page (code block $i)")
        RUN[mod] = i
    end
    return nothing
end

"""
    provide!(mod, page; key, block, needle, inputs, results)

Define in the sandbox module `mod` of the page `page` (a path relative to `docs/src`) the
variables of `results`, a named tuple `name = unit` of the variables that the plain code block
number `block` computes. `needle` is a text that the block contains (a guard against a block
that moved), `inputs` are the names of the variables of the page that the block reads, and `key`
names the entry of the cache.
"""
function provide!(
    mod::Module,
    page::AbstractString;
    key::AbstractString,
    block::Integer,
    needle::AbstractString,
    inputs::Tuple,
    results::NamedTuple,
)
    blocks = code_blocks(read(joinpath(DOCS, "src", page), String))
    1 <= block <= length(blocks) ||
        error("$page has $(length(blocks)) plain code blocks, not $block")
    occursin(needle, blocks[block]) ||
        error("code block $block of $page does not contain \"$needle\"; update the call")
    version = dependency_version("Clapeyron")
    current = fingerprint(
        version,
        view(blocks, 1:block),
        [numbers(variable(mod, name)) for name in inputs],
    )
    store = read_store()
    entry = get(store, key, nothing)
    refresh = get(ENV, "THERMOPHYSICALDB_DOCS_REFRESH", "false") == "true"
    if refresh || entry === nothing || entry.fingerprint != current
        @info "Computing \"$key\" with Clapeyron $version (the cache is missing or out of date)"
        elapsed = @elapsed run_blocks!(mod, page, blocks, block)
        packed = map(name -> pack(variable(mod, name), results[name]), keys(results))
        entry = (; fingerprint = current, values = NamedTuple{keys(results)}(packed))
        store[key] = entry
        write_store(store)
        @info "\"$key\" computed and saved in $(round(elapsed; digits = 1)) s"
    end
    for (name, unit) in pairs(results)
        Core.eval(mod, Expr(:(=), name, unpack(getfield(entry.values, name), unit)))
    end
    return nothing
end

end # module
