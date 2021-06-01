using Distributed, PortAudio

# Modified from Jiahao Chen's example in the obsolete AudioIO module.
# Will use first output device found in system's listing or DEFAULTDEVICE if set below
const DEFAULTDEVICE = -1

function paudio()
    devs = PortAudio.devices()
    if DEFAULTDEVICE < 0
        devnum = findfirst(x -> x.maxoutchans > 0, devs)
        (devnum == nothing) && error("No output device for audio found")
    else
        devnum = DEFAULTDEVICE + 1
    end
    return ostream = PortAudioStream(devs[devnum].name, 0, 2)
end

play(ostream, sample::Array{Float64, 1}) = write(ostream, sample)
play(ostr, sample::Array{Int64, 1}) = play(ostr, Float64.(sample))

struct Note{S <: Real, T <: Real}
    pitch::S
    duration::T
    sustained::Bool
end

function play(
    ostream,
    A::Note,
    samplingfreq::Real = 44100,
    shape::Function = t -> 0.6sin(t) + 0.2sin(2t) + 0.05 * sin(8t),
)
    timesamples = 0:(1 / samplingfreq):(A.duration * (A.sustained ? 0.98 : 0.9))
    v = Float64[shape(2π * A.pitch * t) for t in timesamples]
    if !A.sustained
        decay_length = div(length(timesamples), 5)
        v[(end - decay_length):(end - 1)] =
            v[(end - decay_length):(end - 1)] .* LinRange(1, 0, decay_length)
    end
    play(ostream, v)
    sleep(A.duration)
end

function parsevoice(melody::String; tempo = 132, beatunit = 4, lyrics = nothing)
    ostream = paudio() # initialize audio for output
    lyrics_syllables = lyrics == nothing ? nothing : split(lyrics)
    lyrics_syllables != nothing && (lyrics_syllables[end] *= "\n")
    note_idx = 1
    oldduration = 4
    for line in split(melody, '\n')
        percent_idx = findfirst('%', line) # Trim comment
        percent_idx == nothing || (line = line[1:(percent_idx - 1)])
        for token in split(line)
            pitch, duration, dotted, sustained = parsetoken(token)
            duration == nothing && (duration = oldduration)
            oldduration = duration
            dotted && (duration *= 1.5)
            if lyrics_syllables != nothing && 1 <= note_idx <= length(lyrics_syllables)
                # Print the lyrics, omitting hyphens
                if lyrics_syllables[note_idx][end] == '-'
                    print(join(split(lyrics_syllables[note_idx][:], "")[1:(end - 1)]), "")
                else
                    print(lyrics_syllables[note_idx], ' ')
                end
            end
            play(ostream, Note(pitch, (beatunit / duration) * (60 / tempo), sustained))
            note_idx += 1
        end
    end
end

function parsetoken(token, Atuning::Real = 220)
    state = :findpitch
    pitch = 0.0
    sustain = dotted = false
    lengthbuf = Char[]
    for char in token
        if state == :findpitch
            scale_idx =
                something(findfirst(char, String(collect('a':'g'))), 0) +
                something(findfirst(char, String(collect('A':'G'))), 0)
            if scale_idx != 0
                halfsteps = [12, 14, 3, 5, 7, 8, 10]
                pitch = Atuning * 2^(halfsteps[scale_idx] / 12)
                state = :findlength
            elseif char == 'r'
                pitch, state = 0, :findlength
            else
                error("unknown pitch: $char")
            end
        elseif state == :findlength
            if char == '#'
                pitch *= 2^(1 / 12) # sharp
            elseif char == 'b'
                pitch /= 2^(1 / 12) # flat
            elseif char == '\''
                pitch *= 2          # higher octave
            elseif char == ','
                pitch /= 2          # lower octave
            elseif char == '.'
                dotted = true       # dotted note
            elseif char == '~'
                sustain = true      # tied note
            else
                push!(lengthbuf, char)
                # Check for "is" and "es" suffixes for sharps and flats
                if length(lengthbuf) >= 2
                    if lengthbuf[(end - 1):end] == "is"
                        pitch *= 2^(1 / 12)
                        lengthbuf = lengthbuf[1:(end - 2)]
                    elseif lengthbuf[(end - 1):end] == "es"
                        pitch /= 2^(1 / 12)
                        lengthbuf = lengthbuf[1:(end - 2)]
                    end
                end
            end
        end
    end
    #finalize length
    lengthstr = String(lengthbuf)
    duration = isempty(lengthstr) ? nothing : tryparse(Int, lengthstr)
    return (pitch, duration, sustain, dotted)
end

parsevoice(
    """
f# f# g a a g f# e d d e f# f#~ f#8 e e2
f#4 f# g a a g f# e d d e f# e~ e8 d d2
e4 e f# d e f#8~ g8 f#4 d e f#8~ g f#4 e d e a,
f#2 f#4 g a a g f# e d d e f# e~ e8 d8 d2""",
    lyrics = """
      Freu- de, schö- ner Göt- ter- fun- ken, Toch- ter aus E- li- - si- um!
      Wir be- tre- ten feu- er- trun- ken, Himm- li- sche, dein Hei- - lig- thum!
      Dei- ne Zau- ber bin den - wie- der, was die - Mo- de streng ge- theilt,
      al- le mensch- en wer- den Brü- der wo dein sanf- ter Flü- - gel weilt.
      """,
)

# And now with harmony!

soprano = @spawn parsevoice(
    """
f'#. f'#. g'. a'. a'. g'. f'#. e'~ e'8 d.'4 d.' e.' f#'. f#'.~ f#' e'8 e'4~ e'2
""",
    lyrics = "Freu- de, schö- ner Göt- ter- fun- ken, Toch- ter aus E- li- - si- um!",
)
alto = @spawn parsevoice("""
a. a. a. a.  a.  a. a. a~ g8 f#.4 a.  a.  a. a.~ a a8 a4~ a2
""")
tenor = @spawn parsevoice("""
d. d. e. f#. f#. e. d. d~ e8 f#.4 f#. a,. d. d.~ d c#8 c#4 c#2
""")
bass = @spawn parsevoice("""
d. d. d. d. a,. a,. a,. b,~ c8 d. a., a., a., a., a, a8, a,4 a,2
""")
wait(soprano)
wait(alto)
wait(tenor)
wait(bass)

soprano = @spawn parsevoice(
    """
f'#.4 f'#. g'. a'. a'. g'. f'#. e'. d'. d'. e'. f'#. e'.~ e' d'8 d'4~ d'2
""",
    lyrics = "Wir be- tre- ten feu- er- trun- ken, Himm- li- sche, dein Hei- - lig- thum!",
)
alto = @spawn parsevoice("""
a.4 a. b. c'. c'. b. a. g. f#. f#. g. f#. g.~ g4 f#8 f#~ f#2
""")
tenor = @spawn parsevoice("""
d.4 d. d. d. d. d. d. d. d. d. c#. d. c#.~ c# d8 d d2
""")
bass = @spawn parsevoice("""
d.4 d. d. d. a,. a,. a,. a., a., a., a., a., a.,~ a, a,8 d, d,2
""")
wait(soprano)
wait(alto)
wait(tenor)
wait(bass)
