*(node::AudioNode, coef::Real) = Gain(node, coef)
*(coef::Real, node::AudioNode) = Gain(node, coef)
# multiplying by silence gives silence
*(in1::NullNode, in2::NullNode) = in1
*(in1::AudioNode, in2::NullNode) = in2
*(in1::NullNode, in2::AudioNode) = in1


+(in1::AudioNode, in2::AudioNode) = AudioMixer([in1, in2])
# adding silence has no effect
+(in1::NullNode, in2::NullNode) = in1
+(in1::AudioNode, in2::NullNode) = in1
+(in1::NullNode, in2::AudioNode) = in2
