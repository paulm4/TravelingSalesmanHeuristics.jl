module TravelingSalesmanHeuristics

include("helpers.jl")
include("simulated_annealing.jl")
include("lowerbounds.jl")

export solve_tsp, lowerbound, repetitive_heuristic, two_opt,
       nearest_neighbor, cheapest_insertion, simulated_annealing, farthest_insertion
"""
.. solve_tsp(distmat) ..

Simple one-line call to approximately solving a TSP by specifying a distance matrix.

The optional keyword `quality_factor` (real number in [0,100]; defaults to 40) specifies the
tradeoff between computation time and quality of solution returned. Higher values
tend to lead to better solutions found at the cost of more computation time. Please note
that because both some heuristics and computation time are random, it is not guaranteed
that a call with a high `quality_factor` will always run slower or return a better solution than a
call with a lower `quality_factor`, though this is almost always the case. Also note that a 
`quality_factor` of 100 neither guarantees a solution which is optimal nor the best solution 
that can be found via extensive use of the methods in this package.

For more fine-grained control over the heuristics used, use heuristic methods such as
`nearest_neighbor`, `farthest_insertion`, `two_opt`, and `simulated_annealing`.
"""
function solve_tsp{T<:Real}(distmat::Matrix{T}; quality_factor::Real = 40.0)
	if quality_factor < 0 || quality_factor > 100
		warn("quality_factor keyword passed to solve_tsp must be in [0,100]")
		quality_factor = clamp(quality_factor, 0, 100)
	end
	
	lowest_threshold = 5
	
	# begin adding heuristics as dictated by the quality_factor,
	# starting with the very fastest
	answers = Vector{Tuple{Vector{Int}, T}}()
	push!(answers, farthest_insertion(distmat; do2opt = false))
	if quality_factor < lowest_threshold # fastest heuristic and out
		return answers[1]
	end
	# otherwise, we'll try several heuristics and return the best
	
	
	# add any nearest neighbor heuristics as dictated by quality_factor
	if quality_factor >= 60 # repetitive-NN, 2-opt on each iter
		push!(answers, repetitive_heuristic(distmat, nearest_neighbor; do2opt = true))
	elseif quality_factor >= 25 # repetitive-NN, 2-opt on final
		rnnpath, _ = repetitive_heuristic(distmat, nearest_neighbor; do2opt = false)
		push!(answers, two_opt(distmat, rnnpath))
	elseif quality_factor >= 15 # NN w/ 2-opt
		push!(answers, nearest_neighbor(distmat; do2opt = true))
	end
	
	# farthest insertions as needed
	if quality_factor >= 70 # repetitive-FI, 2-opt on each
		push!(answers, repetitive_heuristic(distmat, farthest_insertion; do2opt = true))
	elseif quality_factor >= 5 # FI w/ 2-opt
		push!(answers, farthest_insertion(distmat; do2opt = true))
	end
	
	# cheapest insertions
	if quality_factor >= 90 # repetitive-CI w/ 2-opt on each
		push!(answers, repetitive_heuristic(distmat, cheapest_insertion; do2opt = true))
	elseif quality_factor >= 35
		push!(answers, cheapest_insertion(distmat; do2opt = true))
	end
	
	# simulated annealing refinement, seeded with best so far
	if quality_factor >= 80
		_, bestind = findmin(pc[2] for pc in answers)
		bestpath, bestcost = answers[bestind]
		nstart = ceil(Int, (quality_factor - 79)/5)
		push!(answers,
		      simulated_annealing(distmat; num_starts = nstart, init_path = Nullable(bestpath)))
	end
	
	# pick best
	_, bestind = findmin(pc[2] for pc in answers)
	return answers[bestind]
end

###
# path generation heuristics
###

