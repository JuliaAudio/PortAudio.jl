using PortAudio
using DSP

function create_measure_signal()
    signal = zeros(Float32, 20000)
    for i in 1:3
        signal = vcat(signal, rand(Float32, 100), zeros(Float32, i*10000))
    end
    return signal
end

function measure_latency(in_latency = 0.1, out_latency=0.1; is_warmup = false)

    in_stream = PortAudioStream(1,0; latency=in_latency)
    out_stream = PortAudioStream(0,1; latency=out_latency)

    cond = Base.Event()

    writer_start_time = Int64(0)
    reader_start_time = Int64(0)

    reader = Threads.@spawn begin
        wait(cond)
        writer_start_time = time_ns() |> Int64
        return read(in_stream, 100000)
    end

    signal = create_measure_signal()
    writer = Threads.@spawn begin
            wait(cond)
            reader_start_time = time_ns() |> Int64
            write(out_stream, signal)
    end

    notify(cond)

    wait(reader)
    wait(writer)

    recorded = collect(reader.result)[:,1]
    
    close(in_stream)
    close(out_stream)

    diff = reader_start_time - writer_start_time |> abs

    diff_in_ms = diff / 10^6 # 1 ms = 10^6 ns

    if !is_warmup && diff_in_ms > 1
        @warn "Threads start time difference $diff_in_ms ms is bigger than 1 ms"
    end

    delay = finddelay(recorded, signal) / 48000

    return trunc(Int, delay * 1000)# result in ms
end

measure_latency(0.1, 0.1, 32; is_warmup = true) # warmup

latencies = [0.1, 0.01, 0.005]
for in_latency in latencies
    for out_latency in latencies
        measure = measure_latency(in_latency, out_latency)
        println("$measure ms latency for in_latency=$in_latency, out_latency=$out_latency")
    end
end
