One design challenge is how to handle nodes with a finite length, e.g.
ArrayPlayers. Also this comes up with how do we stop a node.

Considerations:
1. typically the end of the signal will happen in the middle of a block.
2. we want to avoid the AudioNodes allocating a new block every render cycle
3. force-stopping nodes will typicaly happen on a block boundary
4. A node should be able to send its signal to multiple receivers, but it doesn't
   know what they are (it doesn't store a reference to them), so if a node is finished
   it needs to communicate that in the value returned from render()

Options:

1. We could take the block size as a maximum, and if there aren't that many
   frames of audio left then a short (or empty) block is returned.
2. We could return a (Array, Bool) tuple with the full block-size, padded with
   zeros (or extending the last value out), and the bool indicating whether
   there is more data
3. We could raturn a (Array, Int) tuple that indicates how many frames were
   written
4. We could ignore it and just have them keep playing. This makes the simple
   play(node) usage dangerous because they never get cleaned up
