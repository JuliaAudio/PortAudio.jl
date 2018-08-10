using PortAudio

"""Continuously read from the default audio input and plot an
ASCII level/peak meter"""
function micmeter(metersize)
    mic = PortAudioStream(1, 0; blocksize=512)

    signalmax = zero(eltype(mic))
    println("Press Ctrl-C to quit")
    while true
        block = read(mic, 512)
        blockmax = maximum(abs.(block)) # find the maximum value in the block
        signalmax = max(signalmax, blockmax) # keep the maximum value ever
        print("\r") # reset the cursor to the beginning of the line
        printmeter(metersize, blockmax, signalmax)
    end
end

"""Print an ASCII level meter of the given size. Signal and peak
levels are assumed to be scaled from 0.0-1.0, with peak >= signal"""
function printmeter(metersize, signal, peak)
    # calculate the positions in terms of characters
    peakpos = clamp(round(Int, peak * metersize), 0, metersize)
    meterchars = clamp(round(Int, signal * metersize), 0, peakpos-1)
    blankchars = max(0, peakpos-meterchars-1)

    for position in 1:meterchars
        print_with_color(barcolor(metersize, position), ">")
    end

    print(" " ^ blankchars)
    print_with_color(barcolor(metersize, peakpos), "|")
    print(" " ^ (metersize - peakpos))
end

"""Compute the proper color for a given position in the bar graph. The first
half of the bar should be green, then the remainder is yellow except the final
character, which is red."""
function barcolor(metersize, position)
    if position/metersize <= 0.5
        :green
    elseif position == metersize
        :red
    else
        :yellow
    end
end

micmeter(80)
