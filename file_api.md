Some possible API concepts for dealing with files
=================================================

Notes
-----

* requires libflac for flac decoding

Use Cases
---------

* Play a file through the speakers
* Use a file as input to an AudioNode for processing
* Read a file into an array
* Write an array into a file
* Write the output of an AudioNode to a file


IOStream API
------------

* users use standard julia "open" function to create an IOStream object
* FilePlayer <: AudioNode takes an IOStream and uses `sf_open_fd` to open and
  play
* play(io::IOStream) creates a FilePlayer and plays it (just like ArrayPlayer)
* FileStream 

### Play a file through the speakers

    sndfile = open("myfile.wav")
    play(sndfile)
    close(sndfile)

### Use a file as input to an AudioNode for processing

    sndfile = open("myfile.wav")
    # maybe FilePlayer also takes a string input for convenience
    node = FilePlayer(sndfile)
    mixer = AudioMixer([node])
    # etc.

### Read a file into an array

    # TODO

###  Write an array into a file

    # TODO

###  Write the output of an AudioNode to a file

    node = SinOsc(440)
    # ???

Separate Open Function API
--------------------------

* users use an explicit `af_open` function to open sound files
* `af_open` takes mode arguments just like the regular julia `open` function
* `af_open` returns a AudioFile instance.

### Play a file through the speakers

    sndfile = af_open("myfile.wav")
    play(sndfile)
    close(sndfile)

or

    play("myfile.wav")

### Use a file as input to an AudioNode for processing

    sndfile = af_open("myfile.wav")
    # FilePlayer also can take a string filename for convenience
    node = FilePlayer(sndfile)
    mixer = AudioMixer([node])
    # etc.

### Read a file into an array

    sndfile = af_open("myfile.wav")
    vec = read(sndfile) # takes an optional arg for number of frames to read
    close(sndfile)

###  Write an array into a file

    sndfile = af_open("myfile.wav", "w") #TODO: need to specify format
    vec = rand(Float32, 441000) # 10 seconds of noise
    write(sndfile, vec)
    close(sndfile)

###  Write the output of an AudioNode to a file

    sndfile = af_open("myfile.wav", "w") #TODO: need to specify format
    node = SinOsc(440)
    write(sndfile, node, 44100) # record 1 second, optional block_size
    # note that write() can handle sample depth conversions, and render() is
    # called with the sampling rate of the file
    close(sndfile)

