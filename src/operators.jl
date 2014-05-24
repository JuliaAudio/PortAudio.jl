*(node::AudioNode, coef::Real) = Gain(node, coef)
*(coef::Real, node::AudioNode) = Gain(node, coef)
