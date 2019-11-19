# Netscope CNN Analyzer

available here: http://kentanabe.github.io/netscope 

This is a CNN Analyzer tool, based on Netscope by [dgschwend](https://github.com/dgschwend), based on Netscope by [ethereon](https://github.com/ethereon).
Netscope is a web-based tool for visualizing neural network topologies. It currently supports UC Berkeley's [Caffe framework](https://github.com/bvlc/caffe).

This fork adds support for following layers.
- Interp layer
- Pooling layer with round_mode or ceil_mode

### Documentation
- Netscope [Quick Start Guide](http://kentanabe.github.io/netscope/quickstart.html)

### Demo
- :new: [Visualization of ICNet for Real-Time Semantic Segmentation on High-Resolution Images](http://kentanabe.github.io/netscope/#/preset/icnet_cityscapes)
- :new: [Visualization of Densenet121 (round_mode: FLOOR)](http://kentanabe.github.io/netscope/#/preset/DenseNet_121_round_mode_floor)
- :new: [Visualization of Densenet121 (ceil_mode: false)](http://kentanabe.github.io/netscope/#/preset/DenseNet_121)
- [Visualization of ZynqNet CNN](http://kentanabe.github.io/netscope/#/preset/zynqnet)
- [Visualization of the Deep Convolutional Neural Network "SqueezeNet"](http://kentanabe.github.io/netscope/#/preset/squeezenet)

### License

Released under the MIT license.
All included network models provided under their respective licenses.
