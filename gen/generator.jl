using Clang.Generators
using libportaudio_jll

cd(@__DIR__)

include_dir = joinpath(libportaudio_jll.artifact_dir, "include") |> normpath
portaudio_h = joinpath(include_dir, "portaudio.h")

options = load_options(joinpath(@__DIR__, "generator.toml"))

args = get_default_args()
push!(args, "-I$include_dir")

ctx = create_context(portaudio_h, args, options)

build!(ctx)
