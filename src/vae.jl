"""
	VAE{encoder, sampler, decoder, variant}

Flux-like structure for the variational autoencoder.
"""
mutable struct VAE <: GenerativeModel
	encoder
	sampler
	decoder
	variant::Symbol
end

VAE(E,S,D) = VAE(E,S,D,:unit)

# make the struct callable
(vae::VAE)(X) = vae.decoder(vae.sampler(vae.encoder(X)))

# and make it trainable
Flux.@treelike VAE #encoder, decoder

"""
	VAE(esize, dsize; [activation, layer, variant])

Initialize a variational autoencoder with given encoder size and decoder size.

	esize - vector of ints specifying the width anf number of layers of the encoder
	dsize - size of decoder
	activation [Flux.relu] - arbitrary activation function
	layer [Flux.Dense] - type of layer
	variant [:unit] 
		:unit - output has unit variance
		:scalar - a scalar variance of the output is estimated
		:diag - the diagonal of covariance of the output is estimated
"""
function VAE(esize::Array{Int64,1}, dsize::Array{Int64,1}; activation = Flux.relu,
		layer = Flux.Dense, variant = :unit)
	@assert variant in [:unit, :diag, :scalar]
	@assert size(esize, 1) >= 3
	@assert size(dsize, 1) >= 3
	@assert esize[end] == 2*dsize[1]
	(variant==:unit) ? (@assert esize[1] == dsize[end]) :
		((variant==:diag) ? (@assert esize[1]*2 == dsize[end]) :
			(@assert esize[1] + 1 == dsize[end]) )

	# construct the encoder
	encoder = aelayerbuilder(esize, activation, layer)

	# construct the decoder
	decoder = aelayerbuilder(dsize, activation, layer)

	# finally construct the ae struct
	vae = VAE(encoder, samplenormal, decoder, variant)

	return vae
end

"""
	VAE(xdim, zdim, nlayers; [hdim, activation, layer, variant])

Initialize a variational autoencoder given input and latent dimension 
and numberof layers. The width of layers is linearly interpolated 
between xdim and zdim.

	xdim = input size
	zdim = code size
	nlayers = number of layers
	hdim = width of layers, if not specified, it is linearly interpolated
	activation [Flux.relu] = arbitrary activation function
	layer [Flux.Dense] = layer type
	variant [:unit] 
		:unit - output has unit variance
		:scalar - a scalar variance of the output is estimated
		:diag - the diagonal of covariance of the output is estimated
"""
function VAE(xdim::Int, zdim::Int, nlayers::Int; 
	activation = Flux.relu, hdim = nothing, layer = Flux.Dense, variant = :unit)
	@assert nlayers >= 2

	if hdim == nothing
		esize = ceil.(Int, range(xdim, zdim, length=nlayers+1))
	else
		esize = vcat([xdim], fill(hdim, nlayers-1), [zdim])
	end
	dsize = reverse(esize)
	esize[end] = esize[end]*2
	if variant == :scalar
		dsize[end] = dsize[end] + 1
	elseif variant == :diag
		dsize[end] = dsize[end]*2
	end

	VAE(esize,dsize; activation=activation, layer=layer, variant=variant)
end

"""
	ConvVAE(insize, zdim, nconv, kernelsize, channels, scaling; 
		[variant, ndense, dsizes, activation, stride, batchnorm, upscale_type])

Initializes a convolutional autoencoder.


	insize = tuple of (height, width, channels)
	zdim = size of latent space
	nconv = number of convolutional layers
	kernelsize = Int or a tuple/vector of ints
	channels = a tuple/vector of number of channels
	scaling = Int or a tuple/vector of ints
	pz = sampling distribution that can be called as pz(dim,nsamples)
	variant = one of [:unit, :scalar, :diag]
	ndense = number of dense layers
	dsizes = vector of dense layer widths
	activation = type of nonlinearity
	stride = Int or vecotr/tuple of ints
	batchnorm = use batchnorm in convolutional layers
	upscale_type = one of ["transpose", "upscale"]
"""
function ConvVAE(insize, zdim, nconv, kernelsize, channels, scaling; variant=:unit, 
	outbatchnorm = false, upscale_type = "transpose", kwargs...)
	encoder = convencoder(insize, zdim*2, nconv, kernelsize, 
		channels, scaling; outbatchnorm=outbatchnorm, kwargs...)
	if variant in [:diag, :scalar]
		insize = [x for x in insize]
		insize[end] = 2*insize[end]
	end
	decoder = convdecoder(insize, zdim, nconv, kernelsize, 
		reverse(channels), scaling; layertype = upscale_type, kwargs...)
	return VAE(encoder, samplenormal, decoder, variant)
