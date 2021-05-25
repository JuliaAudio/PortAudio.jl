#!/usr/bin/env julia

using Logging: Debug
using PortAudio
using PortAudio: 
    combine_default_sample_rates,
    handle_status,
    Pa_GetDefaultInputDevice, 
    Pa_GetDefaultOutputDevice, 
    Pa_GetDeviceInfo, 
    Pa_GetHostApiInfo, 
    Pa_Initialize,
    PA_OUTPUT_UNDERFLOWED,
    Pa_Terminate,
    PortAudioDevice,
    recover_xrun,
    seek_alsa_conf,
    @stderr_as_debug
using SampledSignals
using Test

@testset "Debug messages" begin
    @test_logs (:debug, "hi") min_level = Debug @test_nowarn @stderr_as_debug begin
        print(stderr, "hi")
        true
    end
end

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

    @testset "Null errors" begin
        @test_throws BoundsError Pa_GetDeviceInfo(-1)
        @test_throws BoundsError Pa_GetHostApiInfo(-1)
    end
end

if !isempty(PortAudio.devices())
    # make sure we can terminate, then reinitialize
    Pa_Terminate()
    @stderr_as_debug Pa_Initialize()

    # these default values are specific to my machines
    inidx = Pa_GetDefaultInputDevice()
    default_indev = PortAudioDevice(Pa_GetDeviceInfo(inidx), inidx).name
    outidx = Pa_GetDefaultOutputDevice()
    default_outdev = PortAudioDevice(Pa_GetDeviceInfo(outidx), outidx).name

    @testset "Local Tests" begin
        @testset "Open Default Device" begin
            println("Recording...")
            stream = PortAudioStream(2, 0)
            buf = read(stream, 5s)
            close(stream)
            @test size(buf) == (round(Int, 5 * samplerate(stream)), nchannels(stream.source))
            println("Playing back recording...")
            PortAudioStream(0, 2) do stream
                write(stream, buf)
            end
            println("Testing pass-through")
            stream = PortAudioStream(2, 2)
            sink = stream.sink
            source = stream.source
            @test sprint(show, typeof(sink)) == "PortAudioSink{Float32}"
            @test sprint(show, typeof(source)) == "PortAudioSource{Float32}"
            @test sprint(show, sink) == "2-channel PortAudioSink{Float32}($(repr(default_indev)))"
            @test sprint(show, source) == "2-channel PortAudioSource{Float32}($(repr(default_outdev)))"
            write(stream, stream, 5s)
            @test_throws ErrorException("""
                Attempted to close PortAudioSink or PortAudioSource.
                Close the containing PortAudioStream instead
                """
            ) close(sink)
            @test_throws ErrorException("""
                Attempted to close PortAudioSink or PortAudioSource.
                Close the containing PortAudioStream instead
                """
            ) close(source)
            close(stream)
            @test !isopen(stream)
            @test !isopen(sink)
            @test !isopen(source)
            println("done")
        end
        @testset "Samplerate-converting writing" begin
            stream = PortAudioStream(0, 2)
            write(stream, SinSource(eltype(stream), samplerate(stream)*0.8, [220, 330]), 3s)
            write(stream, SinSource(eltype(stream), samplerate(stream)*1.2, [220, 330]), 3s)
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
            
              2 channel sink: "$default_outdev"
              2 channel source: "$default_indev\"""", String(take!(io)))
            close(stream)
        end
        @testset "Error handling" begin
            @test_throws ErrorException PortAudioStream("foobarbaz")
            @test_throws ErrorException PortAudioStream(default_indev, "foobarbaz")
            @test_logs (:warn, "libportaudio: Output underflowed") handle_status(PA_OUTPUT_UNDERFLOWED)
            @test_throws ErrorException("libportaudio: PortAudio not initialized") handle_status(-10000)
            @test_throws ErrorException("""
                Could not find ALSA config directory. Searched:
                

                If ALSA is installed, set the "ALSA_CONFIG_DIR" environment
                variable. The given directory should have a file "alsa.conf".
                
                If it would be useful to others, please file an issue at
                https://github.com/JuliaAudio/PortAudio.jl/issues
                with your alsa config directory so we can add it to the search
                paths.
                """
            ) seek_alsa_conf([])
            @test_throws ErrorException("""
                Can't open duplex stream with mismatched samplerates (in: 0, out: 1).
                Try changing your sample rate in your driver settings or open separate input and output
                streams.
                """
            ) combine_default_sample_rates(1, 0, 1, 1)
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
