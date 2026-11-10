# Where the starting list of compounds comes from.
#
# The identifiers of about 76 000 compounds (names, CAS number, PubChem CID, formula,
# molar mass, SMILES, InChI, InChIKey) are tab-separated lists published in the repository
# CalebBell/chemicals (MIT licence), which in turn takes them from PubChem. They are not part
# of this package: they are downloaded once, from a fixed commit so that everybody gets the
# same data, and each file is checked against its SHA-256 digest before it is used.

const CHEMICALS_REPOSITORY = "https://github.com/CalebBell/chemicals"
const CHEMICALS_RAW_URL = "https://raw.githubusercontent.com/CalebBell/chemicals"
const CHEMICALS_LICENSE = "MIT"
const CHEMICALS_COMMIT = "e79047588b30cfabc564c79fb26d760c746877d7"
const CHEMICALS_FOLDER = "chemicals/Identifiers"

"One file of the seed: its name in the repository, its SHA-256 digest and the label that is kept with each record."
struct SeedFile
    name::String
    sha256::String
    source::String
end

"""
    CompoundSeed(repository, commit, folder, files)

The files that the compound database is built from, and where to get them. The default,
`CHEMICALS_SEED`, points at a fixed commit of CalebBell/chemicals.
"""
struct CompoundSeed
    repository::String
    raw_url::String
    commit::String
    folder::String
    files::Vector{SeedFile}
end

const CHEMICALS_SEED = CompoundSeed(
    CHEMICALS_REPOSITORY,
    CHEMICALS_RAW_URL,
    CHEMICALS_COMMIT,
    CHEMICALS_FOLDER,
    [
        SeedFile(
            "chemical identifiers pubchem large.tsv",
            "3b9aac5ae8d270bafc9e72a6af5441ce580f0ce444d1dee48dc37e47474b91fc",
            "chemicals:pubchem-large",
        ),
        SeedFile(
            "chemical identifiers pubchem small.tsv",
            "9afa9def322716bc9360e21d1833724e4395897ef02cffa170dddb136b3e6af7",
            "chemicals:pubchem-small",
        ),
        SeedFile(
            "chemical identifiers example user db.tsv",
            "4ebccb034b0ad9b4bba66d194df1b8d2c62d12303a126588dc7dfb4280df25aa",
            "chemicals:example",
        ),
        SeedFile(
            "Cation db.tsv",
            "4c45749d2522b99c83d88a1e2965e79dc9223db8d81654fabe415f97b557660c",
            "chemicals:cations",
        ),
        SeedFile(
            "Anion db.tsv",
            "92b05dda5fcf57342be6f56fa06068fbd5e42bda22840760825f3ce360ea16b9",
            "chemicals:anions",
        ),
        SeedFile(
            "Inorganic db.tsv",
            "05e38f7ec8fa928e2d819ad744dac2931e78e9ae0781bf8ee03f2b3367305bce",
            "chemicals:inorganic",
        ),
    ],
)

# The URL of a file at the pinned commit (spaces in the name are percent-encoded).
function seed_url(seed::CompoundSeed, file::SeedFile)
    name = replace(file.name, " " => "%20")
    return string(seed.raw_url, "/", seed.commit, "/", seed.folder, "/", name)
end

seed_path(dir::AbstractString, file::SeedFile) = joinpath(dir, "seed", file.name)

# What to tell the user when the download fails.
function seed_help(seed::CompoundSeed, dir::AbstractString)
    return String[
        "  2. Download the files in a browser from",
        "     $(seed.repository)/tree/$(seed.commit)/$(seed.folder)",
        "     and copy them, with the same names, into $(joinpath(dir, "seed")); then call",
        "     compound_database() again.",
    ]
end

"""
    ensure_seed_files(seed, dir; progress = true, download = download_file) -> Vector{String}

Make sure every file of `seed` is in `dir/seed` with the expected digest, downloading the
missing or different ones, and return their paths. A file is written to a `.part` file,
verified, and only then moved into place.
"""
function ensure_seed_files(
    seed::CompoundSeed,
    dir::AbstractString;
    progress::Bool = true,
    download = download_file,
)
    paths = String[]
    for file in seed.files
        path = seed_path(dir, file)
        if !(isfile(path) && file_sha256(path) == lowercase(file.sha256))
            mkpath(dirname(path))
            part = path * ".part"
            try
                @info "Downloading the list of compounds ($(file.name))"
                try
                    download(seed_url(seed, file), part; progress)
                catch err
                    err isa DownloadError || rethrow()
                    throw(DownloadError(err.url, err.failures, seed_help(seed, dir)))
                end
                verify_sha256(part, file.sha256)
                mv(part, path; force = true)
            finally
                rm(part; force = true)
            end
        end
        push!(paths, path)
    end
    return paths
end