end

################
### training ###
################

"""
	KL(vae, X)

KL divergence between the encoder output and unit gaussian.
"""
function KL(vae::VAE, X) 
	ex = vae.encoder(X)
	KL(mu(ex), sigma2(ex))
end

"""
	loglikelihood(vae, X)

Loglikelihood of an autoencoded sample X.
"""
function loglikelihood(vae::VAE, X)
	if vae.variant == :unit
		μ = vae(X)
		return loglikelihoodopt(X,μ)
	elseif vae.variant == :scalar
		vx = vae(X)
		μ, σ2 = mu_scalarvar(vx), sigma2_scalarvar(vx)
		bound = Float(1e20)
		σ2 = min.(σ2,Float(1e10))
		if any(isnan.(μ))
			println("mu has nans")
		end
		if any(isnan.(σ2))
			println("sigma has nans")
		end
		
		return loglikelihoodopt(X,μ,σ2)
	elseif vae.variant == :diag
		vx = vae(X)
		μ, σ2 = mu(vx), sigma2(vx)
		return loglikelihoodopt(X,μ,σ2)
	end
end

"""
	loglikelihood(vae, X, L)

Loglikelihood of an autoencoded sample X sampled L times.
"""
loglikelihood(vae::VAE, X, L) = sum([loglikelihood(vae, X) for m in 1:L])/Float(L)
# conv layers dont like using mean (probably because there is no promotion of 1/L to Float32)

"""
	loss(vae, X, L, beta)

Loss function of the variational autoencoder. beta is scaling parameter of
the KLD, 1 = full KL, 0 = no KL.
"""
loss(vae::VAE, X, L, beta) = Float(beta)*KL(vae, X) - loglikelihood(vae,X,L)

"""
	evalloss(vae, X, L, beta)

Print vae loss function values.
"""
function evalloss(vae::VAE, X, L, beta) 
	l, lk, kl = getlosses(vae, X, L, beta)
	print("total loss: ", l,
	"\n-loglikelihood: ", lk,
	"\nKL: ", kl, "\n\n")
end

"""
	getlosses(vae, X, L, beta)

Return the numeric values of current losses.
"""
getlosses(vae::VAE, X, L, beta) = (
	Flux.Tracker.data(loss(vae, X, L, beta)),
	Flux.Tracker.data(-loglikelihood(vae,X,L)),
	Flux.Tracker.data(KL(vae, X))
	)

"""
	track!(vae, history, X, L, beta)

Save current progress.
"""
function track!(vae::VAE, history::MVHistory, X, L, beta)
	l, lk, kl = getlosses(vae, X, L, beta)
	push!(history, :loss, l)
	push!(history, :loglikelihood, lk)
	push!(history, :KL, kl)
end

########### callback #################

"""
	(cb::basic_callback)(m::VAE, d, l, opt, L::Int, beta::Real)

Callback for the train! function.
TODO: stopping condition, change learning rate.
"""
function (cb::basic_callback)(m::VAE, d, l, opt, L::Int, beta::Real)
	# update iteration count
	cb.iter_counter += 1
	# save training progress to a MVHistory
	if cb.history != nothing
		track!(m, cb.history, d, L, beta)
	end
	# verbal output
	if cb.verb 
		# if first iteration or a progress print iteration
		# recalculate the shown values
		if (cb.iter_counter%cb.show_it == 0 || cb.iter_counter == 1)
			ls = getlosses(m, d, L, beta)
			cb.progress_vals = Array{Any,1}()
			push!(cb.progress_vals, ceil(Int, cb.iter_counter/cb.epoch_size))
			push!(cb.progress_vals, cb.iter_counter)
			push!(cb.progress_vals, ls[1])
			push!(cb.progress_vals, ls[2])
			push!(cb.progress_vals, ls[3])
		end
		# now give them to the progress bar object
		ProgressMeter.next!(cb.progress; showvalues = [
			(:epoch,cb.progress_vals[1]),
			(:iteration,cb.progress_vals[2]),
			(:loss,cb.progress_vals[3]),
			(Symbol("-loglikelihood"),cb.progress_vals[4]),
			(:KL,cb.progress_vals[5])
			])
	end
end

