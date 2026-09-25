using Pkg
Pkg.activate(@__DIR__)
dev = ["TriShellFiniteElement", "QuadShellFiniteElement", "CeeSectionBuckling", "CUFSM",
       "BucklingModeIdentification", "CrossSectionGeometry", "SectionProperties", "AISIS100", "LinesCurvesNodes"]
for d in dev
    Pkg.develop(path = joinpath(homedir(), ".julia", "dev", d))
end
Pkg.add(["Ferrite", "Arpack", "LinearMaps", "Gmsh", "CairoMakie", "WGLMakie", "Bonito",
         "Statistics", "Printf", "DelimitedFiles", "Serialization", "LinearAlgebra", "SparseArrays", "Tensors"])
Pkg.resolve()
Pkg.instantiate()
Pkg.precompile()
Pkg.status()
open(joinpath(@__DIR__, "logs", "versioninfo.txt"), "w") do io
    versioninfo(io)
    println(io)
    Pkg.status(io = io)
end
