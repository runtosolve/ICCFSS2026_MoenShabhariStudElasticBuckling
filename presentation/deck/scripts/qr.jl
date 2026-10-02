# Generate data/qr.svg — a QR code for a URL, as a compact inline-able SVG.
# Uses QRCoders.jl in a throwaway environment (nothing added to the project).
#
#     julia scripts/qr.jl https://example.com/my-talk/
#
# Put it on a slide with `@fig svg data/qr.svg`. The svg carries class="qr";
# template.html sizes and places it per layout (title corner, centered, ...).
# Always black-on-white so it scans on the dark theme too.

isempty(ARGS) && error("usage: julia scripts/qr.jl <url>")
url = ARGS[1]

import Pkg
Pkg.activate(; temp = true)
Pkg.add("QRCoders"; io = devnull)
using QRCoders

m = qrcode(url; eclevel = Medium(), width = 0)
n = size(m, 1)
q = 4  # quiet zone, modules
d = IOBuffer()
for i in 1:n
    j = 1
    while j <= n
        if m[i, j]
            stop = something(findnext(!, m[i, :], j), n + 1)
            print(d, "M", j - 1 + q, " ", i - 1 + q, "h", stop - j, "v1h-", stop - j, "z")
            j = stop
        else
            j += 1
        end
    end
end
s = n + 2q
svg = string(
    "<svg class=\"qr\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ", s, " ", s,
    "\" shape-rendering=\"crispEdges\" role=\"img\" aria-label=\"", url, "\">",
    "<rect width=\"", s, "\" height=\"", s, "\" fill=\"#fff\"/>",
    "<path fill=\"#000\" d=\"", String(take!(d)), "\"/></svg>\n"
)
out = joinpath(@__DIR__, "..", "data", "qr.svg")
write(out, svg)
println("wrote $(abspath(out)) ($(n)×$(n) modules)")