"""
	opt = fit!(VAE, X, batchsize, nepochs[; L, beta, cbit, history, 
		opt, verb, η, runtype, usegpu, memoryefficient, prealloc_eps])

Trains the VAE neural net.

	vae - a VAE object
	X - data array with instances as columns
	batchsize - batchsize
	nepochs - number of epochs
	L [1] - number of samples for likelihood
	beta [1.0] - scaling for the KLD loss
	cbit [200] - after this # of iterations, progress is updated
	history [nothing] - a dictionary for training progress control from ValueHistories
	opt [ADAM] - optimizer
	verb [true] - if output should be produced
	η [0.001] - learning rate
	runtype ["experimental"] - if fast is selected, no output and no history is written
	usegpu [false] - if X is not already on gpu, this will put the inidvidual batches into gpu memory rather 
			than all data at once
	memoryefficient [false] - calls gc after every batch, again saving some memory but prolonging computation
	prealloc_eps [false] - preallocates the random samples
"""
function fit!(vae::VAE, X, batchsize::Int, nepochs::Int; 
	L=1, beta::Real= Float(1.0), cbit::Int=200, history = nothing, opt=nothing,
	verb::Bool = true, η = 0.001, runtype = "experimental", prealloc_eps=false, 
	trainkwargs...)
	@assert runtype in ["experimental", "fast"]
	# sampler
	sampler = EpochSampler(X,nepochs,batchsize)
	epochsize = sampler.epochsize
	# it might be smaller than the original one if there is not enough data
	batchsize = sampler.batchsize 

	# loss
	# use default loss

	# optimizer
	if opt == nothing
		opt = ADAM(η)
	end
	
	# callback
	if runtype == "experimental"
		cb = basic_callback(history,verb,η,cbit; 
			train_length = nepochs*epochsize,
			epoch_size = epochsize)
		_cb(m::VAE,d,l,o) =  cb(m,d,l,o,L,beta)
	elseif runtype == "fast"
		_cb = fast_callback 
	end

	# allocate an array to be used for randn generation and replace the old sampler
	if prealloc_eps
		ϵ_prealloc = (get(trainkwargs, :usegpu, false)) ? gpu(Array{Float,2}(undef, getlsize(vae), batchsize)) : Array{Float,2}(undef, getlsize(vae), batchsize)
		orig_sampler = vae.sampler
		new_sampler(x) = samplenormal!(x,ϵ_prealloc) 
		vae.sampler = new_sampler
	end

	# train
	train!(
		vae,
		collect(sampler),
		x->loss(vae,x,L,beta),
		opt,
		_cb;
		clip_grad = true,
		trainkwargs...
		)

	# retrieve back the normal sampler
	if prealloc_eps
		vae.sampler = orig_sampler
	end
	
	return opt
end

##### auxiliary functions #####
"""
	encode(VAE, X)

Latent (sampled) representation of X given VAE.
"""
encode(model::VAE, X) = model.sampler(model.encoder(X))
encode_untracked(model::VAE, X) = Flux.Tracker.data(model.sampler(model.encoder(X)))

"""
	isconvvae(model)

Decides whether a VAE model is a convolutional one or not.
"""
function isconvvae(model::VAE)
	try 
		l = length(model.decoder.layers[1])
	catch e
		if isa(e, MethodError)
			return false
		else
			rethrow(e)
		end
	end
	return true
end

"""
	getlsize(model)

Returns the latent dimension size of a given VAE.
"""
function getlsize(model::VAE)
	if isconvvae(model)
		return size(model.decoder.layers[1].layers[1].W, 2)
	else
		return size(model.decoder.layers[1].W, 2)
	end
end

"""
	sample(VAE[, M])

Get samples generated by the VAE.
"""
function StatsBase.sample(vae::VAE)
	if vae.variant == :unit
		X = vae.decoder(randn(Float, getlsize(vae)))
	elseif vae.variant == :scalar
		X = samplenormal_scalarvar(vae.decoder(randn(Float, getlsize(vae)))) 
		isconvvae(vae) ? nothing : X = reshape(X, size(X,1))
	elseif vae.variant == :diag
		X = samplenormal(vae.decoder(randn(Float, getlsize(vae))))
		isconvvae(vae) ? nothing : X = reshape(X, size(X,1))
	end
	return X
end
function StatsBase.sample(vae::VAE, M::Int)
	if vae.variant == :unit
		return vae.decoder(randn(Float, getlsize(vae),M))
	elseif vae.variant == :scalar
		return samplenormal_scalarvar(vae.decoder(randn(Float, getlsize(vae),M)))
	elseif vae.variant == :diag
		return samplenormal(vae.decoder(randn(Float, getlsize(vae),M)))
	end
end
