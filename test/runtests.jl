#!/usr/bin/env julia

using PortAudio
using Test

@testset "PortAudio Tests" begin
    @testset "Reports version" begin
        io = IOBuffer()
        PortAudio.versioninfo(io)
        result = split(String(take!((io))), "\n")
        # make sure this is the same version I tested with
        @test startswith(result[1], "PortAudio V19")
    end

    @testset "Can list devices without crashing" begin
        PortAudio.devices()
    end
end
