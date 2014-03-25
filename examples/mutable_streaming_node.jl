# This demos how real-time audio manipulation can be done using AudioNodes. To
# run it, hook up some input audio to your default recording device and run the
# script. The demo will run for 10 seconds alternating the node between a muted
# and unmuted state
using AudioIO

type MutableNode <: AudioIO.AudioNode
  active::Bool
  deactivate_cond::Condition
  muted::Bool

  function MutableNode(muted::Bool)
    new(false, Condition(), muted)
  end
end

function MutableNode()
  MutableNode(false)
end

import AudioIO.render
function render(node::MutableNode, device_input::AudioIO.AudioBuf, info::AudioIO.DeviceInfo)
  return device_input .* !node.muted, AudioIO.is_active(node)
end

function mute(node::MutableNode)
  node.muted = true
end

function unmute(node::MutableNode)
  node.muted = false
end

mutableNode = MutableNode()
AudioIO.play(mutableNode)
muteTransitions = { true => unmute, false => mute }
for i in 1:10
  sleep(1)
  muteTransitions[mutableNode.muted](mutableNode)
end
