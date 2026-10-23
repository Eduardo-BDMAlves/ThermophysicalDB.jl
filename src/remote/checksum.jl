"""
    ChecksumMismatchError(path, expected, actual)

Thrown when the SHA-256 digest of a file differs from the published one.
"""
struct ChecksumMismatchError <: Exception
    path::String
    expected::String
    actual::String
end

function Base.showerror(io::IO, err::ChecksumMismatchError)
    return print(
        io,
        "SHA-256 mismatch for ",
        err.path,
        ": expected ",
        err.expected,
        ", got ",
        err.actual,
    )
end

const SHA256_REGEX = r"\b([0-9a-fA-F]{64})\b"

"""
    parse_sha256(text) -> String

Extract the first 64-digit hexadecimal digest from `text` and return it in lower case.
Accepts a bare digest (the format NIST publishes) as well as `sha256sum` output such as
`"<digest>  file.tgz"`.
"""
function parse_sha256(text::AbstractString)::String
    m = match(SHA256_REGEX, text)
    m === nothing && throw(ArgumentError("no SHA-256 digest found in the given text"))
    return lowercase(String(m.captures[1]))
end

"""
    file_sha256(path) -> String

Lower-case hexadecimal SHA-256 digest of the file at `path`, computed in streaming mode.
"""
file_sha256(path::AbstractString)::String = open(io -> bytes2hex(SHA.sha256(io)), path)

"""
    verify_sha256(path, expected) -> true

Check the digest of `path` against `expected` (case-insensitive). Throws
[`ChecksumMismatchError`](@ref) on mismatch.
"""
function verify_sha256(path::AbstractString, expected::AbstractString)
    actual = file_sha256(path)
    wanted = lowercase(expected)
    actual == wanted || throw(ChecksumMismatchError(String(path), wanted, actual))
    return true
end
