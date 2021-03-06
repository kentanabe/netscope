module.exports =
  class Analyzer
    constructor: ->

    analyze: (net) ->
        ## Add Input/Output Dimensions + Channels to each Node / Layer
        # shape.dim: (    N   x   K   x   W   x   H   )
        #              batch   channel  width   height
        #               chIn    chOut   wIn     wOut

        for n in net.sortTopologically()

            layertype = n.type.toLowerCase()
            # Setup Default Values for Analysis
            d = n.analysis
            d.wIn = d.wIn ? 0
            d.hIn = d.hIn ? 0
            d.wOut = d.wOut ? 0
            d.hOut = d.hOut ? 0
            d.chIn = d.chIn ? 0
            d.chOut = d.chOut ? 0
            d.comp = {macc: 0, comp: 0, add: 0, div: 0, exp: 0}
            d.mem  = {activation: 0, param: 0}
            d.variants = [];

            # Setup connection to parent layer
            parent = n.parents[0]?.analysis

            # Setup default channels + dimensions: inherited from parent
            d.batchOut = d.batchIn = parent?.batchOut
            if d.wIn == 0
                d.wIn = parent?.wOut
            if d.hIn == 0
                d.hIn = parent?.hOut
            if d.chIn == 0
                d.chIn = parent?.chOut
            switch layertype
                when "data", "input"
                    #dimensions
                    if n.attribs.input_param?.shape?
                        shape     = n.attribs.input_param.shape
                        d.batchIn = shape.dim[0]
                        d.chIn    = shape.dim[1]
                        d.hIn     = shape.dim[2]
                        d.wIn     = shape.dim[3]
                    else if n.attribs.transform_param?.crop_size?
                        d.wIn = d.hIn = n.attribs.transform_param.crop_size
                        d.chIn = 3  # assume RGB
                        d.batchOut = 1
                    else
                        onerror('Unknown Input Dimensions')
                        debugger;
                    # update output sizes
                    d.wOut  = d.wIn
                    d.hOut  = d.hIn
                    d.chOut = d.chIn
                    d.batchOut = d.batchIn
                    #computation
                    #-- none
                    #memory
                    #-- none
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "dummydata"
                    #dimensions
                    params = n.attribs.dummy_data_param
                    if params.shape?
                        shape     = n.attribs.dummy_data_param.shape
                        d.batchIn = shape.dim[0]
                        d.chIn    = shape.dim[1]
                        d.hIn     = shape.dim[2]
                        d.wIn     = shape.dim[3]
                    else
                        num = params.num ? 2
                        channels = params.channels ? 3
                        height = params.height ? 4
                        width = params.width ? 5
                        d.batchIn = num
                        d.chIn = channels
                        d.hIn = height
                        d.wIn = width
                    # update output sizes
                    d.wOut  = d.wIn
                    d.hOut  = d.hIn
                    d.chOut = d.chIn
                    d.batchOut = d.batchIn
                    #computation
                    #-- none
                    #memory
                    #-- none
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "convolution", "depthwiseconvolution"
                    #dimensions
                    params   = n.attribs.convolution_param
                    kernel_w = params.kernel_w ? params.kernel_size
                    kernel_h = params.kernel_h ? params.kernel_size
                    stride_w = params.stride_w ? (params.stride ? 1)
                    stride_h = params.stride_h ? (params.stride ? 1)
                    pad_w    = params.pad_w ? (params.pad ? 0)
                    pad_h    = params.pad_h ? (params.pad ? 0)
                    numout   = params.num_output
                    group    = params.group ? 1
                    dilations = params.dilation ? []
                    if dilations.length > 1
                        dilation_h = dilations[0]
                        dilation_w = dilations[1]
                    else if dilations.length == 1
                        dilation_h = dilations[0]
                        dilation_w = dilations[0]
                    else
                        dilation_h = 1
                        dilation_w = 1
                    has_bias = if (params.bias_term ? "true") == "false" then 0 else 1

                    # according to http://caffe.berkeleyvision.org/tutorial/layers.html and https://github.com/BVLC/caffe/issues/3656
                    kernel = dilation_w*(kernel_w-1)+1
                    d.wOut = Math.floor((d.wIn + 2*pad_w - kernel) / stride_w) + 1
                    kernel = dilation_h*(kernel_h-1)+1
                    d.hOut = Math.floor((d.hIn + 2*pad_h - kernel) / stride_h) + 1

                    d.chOut = numout
                    #computation
                    d.comp.macc = (kernel_w*kernel_h)*(d.wOut*d.hOut)*d.chIn*d.chOut*d.batchOut/group
                    #memory
                    d.mem.param = (kernel_w*kernel_h)*d.chIn*d.chOut/group + has_bias*d.chOut
                    d.mem.activation = (d.wOut*d.hOut)*d.chOut*d.batchOut

                    # CACHE AND BANDWIDTH for Implementation Variants
                    if (do_variants_analysis)
                        d.variants.push({
                          name  : "complete outputs, input cache"
                          cache : d.chIn*kernel_h*d.wIn +          # line buffers
                                  d.chIn*kernel_h*kernel_w         # param cache
                          readBW  : d.chOut*d.chIn*(d.wIn*d.hIn)
                          writeBW : d.chOut*(d.wOut*d.hOut)          # ideal
                          confBW  : d.chOut*d.chIn*kernel_w*kernel_h # ideal
                        })
                        d.variants.push({
                          name  : "complete inputs, input cache"
                          cache : kernel_h*d.wIn +         # line buffers
                                  d.chIn*kernel_h*kernel_w # param cache
                          readBW  : d.chIn*((d.chOut+1)*(d.wIn*d.hIn))
                          writeBW : d.chIn*((d.chOut)*(d.wOut*d.hOut))
                          confBW  : d.chOut*d.chIn*kernel_w*kernel_h # ideal
                        })
                        d.variants.push({
                          name  : "complete inputs, input + output cache"
                          cache : kernel_h*d.wIn +           # line buffers
                                  d.chIn*kernel_h*kernel_w + # param cache
                                  d.wIn*d.hIn*d.chOut        # output cache
                          readBW  : d.chIn*(d.wIn*d.hIn)  # ideal
                          writeBW : d.chOut*(d.wOut*d.hOut) # ideal
                          confBW  : d.chOut*d.chIn*kernel_w*kernel_h # ideal
                        })
                        d.variants.push({
                          name  : "streaming, input cache"
                          cache : d.chIn*kernel_h*d.wIn
                          readBW  : d.chIn*(d.wIn*d.hIn)
                          writeBW : d.chOut*(d.wOut*d.hOut)
                          confBW  : d.hIn*(d.chIn*d.chOut*(kernel_w*kernel_h))
                        })
                        d.variants.push({
                          name  : "streaming, input + config cache"
                          cache : d.chIn*kernel_h*d.wIn +
                                  d.chIn*d.chOut*(kernel_h*kernel_w)
                          readBW  : d.chIn*(d.wIn*d.hIn)
                          writeBW : d.chOut*(d.wOut*d.hOut)
                          confBW  : d.chOut*d.chIn*kernel_w*kernel_h # ideal
                        })
                        d.variants.push({
                          name  : "streaming, temp."
                          img_cache : if kernel_h > 1 then d.chIn*kernel_h*d.wIn else d.chIn
                          img_dim   : d.chIn+"ch ∙ "+d.wIn+" × "+kernel_h+" × 32b"
                          flt_cache : d.chIn*d.chOut*(kernel_h*kernel_w)
                          squeeze_cache : if n.name.indexOf("squeeze") > -1 then d.chOut*d.wOut*d.hOut else ""
                        })


                when "innerproduct", "inner_product"
                    #dimensions
                    numout = n.attribs.inner_product_param.num_output
                    has_bias = if (n.attribs.inner_product_param.bias_term ? "true") == "false" then 0 else 1
                    d.wOut = 1
                    d.hOut = 1
                    d.chOut = numout
                    #computation
                    d.comp.macc = (d.wIn*d.hIn)*d.chIn*d.chOut*d.batchOut
                    #memory
                    d.mem.param = d.wIn*d.hIn*d.chIn*d.chOut + has_bias*d.chOut
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "pooling"
                    #dimensions
                    params = n.attribs.pooling_param
                    kernel_w = params.kernel_w ? params.kernel_size
                    kernel_h = params.kernel_h ? params.kernel_size
                    stride_w = params.stride_w ? (params.stride ? 1)
                    stride_h = params.stride_h ? (params.stride ? 1)
                    pad_w    = params.pad_w ? (params.pad ? 0)
                    pad_h    = params.pad_h ? (params.pad ? 0)
                    isglobal = params.global_pooling ? 0
                    ceil_mode = if (params.ceil_mode ? "true") == "false" then 0 else 1
                    round_mode = if (params.round_mode ? "CEIL").toUpperCase() == "FLOOR" then 0 else 1
                    pooltype = (params.pool ? 'MAX').toUpperCase()
                    d.chOut = d.chIn
                    # according to http://caffe.berkeleyvision.org/tutorial/layers.html and https://github.com/BVLC/caffe/issues/3656
                    if ceil_mode == 0
                        d.wOut = Math.floor((d.wIn + 2*pad_w - kernel_w) / stride_w) + 1
                        d.hOut = Math.floor((d.hIn + 2*pad_h - kernel_h) / stride_h) + 1
                    else if round_mode == 0
                        d.wOut = Math.floor((d.wIn + 2*pad_w - kernel_w) / stride_w) + 1
                        d.hOut = Math.floor((d.hIn + 2*pad_h - kernel_h) / stride_h) + 1
                    else
                        d.wOut = Math.ceil((d.wIn + 2*pad_w - kernel_w) / stride_w) + 1
                        d.hOut = Math.ceil((d.hIn + 2*pad_h - kernel_h) / stride_h) + 1
                    if isglobal
                        d.wOut = d.hOut = 1
                    #computation
                    num_ops = if isglobal then ((d.wIn*d.hIn)*d.chIn*d.batchOut) else ((d.wOut*d.hOut)*kernel_h*kernel_w*d.chOut*d.batchOut)
                    if pooltype == 'MAX'
                        d.comp.comp = num_ops
                    else if pooltype == 'AVE'
                        d.comp.add = num_ops
                        #d.comp.div = (d.wOut*d.hOut*d.chOut) #divide by const.
                    else
                        onerror "Unknown pooling type #{pooltype}"
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "interp"
                    #dimensions
                    params = n.attribs.interp_param
                    pad_beg = params.pad_beg ? 0
                    pad_end = params.pad_end ? 0
                    height_in_eff_ = d.hIn + pad_beg + pad_end
                    width_in_eff_ = d.wIn + pad_beg + pad_end
                    has_shrink_factor = params.shrink_factor ? 1 else 0
                    has_zoom_factor = params.zoom_factor ? 1 else 0
                    shrink_factor = has_shrink_factor ? params.shrink_factor : 1
                    zoom_factor = has_zoom_factor ? params.zoom_factor : 1
                    if shrink_factor < 1
                      onerror('Shrink factor must be positive')
                      debugger;
                    if zoom_factor < 1
                      onerror('Zoom factor must be positive')
                      debugger;
                    
                    if has_shrink_factor == 1
                      if has_zoom_factor == 1
                        height_out_ = Math.floor((height_in_eff_ - 1) / shrink_factor + 1)
                        width_out_ = Math.floor((width_in_eff_ - 1) / shrink_factor + 1)
                        height_out_ = Math.floor(height_out_ + (height_out_ - 1) * (zoom_factor - 1))
                        width_out_ = Math.floor(width_out_ + (width_out_ - 1) * (zoom_factor - 1))
                      else
                        height_out_ = Math.floor((height_in_eff_ - 1) / shrink_factor + 1)
                        width_out_ = Math.floor((width_in_eff_ - 1) / shrink_factor + 1)
                    else
                      if has_zoom_factor == 1
                        height_out_ = Math.floor(height_out_ + (height_out_ - 1) * (zoom_factor - 1))
                        width_out_ = Math.floor(width_out_ + (width_out_ - 1) * (zoom_factor - 1))
                      else
                        has_width = params.width ? 1 else 0
                        has_height = params.height ? 1 else 0
                        if (has_width && has_height)
                          height_out_ = params.height
                          width_out_ = params.width
                        else
                          onerror('Unknown Interp')
                          debugger;
                    d.chOut = d.chIn
                    d.batchOut = d.batchIn
                    d.wOut = width_out_
                    d.hOut = height_out_
                    //computation
                    if (d.hOut != d.hIn) || (d.wOut != d.wIn)
                      d.comp.macc = 2 * 2 * d.wOut * d.hOut * d.chOut * d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "batchnorm", "bn"
                    #dimensions
                    d.wOut  = d.wIn
                    d.hOut  = d.hIn
                    d.chOut = d.chIn
                    #computation
                    # BN: subtract mean, divide by variance for each channel
                    # averages during training: over spatial dims + batch
                    d.comp.add = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.div = d.wIn*d.hIn*d.chIn*d.batchOut
                    #memory
                    d.mem.param = d.chIn*2
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "lrn", "normalize"
                    #dimensions
                    #default mode: ACROSS_CHANNELS
                    mode   = n.attribs.lrn_param?.norm_region ? 'ACROSS_CHANNELS'
                    size   = n.attribs.lrn_param?.local_size ? 1
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    #computation
                    #  Each input value is divided by (1+(α/n)∑xi^2)^β
                    num_inputs = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.macc = num_inputs*size   # (∑xi^2)
                    d.comp.add = num_inputs         # (1+...)
                    d.comp.exp = num_inputs         # (...)^β
                    d.comp.div = num_inputs*2       # (α/n)*... + divide by sum
                    #memory
                    d.mem.param = 2  # alpha, beta
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "concat"
                    #dimensions
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    # sum up channels from inputs
                    d.chIn = 0
                    d.chIn += p.analysis.chOut for p in n.parents
                    d.chOut = d.chIn
                    # check input dimensions
                    failed = failed || (p.analysis.wOut != d.wIn || p.analysis.hOut != d.hIn) for p in n.parents
                    window.onerror('CONCAT: input dimensions dont agree!') if failed
                    #computation
                    # --none
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                #relu/dropout use some memory, do some comparisons
                when "relu", "relu6", "elu", "prelu", "dropout"
                    #dimensions
                    d.wIn = parent.wOut
                    d.hIn = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn = parent.chOut
                    #computation
                    d.comp.comp = d.wIn*d.hIn*d.chIn*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "sigmoid", "tanh"
                    #dimensions
                    d.wIn = parent.wOut
                    d.hIn = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn = parent.chOut
                    #computation
                    d.comp.comp = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.add = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.exp = d.wIn*d.hIn*d.chIn*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "swish"
                    #dimensions
                    d.wIn = parent.wOut
                    d.hIn = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn = parent.chOut
                    #computation
                    d.comp.comp = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.add = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.exp = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.div = d.wIn*d.hIn*d.chIn*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "softmax", "softmaxwithloss", "softmax_loss"
                    #dimensions
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    #computation
                    d.comp.exp = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.add = d.wIn*d.hIn*d.chIn*d.batchOut
                    d.comp.div = d.wIn*d.hIn*d.chIn*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "flatten"
                    #dimensions
                    d.wOut = d.hOut = 1
                    d.chOut = d.chIn * d.wIn * d.hIn
                    #computation
                    # --none
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "eltwise"
                    #dimensions
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    # check input dimensions
                    failed = false
                    for p in n.parents
                        failed = failed or (d.wIn != p.analysis.wOut) or (d.hIn != p.analysis.hOut)
                    onerror 'ELTWISE: input dimensions dont agree in '+n.name if failed
                    #computation
                    op = n.eltwise_param?.operation?.toUpperCase() ? 'SUM'
                    if op == 'SUM'
                        d.comp.add = d.wIn*d.hIn*d.chIn*d.batchOut
                    else if op == 'MAX'
                        d.comp.comp = d.wIn*d.hIn*d.chIn*d.batchOut
                    else if op == 'PROD'
                        d.comp.macc = d.wIn*d.hIn*d.chIn*d.batchOut
                    else
                        onerror 'ELTWISE: unknown operation '+op
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "deconvolution"
                    #dimensions
                    params   = n.attribs.convolution_param
                    kernel_w = params.kernel_w ? params.kernel_size
                    kernel_h = params.kernel_h ? params.kernel_size
                    stride_w = params.stride_w ? (params.stride ? 1)
                    stride_h = params.stride_h ? (params.stride ? 1)
                    pad_w    = params.pad_w ? (params.pad ? 0)
                    pad_h    = params.pad_h ? (params.pad ? 0)
                    numout   = params.num_output
                    group    = params.group ? 1
                    d.wOut = (stride_w*(d.wIn-1)+kernel_w-2*pad_w)
                    d.hOut = (stride_h*(d.hIn-1)+kernel_h-2*pad_h)
                    d.chOut = numout
                    #computation
                    d.comp.macc = d.chIn*d.chOut*d.wOut*d.hOut*(kernel_w/stride_w)*(kernel_h/stride_h)*d.batchOut/group
                    #memory
                    d.mem.param = kernel_w*kernel_h*d.chIn*d.chOut/group
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "crop"
                    #dimensions
                    ## crop to dims of 2nd parent
                    parent2 = n.parents[1].analysis
                    d.wOut = parent2.wOut
                    d.hOut = parent2.hOut
                    d.chOut = d.chIn
                    #computation
                    # --none
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "slice"
                    #dimensions
                    params   = n.attribs.slice_param
                    slice_points = params.slice_point ? []
                    if n.children.length > 2
                        j = 0
                        for child in n.children
                            if j == 0
                                child.analysis.chIn = slice_points[j]
                            else if child_id == n.children.length - 1
                                child.analysis.chIn = d.chIn - slice_points[j-1]
                            else
                                child.analysis.chIn = slice_points[j] - slice_points[j-1]
                            j += 1
                    else if n.children.length == 2
                        n.children[0].analysis.chIn = slice_points
                        n.children[1].analysis.chIn = d.chIn - slice_points[j]
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    #computation
                    # --none
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                #scale layer use activation memory and does multiplies
                when "scale"
                    #dimensions
                    ## assume pass-through
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    if n.parents.length != 1
                        for p in n.parents
                           d.wOut = (d.wOut < p.analysis.wOut) ? p.analysis.wOut : d.wOut
                           d.hOut = (d.hOut < p.analysis.hOut) ? p.analysis.hOut : d.hOut
                           d.chOut = (d.chOut < p.analysis.chOut) ? p.analysis.chOut : d.chOut
                    #computation: scale = multiplication
                    d.comp.macc = d.wOut*d.hOut*d.chOut*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "axpy"
                    #dimensions
                    ## assume pass-through
                    parent0 = n.parents[0].analysis
                    d.wOut = parent0.wOut
                    d.hOut = parent0.hOut
                    d.chOut = parent0.chOut
                    d.batchOut = d.batchIn
                    #computation: scale = multiplication
                    d.comp.macc = d.wOut*d.hOut*d.chOut*d.batchOut
                    d.comp.add = d.wOut*d.hOut*d.chOut*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "broadcast_mul"
                    #dimensions
                    ## assume pass-through
                    parent0 = n.parents[0].analysis
                    d.wOut = parent0.wOut
                    d.hOut = parent0.hOut
                    d.chOut = parparent0ent.chOut
                    d.batchOut = d.batchIn
                    #computation: scale = multiplication
                    d.comp.macc = d.wOut*d.hOut*d.chOut*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                when "broadcast_add"
                    #dimensions
                    ## assume pass-through
                    parent0 = n.parents[0].analysis
                    d.wOut = parent0.wOut
                    d.hOut = parent0.hOut
                    d.chOut = parent0.chOut
                    d.batchOut = d.batchIn
                    #computation: scale = multiplication
                    d.comp.add = d.wOut*d.hOut*d.chOut*d.batchOut
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                #implicit layers use activation memory, but no computation
                when "implicit"
                    #dimensions
                    #fix potentially undefined inputs
                    d.wIn = d.wIn ? "?"
                    d.hIn = d.hIn ? "?"
                    d.chIn = d.chIn ? "?"
                    d.batchIn = d.batchIn ? "?"
                    ## assume pass-through
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    d.batchOut = d.batchIn
                    #computation
                    # --none
                    #memory
                    d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut
                    d.mem.activation = 0 if isNaN(d.mem.activation)

                # accuracy layers just pass through
                when "accuracy"
                    #dimensions
                    ## assume pass-through
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    #computation
                    # --none
                    #memory
                    # --none

                # power layers: computes outputs y = (shift + scale * x) ^ power
                when "power"
                    params = n.attribs.power_param
                    power = params.power ? 1
                    scale = params.scale ? 1
                    shift = params.shift ? 0
                    #dimensions: pass-through
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    #computation
                    n_elements = d.wOut * d.hOut * d.chOut
                    d.comp.macc = if scale != 1 then n_elements else 0
                    d.comp.add = if shift != 0 then n_elements else 0
                    d.comp.exp = if power != 1 then n_elements else 0
                    #memory
                    d.mem.activation = n_elements

                # permute layers reorder the channels / dimensions
                when "permute"
                    permutation = n.attribs.permute_param.order.slice(0) #copy array
                    #dimension order: [batch, channels, height, width] according to http://caffe.berkeleyvision.org/tutorial/layers.html
                    dim_in = [d.batchIn, d.chIn, d.hIn, d.wIn]
                    d.batchOut = dim_in[permutation[0]];
                    d.chOut    = dim_in[permutation[1]];
                    d.hOut     = dim_in[permutation[2]];
                    d.wOut     = dim_in[permutation[3]];
                    #computation
                    # --none
                    #memory
                    # --none

                # generates prior boxes for SSD networks
                when "priorbox"
                    settings = n.attribs.prior_box_param
                    aspect_ratios = settings.aspect_ratio
                    num_priors = settings.min_size * settings.aspect_ratio
                    if settings.flip then num_priors *= 2

                    d.batchOut = d.batchIn
                    d.chOut    = 2
                    d.hOut     = 4
                    d.wOut     = num_priors
                    #computation
                    # -- neglectable
                    #memory
                    # --neglectable

                # reshape layers just permute dimensions, assume on-the-fly operation
                when "reshape"
                    #get reshape parameters
                    newshape = n.attribs.reshape_param.shape.dim.slice(0) # copy array
                    #debugger
                    console.log(newshape);
                    # 0 as dimension = inherit from input
                    if (not newshape[0]) or (newshape[0] == 0) then newshape[0] = d.batchIn
                    if (not newshape[1]) or (newshape[1] == 0) then newshape[1] = d.chIn
                    if (not newshape[2]) or (newshape[2] == 0) then newshape[2] = d.hIn
                    if (not newshape[3]) or (newshape[3] == 0) then newshape[3] = d.wIn
                    # -1 as dimension = infer from other dimensions, allowed for at most 1 dimension
                    prod_in_dims = d.batchIn * d.wIn * d.hIn * d.chIn
                    prod_out_dims = newshape[0] * newshape[1] * newshape[2] * newshape[3] * (-1)# -1 compensates "-1" in newshape
                    infered_dim = prod_in_dims / prod_out_dims
                    if newshape[0] == -1 then newshape[0] = infered_dim
                    if newshape[1] == -1 then newshape[1] = infered_dim
                    if newshape[2] == -1 then newshape[2] = infered_dim
                    if newshape[3] == -1 then newshape[3] = infered_dim
                    # assign output dimensions
                    d.batchOut = newshape[0]
                    d.chOut    = newshape[1]
                    d.hOut     = newshape[2]
                    d.wOut     = newshape[3]
                    #computation
                    # --none (some shifting-around only)
                    #memory

                when "python"
                    module = n.attribs.python_param.module

                    if module == "rpn.proposal_layer"
                        # ASSUME TEST.RPN_POST_NMS_TOP_N = 300
                        num_region_proposals = 300 # see RPN_POST_NMS_TOP_N in lib/fast_rcnn/config.py

                        #output dimensions:
                        d.wOut = d.hOut = 1
                        d.chOut = 5 # rectangle (x1, y1, x2, y2) (and image batch index n)
                        d.batchOut = num_region_proposals

                        #computation
                        d.comp.div  = (num_region_proposals*(num_region_proposals-1))/2
                        d.comp.macc = d.batchIn * (4+4) * 9*(d.wIn*d.hIn) + 2*(d.comp.div)
                        d.comp.add  = d.batchIn * (8+2) * 9*(d.wIn*d.hIn) + 6*(d.comp.div)
                        d.comp.comp = d.batchIn * (4+2) * 9*(d.wIn*d.hIn) + (9*(d.wIn*d.hIn))**2 + 7*(d.comp.div)
                        d.comp.exp  = d.batchIn * (2) * 9*(d.wIn*d.hIn)
                        #memory
                        d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                    else
                        onerror('Unknown Python Layer: '+module)
                        console.log(n)
                        debugger;

                  when "roipooling"
                      # 2 parent layers: region proposals, feature vectors
                      roi_proposals = if (n.parents[0].analysis.batchOut > 1) then n.parents[0].analysis else n.parents[1].analysis # parent with batchOut > 1 = region proposals
                      feature_map   = if (n.parents[0].analysis.batchOut > 1) then n.parents[1].analysis else n.parents[0].analysis # features = the other one
                      # Input / Output dimensions
                      d.chIn = d.chOut = feature_map.chIn
                      d.hIn = feature_map.hIn
                      d.wIn = feature_map.wIn
                      d.hOut  = n.attribs.roi_pooling_param.pooled_h
                      d.wOut  = n.attribs.roi_pooling_param.pooled_w
                      d.batchIn = d.batchOut = roi_proposals.batchOut
                      #spatial_scale = n.attribs.roi_pooling_param.spatial_scale
                      #computation
                      d.comp.add = d.batchOut
                      d.comp.div = d.batchOut
                      d.comp.macc = d.batchOut
                      d.comp.comp = d.batchOut * d.chIn * d.wIn * d.hIn
                      #memory
                      d.mem.activation = d.wOut*d.hOut*d.chOut*d.batchOut

                else # unknown layer;  print error message;
                    onerror('Unknown Layer: '+layertype)
                    console.log(n)
                    debugger;

            # add dimensions to node attributes so they show in graph tooltips
            trivial_layers = ["softmax", "softmaxwithloss", "softmax_loss", "dropout", "concat", "accuracy"]
            if not ($.inArray(layertype, trivial_layers) >= 0)
                summary = {
                    in: "#{d.chIn}ch ⋅ #{d.wIn}×#{d.hIn} (×#{d.batchIn})",
                    out: "#{d.chOut}ch ⋅ #{d.wOut}×#{d.hOut} (×#{d.batchOut})" }
                # concat number of required operations into string
                ops = (val+'⋅'+key for key,val of d.comp when val isnt 0).join(', ')
                #debugger
                summary.ops = ops if ops != ""
                # concat memory requirements into string
                mem = (val+'⋅'+key for key,val of d.mem when val isnt 0).join(', ')
                summary.mem = mem if mem != ""
                # attach
                _.extend(n.attribs, {analysis: summary});

        return net
