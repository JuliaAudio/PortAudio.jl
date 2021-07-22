using PortAudio
using Documenter: deploydocs, makedocs

makedocs(
    sitename = "PortAudio.jl", 
    modules = [PortAudio],
    pages = [
        "Public interface" => "index.md",
        "Internals" => "internals.md"
    ]
)
deploydocs(repo = "github.com/JuliaAudio/PortAudio.jl.git")