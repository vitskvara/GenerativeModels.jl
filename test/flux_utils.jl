using Test
using GenModels
using Flux
using ValueHistories
include(joinpath(dirname(pathof(GenModels)), "../test/test_utils.jl"))

xdim = 3
ldim = 1
N = 10

@testset "flux utils" begin 
	# model saving
    args = [
        :xdim => 3,
        :zdim => 2,
        :nlayers => 3
    ]
    kwargs = Dict(
            :hdim => 10
        )
    modelname = "AE"
    model = GenModels.construct_model(modelname, args...; kwargs...)
    @test length(model.encoder.layers) == args[3][2]
    @test size(model.decoder.layers[1].W,2) == args[2][2]
    @test size(model.decoder.layers[1].W,1) == kwargs[:hdim]
    mf = "model.bson"
    GenModels.save_model(mf, model, modelname=modelname, model_args=args,
        model_kwargs=kwargs)
    @test isfile(mf)
    model2 = GenModels.construct_model(mf)
    for (p1,p2) in zip(params(model), params(model2))
    	@test all(p1 .== p2)
    end
    rm(mf)

	# adapt
	model = Flux.Chain(Flux.Dense(xdim, ldim), Flux.Dense(ldim, xdim))
	m32 = GenModels.adapt(Float32, model)
	@test typeof(m32.layers[1].W.data[1]) == Float32
	m64 = GenModels.adapt(Float64, model)
	@test typeof(m64.layers[1].W.data[1]) == Float64
	m32 = GenModels.adapt(Float32, model)
	@test typeof(m32.layers[1].W.data[1]) == Float32

	# freeze
	mf = GenModels.freeze(model)
	@test length(collect(params(mf))) == 0

	#iscuarray
	@test !GenModels.iscuarray(randn(4,10))
	_x = model(randn(xdim,10))
	@test !GenModels.iscuarray(_x)
	@test !GenModels.iscuarray(randn(4,10,1,1))
	
	# layerbuilder
	m = GenModels.layerbuilder([5,4,3,2], fill(Flux.Dense, 3), [Flux.relu, Flux.relu, Flux.relu])
	@test length(m.layers) == 3
	x = randn(5,10)
	@test size(m.layers[1](x)) == (4,10)
	@test size(m.layers[2](m.layers[1](x))) == (3,10)
	@test size(m(x)) == (2,10)
	@test typeof(m.layers[1].σ) == typeof(relu)
	
	m = GenModels.layerbuilder(5,4,2,4, fill(Flux.Dense, 4), fill(Flux.relu, 4))
	@test length(m.layers) == 4
	x = randn(5,10)
	@test size(m.layers[1](x)) == (4,10)
	@test size(m.layers[2](m.layers[1](x))) == (4,10)
	@test size(m.layers[3](m.layers[2](m.layers[1](x)))) == (4,10)
	@test size(m(x)) == (2,10)
	@test typeof(m.layers[1].σ) == typeof(relu)

	m = GenModels.layerbuilder([5,4,3,2], "relu", "linear", "Dense")
	@test length(m.layers) == 3
	x = randn(5,10)
	@test size(m.layers[1](x)) == (4,10)
	@test size(m.layers[2](m.layers[1](x))) == (3,10)
	@test size(m(x)) == (2,10)
	@test typeof(m.layers[1].σ) == typeof(relu)
	@test typeof(m.layers[3].σ) == typeof(identity)

	#aelayerbuilder
	m = GenModels.aelayerbuilder([5,4,4,2], relu, Dense)	
	@test length(m.layers) == 3
	x = randn(5,10)
	@test size(m.layers[1](x)) == (4,10)
	@test size(m.layers[2](m.layers[1](x))) == (4,10)
	@test size(m(x)) == (2,10)
	@test typeof(m.layers[1].σ) == typeof(relu)
	@test typeof(m.layers[3].σ) == typeof(identity)

	# update!&train!
	X = GenModels.Float.(hcat(ones(xdim, Int(N/2)), zeros(xdim, Int(N/2))))
	opt = ADAM(0.01)
	loss(x) = Flux.mse(model(x), x)
	cb(m,d,l,o) = nothing
	data = fill(X,100)
	L = loss(X)
	l = Flux.Tracker.data(L)
	frozen_params = getparams(model)
	#update!
	Flux.back!(L)
	GenModels.update!(model,opt)
	@test all(paramchange(frozen_params, model))
	@test all(model.layers[1].W.grad .== 0.0)
	# train!
	GenModels.train!(model, data, loss, opt, cb)
	_l = Flux.Tracker.data(loss(X))
	@test _l < l
	# were the layers realy trained?
	@test all(paramchange(frozen_params, model))

	# fast callback
	@test GenModels.fast_callback(GenModels.AE(4,3,2), 1, 2, 3) == nothing
	@test GenModels.fast_callback(GenModels.VAE(4,3,2), 1, 2, 3) == nothing
	@test GenModels.fast_callback(GenModels.TSVAE(4,3,(2,2)), 1, 2, 3) == nothing
	
	# basic callback
	hist = MVHistory()
	cb=GenModels.basic_callback(hist,true,0.0001,100; train_length=10,epoch_size=5)
	@assert typeof(cb) == GenModels.basic_callback

	# resnet module
	X = randn(5,4,2,5)
	layer = GenModels.ResBlock((3,3),2=>4)
	@test size(X) != size(layer(X)) == (5,4,4,5)
	try 
		layer = GenModels.ResBlock((4,3),2=>4)
	catch e
		@test isa(e, DomainError)
	end
	m,n,c,k = (9,6,1,2)
	X = randn(Float32,m,n,c,k)
	model = GenModels.ResBlock((3,3), 1=>2, relu)
	y = model(X)
	@test size(y) == (m,n,2,k)
	loss(x) = Flux.mse(model(x), x)
	opt = ADAM()
	L = loss(X)
	l = Flux.Tracker.data(L)
	frozen_params = getparams(model)
	#update!
	Flux.back!(L)
	GenModels.update!(model,opt)
	@test all(paramchange(frozen_params, model))
	@test loss(X) < l

	# upscaling stuff
	# upscale2D
	a = Tracker.collect(Flux.Tracker.TrackedReal.(Float32.([1.0 2.0; 3.0 4.0])))
	a = reshape(a,2,2,1,1)
	# 2D
	X = GenModels.upscale_2D(a,(3,2))
	@test size(X) == (6,4,1,1)
	@test typeof(X) <: Flux.TrackedArray
	@test X.data[3,1,1,1] == 1.0
	@test X.data[4,1,1,1] == 3.0
	@test X.data[3,4,1,1] == 2.0
	@test X.data[4,4,1,1] == 4.0
	# oneszeros
	x = GenModels.oneszeros(2,3,2)
	@test x == [0.0; 0.0; 1.0; 1.0; 0.0; 0.0]
	@test size(x) == (6,)
	x = GenModels.oneszeros(2,3,1)
	@test x == [1.0; 1.0; 0.0; 0.0; 0.0; 0.0]
	x = GenModels.oneszeros(Float32,2,3,1)
	@test typeof(x[1]) == Float32
	# voneszeros
	@test GenModels.voneszeros(2,3,2) == [0.0; 0.0; 1.0; 1.0; 0.0; 0.0]
	x = GenModels.voneszeros(Float32,2,3,2)
	@test size(x) == (6,)
	@test typeof(x[1]) == Float32
	# honeszeros
	@test GenModels.honeszeros(2,3,2) == [0.0 0.0 1.0 1.0 0.0 0.0]
	x = GenModels.honeszeros(Float32,2,3,2)
	@test size(x) == (1,6)
	@test typeof(x[1]) == Float32
	# vscalemat
	X = GenModels.vscalemat(2,2)
	@test X == [1.0 0.0; 1.0 0.0; 0.0 1.0; 0.0 1.0]
	X = GenModels.vscalemat(Float32,4,3)
	@test typeof(X[1]) == Float32
	@test size(X) == (12,3)
	# vscalemat
	X = GenModels.hscalemat(2,2)
	@test X == [1.0 1.0 0.0 0.0; 0.0 0.0 1.0 1.0]
	X = GenModels.hscalemat(Float32,4,3)
	@test typeof(X[1]) == Float32
	@test size(X) == (3,12)
	# upscaling
	a = Tracker.collect(Flux.Tracker.TrackedReal.(Float32.([1.0 2.0; 3.0 4.0])))
	a = reshape(a,2,2,1,1)
	# 2D
	X = GenModels.upscale(a[:,:,1,1],(3,2))
	@test size(X) == (6,4)
	@test typeof(X) <: Flux.TrackedArray
	@test X.data[3,1] == 1.0
	@test X.data[4,1] == 3.0
	@test X.data[3,4] == 2.0
	@test X.data[4,4] == 4.0
	# 3D
	X = GenModels.upscale(a[:,:,:,1],(3,2))
	@test size(X) == (6,4,1)
	@test typeof(X) <: Flux.TrackedArray
	@test X.data[3,1,1] == 1.0
	@test X.data[4,1,1] == 3.0
	@test X.data[3,4,1] == 2.0
	@test X.data[4,4,1] == 4.0
	# 4D
	X = GenModels.upscale(a,(3,2))
	@test size(X) == (6,4,1,1)
	@test typeof(X) <: Flux.TrackedArray
	@test X.data[3,1,1,1] == 1.0
	@test X.data[4,1,1,1] == 3.0
	@test X.data[3,4,1,1] == 2.0
	@test X.data[4,4,1,1] == 4.0
	# also test if propagation through the upscale layer works
	X = randn(Float32,24,24,1,1)
	global model = Flux.Chain(
	    # 24x24x2x1
	    Flux.Conv((3,3), 1=>4, pad=(1,1)),
	    # 24x24x4x1
	    Flux.MaxPool((8,6)),
	    # 3x4x4x1
	    x->GenModels.upscale(x,(8,6)),
	    # 24x24x4x1
	    Flux.Conv((3,3), 4=>1, pad=(1,1))
	)
	frozen_params = getparams(model)
	Y = model(X)
	@test size(Y) == size(X)
	loss(x) = Flux.mse(x,model(x))
	opt = Flux.ADAM()
	L = loss(X)
	Flux.back!(L)
	GenModels.update!(model, opt)
	@test all(paramchange(frozen_params, model))

	# padding
	a = Tracker.collect(Flux.Tracker.TrackedReal.(Float32.([1.0 2.0; 3.0 4.0])))
	a = reshape(a,2,2,1,1)
	# 2D
	X = GenModels.zeropad(a[:,:,1,1],[1,2,2,3])
	@test size(X) == (5,7)
	@test typeof(X)  <:Flux.TrackedArray
	# 3D
	X = GenModels.zeropad(a[:,:,:,1],[1,2,2,3])
	@test size(X) == (5,7,1)
	@test typeof(X)  <:Flux.TrackedArray
	# 4D
	X = GenModels.zeropad(a,[1,2,2,3])
	@test size(X) == (5,7,1,1)
	@test typeof(X)  <:Flux.TrackedArray
	# backprop
	X = randn(Float32,4,4,1,1)
	global model = Flux.Chain(
	    # 4x4x1x1
	    Flux.Conv((3,3), 1=>4, pad=(1,1)),
	    # 4x4x4x1
	    Flux.MaxPool((2,2)),
	    # 2x2x4x1
	    x->GenModels.zeropad(x,(1,1,1,1)),
	    # 4x4x4x1
	    Flux.Conv((3,3), 4=>1, pad=(1,1))
	)
	frozen_params = getparams(model)
	Y = model(X)
	@test size(Y) == size(X)
	loss(x) = Flux.mse(x,model(x))
	opt = Flux.ADAM()
	L = loss(X)
	Flux.back!(L)
	GenModels.update!(model, opt)
	@test all(paramchange(frozen_params, model))

	# same conv
	X = randn(Float32, 5,6,2,5)
	layer = GenModels.SameConv((3,3),2=>2)
	@test size(X) == size(layer(X))
	try
		layer = GenModels.SameConv((4,4),2=>2)
	catch e
		@test isa(e, DomainError)
	end
	layer = GenModels.SameConv((5,5),2=>2)
	frozen_params = getparams(layer)
	loss(x) = Flux.mse(x,layer(x))
	L = loss(X)
	Flux.back!(L)
	GenModels.update!(layer, opt)
	@test all(paramchange(frozen_params, layer))

	# convmaxpool
	X = randn(12,6,2,5)
	layer = GenModels.convmaxpool(3,2=>4,2)
	@test length(layer.layers) == 2
	@test size(layer(X)) == (6,3,4,5)
	layer = GenModels.convmaxpool(5,2=>8,(3,2))
	@test size(layer(X)) == (4,3,8,5)
	layer = GenModels.convmaxpool(3,2=>8,2;stride=3)
	@test size(layer(X)) == (2,1,8,5)
	layer = GenModels.convmaxpool(3,2=>4,2,batchnorm=true)
	@test length(layer.layers) == 3
	@test size(layer(X)) == (6,3,4,5)
	layer = GenModels.convmaxpool(5,2=>8,(3,2),batchnorm=true)
	@test size(layer(X)) == (4,3,8,5)
	layer = GenModels.convmaxpool(3,2=>8,2;stride=3,batchnorm=true)
	@test size(layer(X)) == (2,1,8,5)
	layer = GenModels.convmaxpool(3,2=>8,2;resblock=true)
	@test size(layer(X)) == (6,3,8,5)
	layer = GenModels.convmaxpool(3,2=>8,2;resblock=true)
	@test size(layer(X)) == (6,3,8,5)
		
	# convencoder
	L = 2
	X = randn(12,6,2,3)
	ins = size(X)[1:3]
	ds = [10,3,2]
	das = [relu,relu]
	ks = fill(3,L)
	cs = [2=>4, 4=>8]
    scs = [2,3]
    cas = fill(relu,L)
    sts = fill(1,L)
    bns = fill(true,L)
    rbs = fill(true,L)
	model = GenModels.convencoder(ins,ds,das,ks,cs,scs,cas,sts,bns,rbs)
	@test size(model(X)) == (2,3)

	# lightweight convencoder constructor
	# basic call
	X = randn(16,8,2,3)
	insize = size(X)[1:3]
	latentdim = 3
	nconv = 3
	kernelsize = 3
	channels = [4,8,16]
	scaling = 2
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling,
		resblock=true)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (2,1,16,3) 
	# more dense layers
	ndense = 2
	dsizes = [16]
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling;
		ndense = ndense, dsizes=dsizes)
	@test size(model(X)) == (latentdim,3) 
	@test length(model.layers[end]) == 2
	@test size(model.layers[end][1].W,1) == dsizes[1]
	# different kernelsizes
	kernelsize = [3,5,3]
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(X)) == (latentdim,3) 
	# different scaling factors
	scaling = [2,1,2]
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (4,2,16,3)
	# different scaling factors in dimesions
	scaling = (2,1)
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (2,8,16,3)
	# scaling factors different for each layer and dimension
	scaling = [(2,1),(1,2),(2,2)]
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (4,2,16,3)
	# stride
	scaling = [1,1,1]
	lstride = 2
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling;
		lstride = lstride)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (2,1,16,3)
	# different stride for each layer
	scaling = [1,1,1]
	lstride = [2,1,2]
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling;
		lstride = lstride)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (4,2,16,3) 
	# batchnorm 
	scaling = 2
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling;
		batchnorm=true)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (2,1,16,3) 
	@test length(model.layers[1].layers[1].layers) == 3
	# outbatchnorm
	scaling = 2
	model = GenModels.convencoder(insize, latentdim, nconv, kernelsize, channels, scaling;
		outbatchnorm=true)
	@test size(model(X)) == (latentdim,3)
	@test size(model.layers[1](X)) == (2,1,16,3) 
	@test length(model.layers[3].layers) == 2
	@test size(model(X)) == (latentdim,3)

	# upscaleconv
	X = randn(2,4,4,10)
	layer = GenModels.upscaleconv(3,4=>2,2)
	@test length(layer.layers) == 2
	@test size(layer(X)) == (4,8,2,10)
	layer = GenModels.upscaleconv(5,4=>1,(4,3))
	@test size(layer(X)) == (8,12,1,10)
	layer = GenModels.upscaleconv(3,4=>2,2;stride=2)
	@test size(layer(X)) == (2,4,2,10)
	layer = GenModels.upscaleconv(3,4=>2,2,batchnorm=true)
	@test length(layer.layers) == 3
	@test size(layer(X)) == (4,8,2,10)
	layer = GenModels.upscaleconv(5,4=>1,(4,3),batchnorm=true)
	@test size(layer(X)) == (8,12,1,10)
	layer = GenModels.upscaleconv(3,4=>2,2;stride=2,batchnorm=true)
	@test size(layer(X)) == (2,4,2,10)
	layer = GenModels.upscaleconv(3,4=>2,2;resblock=true)
	@test size(layer(X)) == (4,8,2,10)

	# upscaleconv
	X = randn(2,4,4,10)
	layer = GenModels.upscaleconv(3,4=>2,2,efficient=false)
	@test length(layer.layers) == 2
	@test size(layer(X)) == (4,8,2,10)
	layer = GenModels.upscaleconv(5,4=>1,(4,3),efficient=false)
	@test size(layer(X)) == (8,12,1,10)
	layer = GenModels.upscaleconv(3,4=>2,2;stride=2,efficient=false)
	@test size(layer(X)) == (2,4,2,10)
	layer = GenModels.upscaleconv(3,4=>2,2,batchnorm=true,efficient=false)
	@test length(layer.layers) == 3
	@test size(layer(X)) == (4,8,2,10)
	layer = GenModels.upscaleconv(5,4=>1,(4,3),batchnorm=true,efficient=false)
	@test size(layer(X)) == (8,12,1,10)
	layer = GenModels.upscaleconv(3,4=>2,2;stride=2,batchnorm=true,efficient=false)
	@test size(layer(X)) == (2,4,2,10)
	layer = GenModels.upscaleconv(3,4=>2,2;resblock=true,efficient=false)
	@test size(layer(X)) == (4,8,2,10)

	# convtransposeconv
	X = randn(2,4,4,10)
	layer = GenModels.convtransposeconv(3,4=>2,2)
	@test length(layer.layers) == 2
	@test size(layer(X)) == (4,8,2,10)
	layer = GenModels.convtransposeconv(5,4=>1,(4,3))
	@test size(layer(X)) == (8,12,1,10)
	layer = GenModels.convtransposeconv(3,4=>2,2;stride=2)
	@test size(layer(X)) == (2,4,2,10)
	layer = GenModels.convtransposeconv(3,4=>2,2,batchnorm=true)
	@test length(layer.layers) == 3
	@test size(layer(X)) == (4,8,2,10)
	layer = GenModels.convtransposeconv(5,4=>1,(4,3),batchnorm=true)
	@test size(layer(X)) == (8,12,1,10)
	layer = GenModels.convtransposeconv(3,4=>2,2;stride=2,batchnorm=true)
	@test size(layer(X)) == (2,4,2,10)
	layer = GenModels.convtransposeconv(3,4=>2,2;resblock=true)
	@test size(layer(X)) == (4,8,2,10)

	# convdecoder
	L = 2
	X = randn(12,6,2,3)
	y = randn(3,3)
	outs = size(X)[1:3]
	ds = [3,10]
	das = [relu,relu]
	ks = fill(3,L)
	cs = [8=>4, 4=>2]
    scs = [3,2]
    cas = fill(relu,L-1)
    sts = fill(1,L)
    bns = fill(true, L)
    rbs = fill(true, L)
	model = GenModels.convdecoder(outs,ds,das,ks,cs,scs,cas,sts,bns,rbs)
	@test size(model(y)) == size(X)

	# lightweight convdecoder constructor
	# basic call
	n = 5
	X = randn(16,8,2,n)
	outsize = size(X)[1:3]
	latentdim = 3
	y = randn(latentdim,n)
	nconv = 3
	kernelsize = 3
	channels = [16,8,4]
	scaling = 2
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(y)) == size(X)
	@test length(model.layers[3].layers[1].layers) == 2
	# upscale layer instead of convtranspose
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling;
		layertype = "upscale")
	@test size(model(y)) == size(X)
	# more dense layers
	ndense = 2
	dsizes = [16]
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling;
		ndense = ndense, dsizes=dsizes)
	@test size(model(y)) == size(X)
	@test length(model.layers[1]) == 2
	@test size(model.layers[1][1].W,1) == dsizes[1]
	# different kernelsizes
	kernelsize = [3,5,3]
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(y)) == size(X)
	# different scaling factors
	scaling = [2,1,2]
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(y)) == size(X)
	# different scaling factors in dimesions
	scaling = (2,1)
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(y)) == size(X)
	# scaling factors different for each layer and dimension
	scaling = [(2,1),(1,1),(2,2)]
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling)
	@test size(model(y)) == size(X)
	# stride
	scaling = [1,1,1]
	lstride = 2
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling;
		lstride = lstride)
	@test size(model(y)) == size(X)
	# different stride for each layer
	scaling = [1,1,1]
	lstride = [2,1,2]
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling;
			lstride = lstride)
	@test size(model(y)) == size(X)
	# batchnorm
	scaling = 2
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling;
		batchnorm = true)
	@test length(model.layers[3].layers[1].layers) == 3
	@test size(model(y)) == size(X)
	# resblock
	scaling = 2
	model = GenModels.convdecoder(outsize, latentdim, nconv, kernelsize, channels, scaling;
		resblock = true)
	@test length(model.layers[3].layers[1].layers) == 2
	@test size(model(y)) == size(X)
	
end