"""
Approximately solve a TSP using the nearest neighbor heuristic. You must pass a square matrix
distmat where distmat[i,j] represents the distance from city i to city j. The matrix needn't be
symmetric and possibly could contain negative values, though nonpositive values have not been tested.


Optional arguments:

firstCity (Int): specifies the city to begin the path on. Not specifying a value corresponds to random selection. 
	
closepath: boolean for whether to include the arc from the last city visited back to the first city in
	cost calculations. If true, the first city appears first and last in the path. Defaults to true.
	
do2opt: whether to refine the path found by 2-opt switches (corresponds to removing path crossings in
	the planar Euclidean case). Defaults to true.
	
returns a tuple (path, pathcost) where path is a Vector{Int} corresponding to the order of cities visited
"""
function nearest_neighbor{T<:Real}(distmat::Matrix{T};
							       firstcity::Union{Int, Nullable{Int}} = rand(1:size(distmat, 1)),
							       repetitive::Bool = false,
							       closepath::Bool = true,
							       do2opt::Bool = true)
	# must have a square matrix 
	numCities = check_square(distmat, "Must pass a square distance matrix to nearest_neighbor")
	
	# for backward compatibility, firstcity can be Int or Nullable{Int}
	# extract an int value
	if isa(firstcity, Int)
		firstcityint = firstcity
	else # Nullable{Int}
		warn("Calling `nearest_neighbor` with firstcity a Nullable{Int} is deprecated;" * 
		     " pass the Int directly. A random city is used if no city is specified.")
		firstcityint = isnull(firstcity) ? rand(1:numCities) : get(firstcity)
	end
	
	# calling with KW repetitive is deprecated; pass the call to repetitive_heuristic
	if repetitive
		warn("Calling `nearest_neighbor` with keyword `repetitive` is deprecated;'" *
		     " instead call `repetitive_heuristic(distmat, nearest_neighbor; kwargs...)`")
		return repetitive_heuristic(distmat, nearest_neighbor;
		                            closepath = closepath, do2opt = do2opt)
	end
		
	# put first city on path
	path = Vector{Int}()
	push!(path, firstcityint)
	
	# cities to visit
	citiesToVisit = collect(1:(firstcityint - 1))
	append!(citiesToVisit, collect((firstcityint + 1):numCities))
	
	# nearest neighbor loop
	while !isempty(citiesToVisit)
		curCity = path[end]
		dists = distmat[curCity, citiesToVisit]
		_, nextInd = findmin(dists)
		nextCity = citiesToVisit[nextInd]
		push!(path, nextCity)
		deleteat!(citiesToVisit, nextInd)
	end
	
	# complete cycle? (duplicates first city)
	if closepath
		push!(path, firstcityint)
	end
	
	# do swaps?
	if do2opt
		path, _ = two_opt(distmat, path)
	end
	
	return (path, pathcost(distmat, path))
end

"""
.. cheapest_insertion(distmat, initpath) ..


Given a distance matrix and an initial path, complete the tour by
repeatedly doing the cheapest insertion. The initial path must have length at least 2, but can be
simply [i, i] for some city index i which corresponds to starting with a self-loop at city i.
Insertions are always in the interior of the current path so this heuristic can also be used for
non-closed TSP paths.
Currently the implementation is a naive n^3 algorithm.
"""
function cheapest_insertion{T<:Real}(distmat::Matrix{T}, initpath::Vector{Int})
	check_square(distmat, "Distance matrix passed to cheapest_insertion must be square.")
	
	n = size(distmat, 1)
	path = copy(initpath)
	
	# collect cities to visited
	visitus = setdiff(collect(1:n), initpath)
	
	while !isempty(visitus)
		bestCost = Inf
		bestInsertion = (-1, -1)
		for k in visitus
			for after in 1:(length(path) - 1) # can't insert after end of path
				c = inscost(k, after, path, distmat)
				if c < bestCost
					bestCost = c
					bestInsertion = (k, after)
				end
			end
		end
		# bestInsertion now holds (k, after)
		# insert into path, remove from to-do list
		k, after = bestInsertion
		insert!(path, after + 1, k)
		visitus = setdiff(visitus, k)
	end
	
	return (path, pathcost(distmat, path))
