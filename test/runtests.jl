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

if !isempty(PortAudio.devices())
    # these default values are specific to my machines
    if Sys.iswindows()
        default_indev = "Microphone Array (Realtek High "
        default_outdev = "Speaker/Headphone (Realtek High"
    elseif Sys.isapple()
        default_indev = "Built-in Microphone"
        default_outdev = "Built-in Output"
    elseif Sys.islinux()
        default_indev = "default"
        default_outdev = "default"
    end

    @testset "Local Tests" begin
        @testset "Open Default Device" begin
            println("Recording...")
            stream = PortAudioStream(2, 0)
            buf = read(stream, 5s)
            close(stream)
            @test size(buf) == (round(Int, 5 * samplerate(stream)), nchannels(stream.source))
            println("Playing back recording...")
            stream = PortAudioStream(0, 2)
            write(stream, buf)
            println("flushing...")
            flush(stream)
            close(stream)
            println("Testing pass-through")
            stream = PortAudioStream(2, 2)
            write(stream, stream, 5s)
            flush(stream)
            close(stream)
            println("done")
        end
        @testset "Samplerate-converting writing" begin
            stream = PortAudioStream(0, 2)
            write(stream, SinSource(eltype(stream), samplerate(stream)*0.8, [220, 330]), 3s)
            write(stream, SinSource(eltype(stream), samplerate(stream)*1.2, [220, 330]), 3s)
            flush(stream)
            close(stream)
        end
        @testset "Open Device by name" begin
            stream = PortAudioStream(default_indev, default_outdev)
            buf = read(stream, 0.001s)
            @test size(buf) == (round(Int, 0.001 * samplerate(stream)), nchannels(stream.source))
            write(stream, buf)
            io = IOBuffer()
            show(io, stream)
            @test occursin("""
            PortAudioStream{Float32}
              Samplerate: 44100.0Hz
              Buffer Size: 4096 frames
              2 channel sink: "$default_outdev"
              2 channel source: "$default_indev\"""", String(take!(io)))
            close(stream)
        end
        @testset "Error on wrong name" begin
            @test_throws ErrorException PortAudioStream("foobarbaz")
        end
        # no way to check that the right data is actually getting read or written here,
        # but at least it's not crashing.
        @testset "Queued Writing" begin
            stream = PortAudioStream(0, 2)
            buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.sink))*0.1, samplerate(stream))
            t1 = @async write(stream, buf)
            t2 = @async write(stream, buf)
            @test fetch(t1) == 48000
            @test fetch(t2) == 48000
            flush(stream)
            close(stream)
        end
        @testset "Queued Reading" begin
            stream = PortAudioStream(2, 0)
            buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.source))*0.1, samplerate(stream))
            t1 = @async read!(stream, buf)
            t2 = @async read!(stream, buf)
            @test fetch(t1) == 48000
            @test fetch(t2) == 48000
            close(stream)
        end
    end
end
