function setup_server(env = dirname(SymbolServer.Pkg.Types.Context().env.project_file), depot = first(SymbolServer.Pkg.depots()), cache = joinpath(dirname(pathof(SymbolServer)), "..", "store"))
    server = StaticLint.FileServer()
    ssi = SymbolServerInstance(depot, cache)
    _, symbols = SymbolServer.getstore(ssi, env)
    extended_methods = SymbolServer.collect_extended_methods(symbols)
    server.external_env = ExternalEnv(symbols, extended_methods, Symbol[])
    server
end

function indexlines(io::IO)
    lines = readlines(io, keep = true)
    indices = cumsum(length(line) for line in lines)
    indices, lines
end
indexlines(text::AbstractString) = indexlines(IOBuffer(text))

const noqa = r"# noqa\(([^)]+)\)"

function format_hint(indices, lines, prefix, offset, x)
    if haserror(x)
        message = LintCodeDescriptions[x.meta.error]
        code = String(Symbol(x.meta.error))
    else
        message = "Missing reference"
        code = "MissingRef"
    end

    row = searchsortedfirst(indices, offset)
    m = match(noqa, lines[row])
    if m !== nothing
        (codes,) = m
        code in eachsplit(codes, ',') && return ""
    end

    col = offset - get(indices, row - 1, 0)
    "$(prefix)$(row):$(col): $(message)"
end

function format_hints(source, prefix, hints)
    indices, lines = indexlines(source)
    result = [(x, format_hint(indices, lines, prefix, offset + 1, x)) for (offset, x) in hints]
    filter!(((_, hint),) -> !isempty(hint), result)
end

"""
    lint_string(s, server; gethints = false)

Parse a string and run a semantic pass over it. This will mark scopes, bindings,
references, and lint hints. An annotated `EXPR` is returned or, if `gethints = true`,
it is paired with a collected list of errors/hints.
"""
function lint_string(s::String, server = setup_server(); gethints = false)
    empty!(server.files)
    f = File("", s, CSTParser.parse(s, true), nothing, server)
    env = getenv(f, server)
    setroot(f, f)
    setfile(server, "", f)
    semantic_pass(f)
    check_all(f.cst, LintOptions(), env)
    if gethints
        return f.cst, format_hints(f.source, "", collect_hints(f.cst, env))
    else
        return f.cst
    end
end

"""
    lint_file(rootpath, server)

Read a file from disc, parse and run a semantic pass over it. The file should be the
root of a project, e.g. for this package that file is `src/StaticLint.jl`. Other files
in the project will be loaded automatically (calls to `include` with complicated arguments
are not handled, see `followinclude` for details). A `FileServer` will be returned
containing the `File`s of the package.
"""
function lint_file(rootpath, server = setup_server(); gethints = false)
    empty!(server.files)
    root = loadfile(server, rootpath)
    semantic_pass(root)
    for f in values(server.files)
        check_all(f.cst, LintOptions(), getenv(f, server))
    end
    if gethints
        hints = []
        rootdir = dirname(rootpath)
        for (p,f) in server.files
            prefix = "$(relpath(p, rootdir)):"
            append!(hints, format_hints(f.source, prefix, collect_hints(f.cst, getenv(f, server))))
        end
        return root, hints
    else
        return root
    end
end