end
"""
.. cheapest_insertion(distmat; ...) ..


Cheapest insertion with a self-loop as the initial path. 
`distmat` must be a square real matrix. Non-symmetric distance matrices are fine; negative
distances have not been tested but should also work.

Optional arguments:

firstCity (Int): specifies the city to begin the path on. Not specifying a value corresponds to random selection.

do2opt: boolean for whether to improve the paths found by 2-opt swaps. Defaults to true.
"""
function cheapest_insertion{T<:Real}(distmat::Matrix{T};
								     firstcity::Union{Int, Nullable{Int}} = rand(1:size(distmat, 1)),
							         repetitive::Bool = false,
								     do2opt::Bool = true)
	#infer size
	n = size(distmat, 1)

	# calling with KW repetitive is deprecated; pass the call to repetitive_heuristic
	if repetitive
		warn("Calling `cheapest_insertionr` with keyword `repetitive` is deprecated;'" *
		     " instead call `repetitive_heuristic(distmat, cheapest_insertion; kwargs...)`")
		return repetitive_heuristic(distmat, cheapest_insertion; do2opt = do2opt)
	end
	
	# for backward compatibility, firstcity can be Int or Nullable{Int}
	# extract an int value
	if isa(firstcity, Int)
		firstcityint = firstcity
	else # Nullable{Int}
		warn("Calling `nearest_neighbor` with firstcity a Nullable{Int} is deprecated;" * 
		     " pass the Int directly. A random city is used if no city is specified.")
		firstcityint = isnull(firstcity) ? rand(1:n) : get(firstcity)
	end
	
	# okay, we're not repetitive. Do we pick first city at random?
	path, cost = cheapest_insertion(distmat, [firstcityint, firstcityint])
	
	# user may have asked for 2-opt refinement
	if do2opt
		path, cost = two_opt(distmat, path)
	end
	
	return path, cost
end

"""
.. farthest_insertion(distmat; ...) ..

Farthest insertion strategy for path generation. `distmat` must be a square real matrix but need not be symmetric.

Optional arguments:

firstCity (Int): specifies the city to begin the path on. Not specifying a value corresponds to random selection.

do2opt (Bool): whether to improve the path by 2-opt swaps. Defaults to true."""
function farthest_insertion{T<:Real}(distmat::Matrix{T};
                                     firstcity::Int = rand(1:size(distmat, 1)), do2opt::Bool = true)
	n = check_square(distmat, "Must pass square distance matrix to farthest_insertion.")
	if firstcity < 1 || firstcity > n
		error("First city for farthest_insertion must be in [1,..,n]")
	end
	smallval = minimum(distmat) - one(T) # will never be the max
	
	path = Int[firstcity, firstcity]
	sizehint!(path, n)
	dists_to_tour = (distmat[firstcity, :] + distmat[:, firstcity]) / 2
	dists_to_tour[firstcity] = smallval
	
	while length(path) < n + 1
		# city farthest from tour
		_, nextcity = findmax(dists_to_tour)
		
		# find where to add it
		bestcost = inscost(nextcity, 1, path, distmat)
		bestind = 1
		for ind in 2:(length(path) - 1)
			altcost = inscost(nextcity, ind, path, distmat)
			if altcost < bestcost
				bestcost = altcost
				bestind = ind
			end
		end
		# and add the next city at the best spot found
		insert!(path, bestind + 1, nextcity) # +1 since arg to insert! is where nextcity ends up
		
		# update distances to tour
		dists_to_tour[nextcity] = smallval
		for i in 1:n
			c = dists_to_tour[i]
			if c == zero(T) # i already in tour
				continue
			end
			altc = (distmat[i, nextcity] + distmat[nextcity, i]) / 2 # cost i--nextcity
			if altc < c
				@inbounds dists_to_tour[i] = altc
			end
		end
	end
	
	if do2opt
		path, _ = two_opt(distmat, path)
	end
	
	return path, pathcost(distmat, path)
end
	
###
# path improvement heuristics
###

"perform 2-opt reversals until doing so does not improve the path cost

First argument is the distance matrix, second is the path to be improved."
function two_opt{T<:Real}(distmat::Matrix{T}, path::Vector{Int})
	# size checks
	n = length(path)
	if size(distmat, 1) != size(distmat, 2)
		error("Distance matrix passed to two_opt must be square.")
	end
	
	# don't modify input
	path = copy(path) # Int is a bitstype
	
	# main loop
	# check every possible switch until no 2-swaps reduce objective
	# if the path passed in is a loop (first/last nodes are the same)
	# then we must keep these the endpoints of the path the same
	# ie just keep it a loop, and therefore it doesn't matter which node is at the end
	# if the path is not a cycle, we should respect the endpoints
	switchLow = 2
	switchHigh = n - 1
	prevCost = Inf
	curCost = pathcost(distmat, path)
	while prevCost > pathcost(distmat, path)
		prevCost = curCost
		# we can't change the first 
		for i in switchLow:(switchHigh-1)
			for j in switchHigh:-1:(i+1)
				altCost = pathcost_rev(distmat, path, i, j)
				if altCost < curCost
					curCost = altCost
					reverse!(path, i, j)
				end
			end
		end
	end
	return path, pathcost(distmat, path)
end

end # module
