# Publish the deck to GitHub Pages: builds the self-contained single file and
# force-pushes it as index.html on an orphan gh-pages branch of `origin`.
#
#     julia publish.jl            # publishes to https://<user>.github.io/<repo>/
#     julia publish.jl talk2026   # ... to a subdirectory, keeping the root free
#
# First push auto-enables GitHub Pages on the repo (branch gh-pages, path /).
# The branch history is replaced on every publish — it only ever holds output.

ENV["SLIDES_NO_AUTOBUILD"] = "1"
include(joinpath(@__DIR__, "build.jl"))   # provides build() and DIR

build(single = true)

subdir = isempty(ARGS) ? "" : ARGS[1]
origin = readchomp(`git -C $DIR remote get-url origin`)

mktempdir() do tmp
    dest = isempty(subdir) ? tmp : mkpath(joinpath(tmp, subdir))
    cp(joinpath(DIR, "deck-single.html"), joinpath(dest, "index.html"))
    touch(joinpath(tmp, ".nojekyll"))
    run(`git -C $tmp init -q -b gh-pages`)
    run(`git -C $tmp add -A`)
    run(`git -C $tmp commit -q -m "Publish slide deck"`)
    run(`git -C $tmp push -q --force $origin gh-pages`)
end

m = match(r"github\.com[:/]([^/]+)/([^/.]+)", origin)
if m !== nothing
    user, repo = lowercase(m.captures[1]), m.captures[2]
    path = isempty(subdir) ? "" : subdir * "/"
    println("published: https://$user.github.io/$repo/$path")
else
    println("published gh-pages to $origin")
end
