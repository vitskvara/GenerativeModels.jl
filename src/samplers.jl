abstract type Sampler end

"""
	collect(s::Sampler)

Colect all samples.
"""
function collect(s::Sampler)
	res = []
	x = next!(s)
	while x != nothing
		push!(res,x)
		x = next!(s)
	end
	return res
end

"""
	enumerate(s::Sampler)

Returns an iterable over indices and batches.
"""
function enumerate(s::Sampler)
	res = []
	x = next!(s)
	i = 1
	while x != nothing
		push!(res,(i, x))
		x = next!(s)
	end
	return res
end

"""
	UniformSampler

A uniformly distributed sampler from a given data (Matrix). 
Returns niter batches of size batchsize, sampled unifromly from X.

Fields:

	data = original data
	M = number of dimensions of the data
	N = number of samples
	niter = how many iterations
	batchsize = how many samples in iteration
	iter = iteration counter
	replace = sample with replacement?
"""
mutable struct UniformSampler <: Sampler
	data
	M
	N
	niter
	batchsize
	iter
	replace
end

"""
	checkbatchsize(N,batchsize,replace)

Checks if batchsize is not larger than number of samples if replace = false.
"""
function checkbatchsize(N,batchsize,replace)
	if batchsize > N && !replace
		@warn "batchsize too large, setting to $N"
		batchsize = N
	end
	return batchsize
end

"""
	UniformSampler(X, niter::Int, batchsize::Int; replace = false)

A standard constructor.
"""
function UniformSampler(X::AbstractArray, niter::Int, batchsize::Int; replace = false)
	M = ndims(X)
	N = size(X,M)
	batchsize = checkbatchsize(N,batchsize,replace)
	return UniformSampler(X,M,N,niter,batchsize,0, replace)
end

"""
	next!(s::UniformSampler)

Returns next batch.
"""
function next!(s::UniformSampler)
	if s.iter < s.niter
		s.iter += 1
		randinds = sample(1:s.N,s.batchsize,replace=s.replace)
		inds = [collect(x) for x in axes(s.data)]
		inds[end] = randinds
		return s.data[inds...]
	else
		return nothing
	end
end

"""
	reset!(s::UniformSampler)

Set iteration counter to zero.
"""
function reset!(s::UniformSampler)
	s.iter = 0
end

"""
	EpochSampler

Sample in batches that cover the entire dataset for a given number of epochs.

Fields:

	data = original data matrix
	M = number of dimensions
	N = number of samples
	nepochs = how many epochs
	epochsize = how many iterations are in an epoch
	batchsize = how many samples in iteration
	iter = iteration counter
	buffer = list of indices yet unused in the current epoch
"""
mutable struct EpochSampler <: Sampler
	data
	M
	N
	nepochs
	epochsize
	batchsize
	iter
	buffer
end

"""
	EpochSampler(X, nepochs::Int, batchsize::Int)

Default constructor.
"""
function EpochSampler(X, nepochs::Int, batchsize::Int)
	M = ndims(X)
	N = size(X,M) 
	batchsize = checkbatchsize(N,batchsize,false)
	return EpochSampler(X,M,N,nepochs,Int(ceil(N/batchsize)),batchsize,0,
		sample(1:N,N,replace = false))
end

"""
	next!(s::EpochSampler)

Returns the next batch.
"""
function next!(s::EpochSampler)
	if s.iter < s.nepochs
		L = length(s.buffer)
		if  L > s.batchsize
			randinds = s.buffer[1:s.batchsize]
			s.buffer = s.buffer[s.batchsize+1:end]
		else
			randinds = copy(s.buffer)
			# reshuffle the indices again
			s.buffer = sample(1:s.N,s.N,replace = false)
			s.iter += 1
		end
		inds = [collect(x) for x in axes(s.data)]
		inds[end] = randinds
		# using views is very memory efficient, however it slows down training and is unusable for GPU
		# return @views s.data[inds...]
		return s.data[inds...]
	else
		return nothing
	end
end

"""
	enumerate(s::UniformSampler)

Returns an iterable over indices and batches.
"""
function reset!(s::EpochSampler)
	s.iter = 0
	s.buffer = sample(1:s.N,s.N,replace=false)
end
