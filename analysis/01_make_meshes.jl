# Build the stud grids (tri and quad) for the 96 in 362S162-33 stud with SFIA service holes.
#   julia --project=. 01_make_meshes.jl [--dz=5] [--k=2] [--tag=M1] [--elements=mixed|tri|quad] [--noholes]
include(joinpath(@__DIR__, "stud_buckling_tools.jl"))
using .StudBucklingTools, Serialization, Printf
function getopt(name, default)
    i = findfirst(a -> startswith(a, "--$name="), ARGS)
    i === nothing ? default : split(ARGS[i], "=", limit = 2)[2]
end
dz  = parse(Float64, getopt("dz", "5"))
k   = parse(Int, getopt("k", "2"))
tag = getopt("tag", "M1")
elements = Symbol.(split(getopt("elements", "mixed"), ","))
holes = "--noholes" in ARGS ? nothing : (w = 1.5 * 25.4, ℓ = 4.0 * 25.4, spacing = 24.0 * 25.4)
L = 96.0 * 25.4
sec = section_362S162_33(; k)
println("Section: $(length(sec.X)) nodes, A = $(round(sec.A; digits = 3)) mm², web nodes $(sec.web_range), web centre node $(sec.web_center)")
for el in elements
    t0 = time()
    m = build_stud_grid(sec; L, dz, element = el, hole = holes, tag = tag * "_" * String(el))
    path = joinpath(@__DIR__, "meshes", "stud96_$(tag)_$(el).jls")
    StudBucklingTools.save_model(m, path)
    println("  saved $(path) ($(round(filesize(path)/1e6; digits = 1)) MB) in $(round(time() - t0; digits = 1)) s")
end
