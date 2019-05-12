using GenerativeModels
using Flux
using ValueHistories
using Test
using Random
include(joinpath(dirname(pathof(GenerativeModels)), "../test/test_utils.jl"))

xdim = 5
ldim = 1
N = 10

@testset "AE" begin
	println("           autoencoder")

	x = GenerativeModels.Float.(hcat(ones(xdim, Int(N/2)), zeros(xdim, Int(N/2))))
	Random.seed!(12345)
	model = GenerativeModels.AE([xdim,2,ldim], [ldim,2,xdim])
	_x = model(x)
	# for training check
	frozen_params = getparams(model)
	@test !all(paramchange(frozen_params, model))

	# test correct construction
	@test size(model.encoder.layers,1) == 2
	@test size(model.decoder.layers,1) == 2
	# test basic functionality
	@test size(model.encoder(x)) == (ldim, N)
	@test size(_x) == (xdim,N)
	# test output types
	@test typeof(_x) <: Flux.TrackedArray{GenerativeModels.Float,2}
	@test typeof(GenerativeModels.loss(model, x)) == Flux.Tracker.TrackedReal{GenerativeModels.Float}    
	# test loss functions
	l = GenerativeModels.getlosses(model, x)[1]
	@test typeof(l) == GenerativeModels.Float
	@test GenerativeModels.loss(model, x) == l
	# test basic loss tracking
	hist = MVHistory()
	GenerativeModels.track!(model, hist, x)
	GenerativeModels.track!(model, hist, x)
	is, ls = get(hist, :loss)
	@test ls[1] == l
	@test ls[1] == ls[2]
	# test training
	GenerativeModels.fit!(model, x, 5, 1000, cbit=100, history = hist, verb = false)
	is, ls = get(hist, :loss)
	@test ls[1] > ls[end] 
	@test ls[end] < 2e-5
	# were the layers realy trained?
	@test all(paramchange(frozen_params, model))	
	# test fast training
	GenerativeModels.fit!(model, x, 5, 1000, cbit=100, history = hist, verb = false, runtype = "fast")

	# alternative constructor test
	model = GenerativeModels.AE(xdim, ldim, 4)
	@test length(model.encoder.layers) == 4
	@test length(model.decoder.layers) == 4
	@test size(model.encoder(x)) == (ldim, N)
	@test size(model(x)) == (xdim, N)

	# hdim 
	model = GenerativeModels.AE(xdim, ldim, 4, hdim = 10)
	@test length(model.encoder.layers) == 4
	@test length(model.decoder.layers) == 4
	@test size(model.encoder(x)) == (ldim, N)
	@test size(model(x)) == (xdim, N)
	@test size(model.encoder.layers[1].W,1) == 10
	@test size(model.encoder.layers[end].W,2) == 10	

	# encoding
	@test size(GenerativeModels.encode(model, x)) == (ldim,N)
	@test size(GenerativeModels.encode(model, x, 3)) == (ldim,N)

	# convolutional AE
	data = randn(Float32,32,16,1,8);
	m,n,c,k = size(data)
	# now setup the convolutional net
	insize = (m,n,c)
	latentdim = 2
	nconv = 3
	kernelsize = 3
	channels = (2,4,6)
	scaling = [(2,2),(2,2),(1,1)]
	batchnorm = true
	model = GenerativeModels.ConvAE(insize, latentdim, nconv, kernelsize, channels, scaling;
		batchnorm = batchnorm)
	hist = MVHistory()
	frozen_params = getparams(model)
	@test size(model(data)) == size(data)
	@test size(model.encoder(data)) == (latentdim,k)
	GenerativeModels.fit!(model, data, 4, 10, cbit=1, history=hist, verb=false)
	@test all(paramchange(frozen_params, model))	
	(i,ls) = get(hist,:loss)
	@test ls[end] < ls[1]
	# encoding
	@test size(GenerativeModels.encode(model, data)) == (latentdim,k)
	@test size(GenerativeModels.encode(model, data,3)) == (latentdim,k)
end
