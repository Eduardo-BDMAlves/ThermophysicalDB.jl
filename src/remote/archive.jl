# Streaming access to the .tgz: entries are decompressed and handed over one at a time,
# so the archive is never unpacked to disk (tens of thousands of small files are slow to
# create, especially on Windows) and memory use is bounded by the largest single entry.

const TAR_BUFFER_SIZE = 512 * 1024  # must be a multiple of 512

function open_tar_stream(f, archive::AbstractString)
    return open(archive, "r") do io
        stream = GzipDecompressorStream(io)
        try
            return f(stream)
        finally
            close(stream)
        end
    end
end

"""
    foreach_archive_entry(f, archive; suffix = ".json")

Stream through the gzip-compressed tarball `archive` and call `f(path, data)` for every
regular file whose path ends with `suffix`, where `data` is a `Vector{UInt8}` with the
file contents. Other entries are skipped without being materialised.
"""
function foreach_archive_entry(f, archive::AbstractString; suffix::AbstractString = ".json")
    buf = Vector{UInt8}(undef, TAR_BUFFER_SIZE)
    open_tar_stream(archive) do stream
        while !eof(stream)
            header = Tar.read_header(stream; buf)
            header === nothing && break
            if header.type === :file && endswith(header.path, suffix)
                out = IOBuffer(; sizehint = Int(header.size))
                Tar.read_data(stream, out; size = header.size, buf)
                f(header.path, take!(out))
            else
                Tar.skip_data(stream, header.size)
            end
        end
    end
    return nothing
end

"""
    archive_inventory(archive) -> NamedTuple

Count the regular files in the tarball `archive` per (lower-case) extension without
reading their contents. Returns `(; files, by_extension)`. Useful as a quick sanity check
of a downloaded archive.
"""
function archive_inventory(archive::AbstractString)
    by_extension = Dict{String,Int}()
    buf = Vector{UInt8}(undef, TAR_BUFFER_SIZE)
    open_tar_stream(archive) do stream
        while !eof(stream)
            header = Tar.read_header(stream; buf)
            header === nothing && break
            Tar.skip_data(stream, header.size)
            if header.type === :file
                extension = lowercase(last(splitext(header.path)))
                by_extension[extension] = get(by_extension, extension, 0) + 1
            end
        end
    end
    return (; files = sum(values(by_extension); init = 0), by_extension)
end
