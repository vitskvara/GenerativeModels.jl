using GenModels
using Flux
using ValueHistories
using Test
using Random
include(joinpath(dirname(pathof(GenModels)), "../test/test_utils.jl"))

xdim = 5
ldim = 1
N = 10

@testset "AAE" begin
	println("           adversarial autoencoder")

	x = GenModels.Float.(hcat(ones(xdim, Int(N/2)), zeros(xdim, Int(N/2))))
	Random.seed!(12345)
	model = GenModels.AAE([xdim,2,ldim], [ldim,2,xdim], [ldim,3,1])
	_x = model(x)
	z = model.pz(N)

	# alternative constructor
	model = GenModels.AAE(xdim, ldim, 3, 2)
	# for training check
	frozen_params = getparams(model)
	@test !all(paramchange(frozen_params, model)) 
	@test length(model.encoder.layers) == 3
	@test length(model.decoder.layers) == 3
	@test length(model.discriminator.layers) == 2

	# constructor with specified hdim
	model = GenModels.AAE(xdim, ldim, 3, 2, hdim=10)
	# for training check
	frozen_params = getparams(model)
	@test length(model.encoder.layers) == 3
	@test length(model.decoder.layers) == 3
	@test length(model.discriminator.layers) == 2
	@test size(model.encoder.layers[1].W,1) == 10
	@test size(model.encoder.layers[end].W,2) == 10
	@test size(model.discriminator.layers[1].W,1) == 10
	# encoding
	@test size(GenModels.encode(model, x)) == (ldim,N)
	@test size(GenModels.encode(model, x, 3)) == (ldim,N)

	# loss functions
	ael = GenModels.aeloss(model,x)
	dl = GenModels.dloss(model,x)
	dl = GenModels.dloss(model,x,z)
	gl = GenModels.gloss(model,x)
	@test typeof(ael) <: Flux.Tracker.TrackedReal	
	@test typeof(dl) <: Flux.Tracker.TrackedReal
	@test typeof(gl) <: Flux.Tracker.TrackedReal
	ael, dl, gl = GenModels.getlosses(model,x)
	aelz, dlz, glz = GenModels.getlosses(model,x,z)
	@test (ael, gl) == (aelz, glz)

	# tracking
	hist = MVHistory()
	GenModels.track!(model, hist, x)
	GenModels.track!(model, hist, x)
	is, ls = get(hist, :aeloss)
	@test ls[1] == ael
	@test ls[1] == ls[2]
	is, gls = get(hist, :gloss)
	@test gls[1] == gl
	@test gls[1] == gls[2]

	# test of basic training
	# test proper updating of autoencoder
	eparams = getparams(model.encoder)
	decparams = getparams(model.decoder)
	disparams  = getparams(model.discriminator)
	aeopt = ADAM()
	ael = GenModels.aeloss(model,x)
	Flux.Tracker.back!(ael)
	GenModels.update!((model.encoder,model.decoder), aeopt)
	@test all(paramchange(eparams, model.encoder))
	@test all(paramchange(decparams, model.decoder))
	@test !any(paramchange(disparams, model.discriminator))
	@test all(model.encoder.layers[end].W.data .== model.f_encoder.layers[end].W)

	# test proper updating of discriminator
	eparams = getparams(model.encoder)
	decparams = getparams(model.decoder)
	disparams  = getparams(model.discriminator)
	dopt = ADAM()
	dl = GenModels.dloss(model,x)
	Flux.Tracker.back!(dl)
	@test all(model.encoder.layers[1].W.grad .== 0) 
	GenModels.update!(model.discriminator, dopt)
	@test !any(paramchange(eparams, model.encoder))
	@test !any(paramchange(decparams, model.decoder))
	@test all(paramchange(disparams, model.discriminator))
	@test all(model.discriminator.layers[end].W.data .== model.f_discriminator.layers[end].W)

	# test proper updating of encoder with gloss
	eparams = getparams(model.encoder)
	decparams = getparams(model.decoder)
	disparams = getparams(model.discriminator)
	gopt = ADAM()
	gl = GenModels.gloss(model,x)
	Flux.Tracker.back!(gl)
	@test all(model.discriminator.layers[1].W.grad .== 0) 
	GenModels.update!(model.encoder, gopt)
	@test all(paramchange(eparams, model.encoder))
	@test !any(paramchange(decparams, model.decoder))
	@test !any(paramchange(disparams, model.discriminator))

	# test the fit function
	hist = MVHistory()
	GenModels.fit!(model, x, 5, 1000, cbit=5, history = hist, verb = false)
	is, ls = get(hist, :aeloss)
	@test ls[1] > ls[end] 

	# test sampling
	@test size(GenModels.sample(model)) == (xdim,1)
	@test size(GenModels.sample(model,7)) == (xdim,7)

	# convolutional AAE
	data = randn(Float32,32,16,1,8);
	m,n,c,k = size(data)
	# now setup the convolutional net
	insize = (m,n,c)
	latentdim = 2
	disc_nlayers = 4 # number of discriminator layers
	nconv = 3
	kernelsize = 3
	channels = (2,4,6)
	scaling = [(2,2),(2,2),(1,1)]
	batchnorm = true
	hdim = 10 # width of the discriminator
	pz(n) = randn(Float32, latentdim, n)
	model = GenModels.ConvAAE(insize, latentdim, disc_nlayers, nconv, kernelsize, 
		channels, scaling, pz; hdim = hdim, batchnorm = batchnorm)
	# test correct construction
	@test length(model.discriminator.layers) == disc_nlayers
	@test size(model.discriminator.layers[2].W, 1) == hdim
	# test training
	hist = MVHistory()
	frozen_params = getparams(model)
	@test size(model(data)) == size(data)
	@test size(model.encoder(data)) == (latentdim,k)
	GenModels.fit!(model, data, 4, 10, cbit=1, history=hist, verb=false)
	@test all(paramchange(frozen_params, model))	
	(i,ls) = get(hist,:aeloss)
	@test ls[end] < ls[1]
	# encoding
	@test size(GenModels.encode(model, data)) == (latentdim,k)
	@test size(GenModels.encode(model, data,3)) == (latentdim,k)
end
