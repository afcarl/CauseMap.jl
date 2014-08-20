module CauseMap
using Base.LinAlg.BLAS 
using PyCall


export makesingleplot, makeoptimizationplots, optandcalcCCM, precalc_manif_dists, calcCCM


function _sqsum(a)
    m, n = size(a)
    ans = Array(Float64, n, 1)
    for i = 1:n
        ans[i] = sum(abs2(a[:, i]))
    end
    return(ans)
end

# The function below is adapted from Dahua Lin's blog post here: http://julialang.org/blog/2013/09/fast-numeric/
function vecdist(a1::Array{Float64, 2}, a2::Array{Float64, 2})
    m, n = size(a1)
    sa = _sqsum(a1)
    sb = _sqsum(a2)
    r = sa .+ reshape(sb, 1, n)
    
    #Update C as alpha*A*B + beta*C
    # or the other three variants according to tA (transpose A) and tB. Returns the updated C.
    gemm!('T', 'N', -2.0, a1, a2, 1.0, r)
    for i = 1:length(r)
        if r[i] < 0
            if r[i] > -1e-9
                r[i] = 0
            else
                error("Negative squared distance in vecdist")
            end
        else
            r[i] = sqrt(r[i])
        end
    end
    return(r)
end


### functions for attractor reconstruction and distance calculation
function calc_dists(shadowmat::Array{Float64,2})
    return vecdist(shadowmat, shadowmat)
    #return sqrt(pairwise(SqEuclidean(), shadowmat))
end


function precalc_manif_dists(Evals::AbstractVector{Int64}, tau_vals::AbstractVector{Int64}, vector::AbstractVector)
    shadowmats = (Int64=>Dict)[tt => (Int64=>Array{Float64,2})[E => construct_shadow(vector, E, tt) for E in Evals] for tt in tau_vals]
    distmats   = (Int64=>Dict)[tt => (Int64=>Array{Float64,2})[E => calc_dists(shadowmats[tt][E]) for E in Evals] for tt in tau_vals]
    return shadowmats, distmats
end


function construct_shadow(vector::AbstractVector, E::Int64, tau_s::Int64=1)
    if tau_s < 1
        throw(ArgumentError("tau_s must be greater than 0!"))
    end
    n::Int64   = length(vector)
    lag::Int64 = 0
    shadowmat  = nans(Float64, E, n)
    
    for ii in 1:E
        shadowmat[ii, (lag+1):n] = vector[1:(n-lag)]
        lag += tau_s
    end
    return shadowmat
end
#### End attractor reconstruction and distance calculation functions

function processpredvals_simple(predvals::Array{Float64,2}, targvals::Vector{Float64})
    nanval = NaN

    if all(isnan(predvals))
        println("All predvals were NaN in process predvals")
        return nanval
    end
    rhos = nans(Float64, size(predvals,2))
    
    for xx in 1:size(predvals,2)
        touse = !isnan(predvals[:,xx]) & !isnan(targvals)
        
        if sum(touse) < 10
            rhos[xx] = NaN
            println("Not enough predvals present for lib size of $lib_size !")
            println("$(predvals[:,xx])")
        else
            rhos[xx] = cor(predvals[touse,xx], targvals[touse])
            if isnan(rhos[xx])
                warn("in process predvals, why is rho nan?")
            end
        end
    end
    
    
    


    toret = !isnan(rhos)
    if sum(toret) > 0
        return median(rhos[toret])
    else
        println("no non-nan values")
        return nanval
    end

end

# function processpredvals(predvals::Array{Float64,2}, targvals::Vector{Float64}, min_distances::Array{Float64,2},
#     nobs::Int64, lib_start::Int64, lib_size::Int64, npred::Int64, pred_start_min::Int64)
    
#     nanval = NaN

#     if all(isnan(predvals))
#         println("All predvals were NaN in process predvals")
#         return nanval
#     end
#     rhos         = nans(Float64, size(predvals,2))
#     loopedstarts = lib_start:(nobs-lib_size)
    
#     for xx in 1:size(predvals,2)
#         ll = loopedstarts[xx]
#         predstart, predstop = getpredstartstop(nobs, ll, lib_size, npred, pred_start_min)
#         touse = !isnan(predvals[:,xx]) & !isnan(targvals[predstart:predstop])
        
#         if sum(touse) < 10
#             rhos[xx] = NaN
#             println("Not enough predvals present for lib size of $lib_size !")
#             println("$(predvals[:,xx])")
#         else
#             rhos[xx] = cor(predvals[touse,xx], targvals[predstart:predstop][touse])
#             if isnan(rhos[xx])
#                 warn("in process predvals, why is rho nan?")
#             end
#         end
#     end

#     toret = !isnan(rhos)
#     if sum(toret) > 0
#         return median(rhos[toret])
#     else
#         println("no non-nan values")
#         return nanval
#     end
# end


function weightfunc(distances::Array{Float64}; kernelargs...)
    w = [exp(-d) for d in distances]
    return w / sum(w)
end


function getdist!(dist_top::Vector{Float64}, inds_touse::AbstractVector{Int64}, num_neighbors::Int) 
    if dist_top[1] == 0
        for xx in 1:num_neighbors
            if xx == 1
                dist_top[xx] = 1
            else
                dist_top[xx] = 1e200
            end
        end
        return 1e-100
    else
        min_dist::Float64 = dist_top[1]
        for xx in num_neighbors:-1:1
            dist_top[xx] = dist_top[xx] / min_dist
        end
        return min_dist
    end
end


function getpredstartstop(nobs::Int, ll::Int, lib_size::Int, npred::Int, pred_start_min::Int64)
    left::Int64 = iceil(npred / 2)
    right::Int64 = npred - left - 1
    midpoint::Int64 = iceil(ll + lib_size / 2)
    lp::Int64 = midpoint - left
    rp::Int64 = midpoint + right

    if lp < pred_start_min
        rp += (pred_start_min - lp)
        lp  = pred_start_min
    end

    if rp > nobs
        lp -= rp % nobs
        rp  = nobs
    end
    
    if (rp - lp + 1) != npred
        error("start and stop not equal to npred")
    end

    return lp, rp
end


### this function accounts for ~70% of algorithm run time
function calcdistslice!(source_dists::Array{Float64, 2}, dist_top::Vector{Float64}, slice_inds::AbstractVector{Int64}, topred::Int64, nn::Range1{Int64})    
    if in(topred, slice_inds)
        slice_inds = convert(Vector{Int64}, slice_inds)
        splice!(slice_inds, findfirst([yy == topred for yy in slice_inds])) # remove topred, but don't move any of the preceding elements in the array
    end

    # this line accounts for ~60% of algorithm run time
    inds_touse::Vector{Int64} = slice_inds[sortperm(source_dists[slice_inds, topred])[nn]] 
    for xx in nn
        dist_top[xx] = source_dists[inds_touse[xx], topred]
    end
    return inds_touse   
end


function prepgetpred(source_manifold, lib_start, lib_size, tau_p, npred, num_neighbors; nboots=0)
    nobs::Int64 = size(source_manifold, 2)
    lib_stop::Int64 = nobs - lib_size - tau_p
    nlib::Int64 = lib_stop - lib_start + 1
    if nlib < 1
        println("No libs of this size in dataset. Lib_start is $lib_start, lib_stop is $lib_stop")
        return nans(1,1), nans(1,1)
    end

        if nboots > 0
        min_distances = nans(Float64, npred, nboots)
        predvals = nans(Float64, npred, nboots)
        targvals = nans(Float64, npred)
    else
        # min_distances = nans(Float64, npred, nobs - lib_start - lib_size + 1)
        min_distances = nans(Float64, npred, nlib)
        predvals = nans(Float64, npred, nlib)
        targvals = nans(Float64, npred)
    end
    lib_end::Int64 = lib_start + lib_size - 1
    dist_top = nans(Float64, num_neighbors)
    return nobs, lib_stop, nlib, predvals, targvals, min_distances, lib_end, dist_top
end


function getpredvals_boot(source_manifold::Array{Float64,2}, source_dists::Array{Float64,2},
     target_series::Vector{Float64}, lib_size::Int64,
     lib_start::Int64, num_neighbors::Int64, 
     tau_p::Int64, npred::Int64, pred_start_min::Int64, nboots::Int64)
#     # Use bootstrap samples to generate libraries

    nobs, lib_stop, nlib, predvals, targvals, min_distances, lib_end, dist_top = prepgetpred(source_manifold,
                                                                                                                                lib_start, lib_size, 
                                                                                                                                tau_p, npred, num_neighbors; 
                                                                                                                                nboots=nboots)
    # lib_stop is the last possible sliding window START index (stop of the start..confusing...)
    # lib_end is the last in the current window
    nn = 1:num_neighbors
    for pp in 1:npred
        topred = rand(pred_start_min:length(target_series))
        targvals[pp] = target_series[topred]
        for xx in 1: nboots  
            slice_inds::Array{Int64, 1} = [rand(lib_start:lib_stop) for xx in 1:lib_size]
            inds_touse = calcdistslice!(source_dists, dist_top, slice_inds, topred, nn)   
            min_distances[pp, xx] = getdist!(dist_top, inds_touse, num_neighbors)
            weights = weightfunc(dist_top)
            predvals[pp, xx] = dot(weights, target_series[inds_touse + tau_p])   
        end        
    end
    rhos = processpredvals_simple(predvals, targvals)
    return predvals, min_distances, rhos
end


function getpredvals_sw(source_manifold::Array{Float64,2}, source_dists::Array{Float64,2},
    target_series::Vector{Float64}, lib_size::Int64,
    lib_start::Int64, num_neighbors::Int64, 
    tau_p::Int64, npred::Int64, pred_start_min::Int64)
    # Use a sliding window for your library. This is the traditional form of CCM

    nobs, lib_stop, nlib, predvals, targvals, min_distances, lib_end, dist_top = prepgetpred(source_manifold,
                                                                                                                                lib_start, lib_size, 
                                                                                                                                tau_p, npred, num_neighbors)
    # lib_stop is the last possible sliding window START index (stop of the start..confusing...)
    # lib_end is the last in the current window

    nn = 1:num_neighbors
    
    start_count::Int = 1
    for ll in lib_start:lib_stop
        ll_end::Int64     = ll + lib_size - 1
        slice_inds = ll:ll_end
        predstart, predstop = getpredstartstop(nobs, ll, lib_size, npred, pred_start_min)
        
        pred_count::Int=1
        for topred in predstart:predstop
            slice_inds = ll:ll_end
            inds_touse = calcdistslice!(source_dists, dist_top, slice_inds, topred, nn)
            
            min_distances[pred_count, start_count] = getdist!(dist_top, inds_touse, num_neighbors)
            
            weights = weightfunc(dist_top)
            predvals[pred_count, start_count] = dot(weights, target_series[inds_touse+tau_p])
            targvals[pred_count] = target_series[topred]
            pred_count += 1
        end
        start_count += 1
        lib_end += 1
    end
    rhos = processpredvals_simple(predvals, targvals)
    return predvals, min_distances, rhos
end


function cross_mapping(source_manif_dict::Dict, source_dist_dict::Dict, 
    target_series::AbstractVector,
    nobs::Int64,
    libsizemin::Int64, libsizemax::Int64, E::Int64,
    tau_s::Int64, tau_p::Int64, npred::Int64, 
    pred_start_min::Int64, num_neighbors, args...; lib_start::Int64=0, nboots=0)
    

    res12 = nans(Float64, libsizemax-libsizemin+1)
    count = 1

    nlibpluslibsize = nobs - tau_p - lib_start + 1

    for lib_size in libsizemin:libsizemax
        nlib = nlibpluslibsize - lib_size
        if nboots > 0
            predvals, min_distances, rhos = getpredvals_boot(source_manif_dict[tau_s][E], source_dist_dict[tau_s][E], 
                                target_series, lib_size, lib_start, num_neighbors, tau_p, npred, pred_start_min, nboots)
        else
            predvals, min_distances, rhos = getpredvals_sw(source_manif_dict[tau_s][E], source_dist_dict[tau_s][E], 
                                target_series, lib_size, lib_start, num_neighbors, tau_p, npred, pred_start_min)
        end
        res12[count] = rhos # processpredvals(predvals, target_series, min_distances, nobs, lib_start, lib_size, npred, pred_start_min)

        count += 1
    end
    if count == 1
        warn("Why was there no loop?")
    end
    return res12
end


function calclibstart(shadowmat_dict::Dict, E::Int64, tau_s::Int64)
    nanrows::Array{Bool, 1} = [in(NaN, shadowmat_dict[tau_s][E][:,xx]) for xx in 1:size(shadowmat_dict[tau_s][E],2)]
    return (maximum(find(nanrows)) + 1)
end


function calcCCM(var1::AbstractVector, var2::AbstractVector,
    shadowmat_dict::Dict, distmat_dict::Dict, libsizemin::Int64, libsizemax::Int64,
    E::Int64, tau_s::Int64, tau_p::Int64, npred::Int64, pred_start::Int64; 
    lib_start::Int64=0, b_offset::Int64=1, quick=false, nlag=10, nboots=0)

    nobs = length(var1)
    num_neighbors = E + b_offset

    ################## clean input parameters
    libsizemin::Int64 = max(libsizemin, E+b_offset+1)
    
    if lib_start == 0 
        lib_start = calclibstart(shadowmat_dict, E, tau_s)
    end 

    libsizemax::Int64 = min(libsizemax, nobs-tau_p-lib_start)
    pred_start::Int64 = max(lib_start, pred_start)
    if quick 
        libsizemin = max(E+b_offset+1, libsizemax-nlag)
    end
    #########
    ##### Raise error or warning messages as needed.
    if libsizemin > libsizemax
        println("Libsizemin, libsizemax: ($libsizemin, $libsizemax)")
        println("E, tau_s, tau_p, nobs, lib_start : ($E, $tau_s, $tau_p, $nobs, $lib_start)")
        warn("why is libsizemin less than libsizemax? returning NaN")
        return 0:0, nans(1)
    end
    if pred_start + npred - 1 > nobs
        npred -= (pred_start + npred - 1) - nobs
    end
    ###################
    res12 = cross_mapping(shadowmat_dict, distmat_dict, var2, nobs, libsizemin, libsizemax, E,
                            tau_s, tau_p, npred, pred_start, num_neighbors; lib_start = lib_start, nboots=nboots)

    return libsizemin:libsizemax, res12
end


function optandcalcCCM(vec1::AbstractVector, vec2::AbstractVector, 
    libsizemin::Int64, libsizemax::Int64, E_vals::AbstractVector,  
    tau_s_vals::AbstractVector, tau_p_vals::AbstractVector, npred::Int64, 
    pred_start::Int64; nreps=5, b_offset=1, nboots=0)
    """
    vec1: Time series 1
    vec2: Time series 2
    libsizemin: Minimum library size
    libsizemax: Maximum library size
    E_vals: A vector of dimensions to try
    tau_s_vals: A vector of lag lengths to use for manifold reconstruction
    tau_p_vals: A vector of lag lengths to try for the causal effect 
    npred: Number of points to predict 
    pred_start: First point to predict
    ## kwargs
    nreps: Number of coordinate descent runs
    """

    shadowmat_dict_vec1, distmat_dict_vec1 = precalc_manif_dists(E_vals, tau_s_vals, vec1)
    shadowmat_dict_vec2, distmat_dict_vec2 = precalc_manif_dists(E_vals, tau_s_vals, vec2)

    println("CoordDescentOpt opt1")
    res12 = CoordDescentOpt(vec1, vec2, shadowmat_dict_vec1, distmat_dict_vec1, libsizemin, 
                                                libsizemax, E_vals, tau_s_vals, tau_p_vals, npred, pred_start; nreps=nreps, nboots=nboots)
    println("CoordDescentOpt opt2")
    res21 = CoordDescentOpt(vec2, vec1, shadowmat_dict_vec2, distmat_dict_vec2, libsizemin, 
                                                libsizemax, E_vals, tau_s_vals, tau_p_vals, npred, pred_start; nreps=nreps, nboots=nboots)
    libsizemin_12 = max(res12["E"]+b_offset+1,10)
    libsizemin_21 = max(res21["E"]+b_offset+1,10)
    println("starting calcCCM1")
    librange12, yval_12 = calcCCM(vec1, vec2, shadowmat_dict_vec1, distmat_dict_vec1, libsizemin_12, libsizemax, 
                            res12["E"], res12["tau_s"], res12["tau_p"], npred, pred_start; nboots=nboots)
    println("starting calcCCM2")
    librange21, yval_21 = calcCCM(vec2, vec1, shadowmat_dict_vec2, distmat_dict_vec2, libsizemin_21, libsizemax, 
                            res21["E"], res21["tau_s"], res21["tau_p"], npred, pred_start; nboots=nboots)

    return (librange12, yval_12), (librange21, yval_21)
end
########## end CCM functions


########### start optimization functions
function CoordDescentOpt(source_series::Vector{Float64}, target_series::Vector{Float64}, shadowmat_dict::Dict, distmat_dict::Dict,
    libsizemin::Int64, libsizemax::Int64,
    E_vals::AbstractVector{Int64}, tau_s_vals::AbstractVector{Int64},
    tau_p_vals::AbstractVector{Int64}, npred::Int64, pred_start::Int64; nreps = 5, nboots=0)
    bestres=Dict()
    count = 0
    for xx in 1:nreps
        res12, evalcount = _CoordDescentOpt(source_series, target_series, shadowmat_dict, distmat_dict,
                    libsizemin, libsizemax,
                    E_vals, tau_s_vals,
                    tau_p_vals, npred, pred_start; nboots=nboots)
        count += evalcount
        if xx == 1
            bestres = res12
        elseif res12["rho"] > bestres["rho"]
            bestres = res12
        end
    end
    println("Finished $(count) CCM evaluations")
    return bestres
end

    
function _CoordDescentOpt(source_series::Vector{Float64}, target_series::Vector{Float64}, shadowmat_dict::Dict, distmat_dict::Dict,
    libsizemin::Int64, libsizemax::Int64,
    E_vals::AbstractVector{Int64}, tau_s_vals::AbstractVector{Int64},
    tau_p_vals::AbstractVector{Int64}, npred::Int64, pred_start::Int64; nboots=0)

    E_vals     = convert(Vector{Int64}, E_vals)
    tau_s_vals = convert(Vector{Int64}, tau_s_vals)
    tau_p_vals = convert(Vector{Int64}, tau_p_vals)

    toopt = ["E"; "tau_s"; "tau_p"]

    current_vals = {"E"=>E_vals[1], "tau_s"=> tau_s_vals[1], "tau_p"=>tau_p_vals[1]}
    librange, res12 = calcCCM(source_series, target_series, shadowmat_dict, distmat_dict, libsizemin, 
                                libsizemax, current_vals["E"], current_vals["tau_s"], current_vals["tau_p"], npred, pred_start; quick=true)
    rhoinit = getrho(res12)
    best_vals = merge(current_vals, ["rho"=>rhoinit])
    
    all_vals = ["E"=>E_vals, "tau_s"=>tau_s_vals, "tau_p"=>tau_p_vals]

    iternum = 1
    count = 0
    while true
        var_count = 0
        println("========Starting iteration $iternum===========")
        for var in shuffle(toopt)
            nochange_bool, evalcount = optvar(source_series, target_series, shadowmat_dict, distmat_dict, 
                                                                    all_vals, current_vals, best_vals, var, libsizemax, npred, pred_start; nboots=nboots)
            count += evalcount
            current_vals[var] = best_vals[var][1] # make sure optimization of next variable is done with best value of this one

            if nochange_bool
                var_count += 1
            end
        end

        if var_count == size(toopt, 1)  # check for convergence (all variables unchanged)
            break
        end
        iternum += 1
    end
    return best_vals, count
end
### end functions for CoordDescentOpt optimization

function calclibsizemax(source_series::AbstractVector, E::Int64, tau_s::Int64, tau_p::Int64)
    return ifloor(length(source_series)/tau_s) - E - tau_p
end


function getrho(rhos::AbstractArray)
    rhos = rhos[!isnan(rhos)]   
    if length(rhos) > 0
        rho = median(rhos)
    else
        rho = NaN
    end
    return rho
end


function optvar(source_series::AbstractVector, target_series::AbstractVector, shadowmat_dict::Dict, 
    distmat_dict::Dict, all_vals::Dict, current_vals::Dict, 
    best_vals::Dict, var::ASCIIString, libsizemax::Int64, npred::Int64, pred_start::Int64; nlag::Int64=10, b_offset=1, nboots=0)
    
    
    if length(all_vals[var]) < 2
        return true, 0
    end
    count::Int64= 0
    looplist     = shuffle(setdiff(all_vals[var], current_vals[var]))
    val_count::Int64    = 0
    update_count::Int64 = 0
    for val in looplist
        current_vals[var] = val # update variable of interest
        libsizemax = min(libsizemax, calclibsizemax(source_series, current_vals["E"], current_vals["tau_s"], current_vals["tau_p"]))
        libsizemin = max(current_vals["E"] + b_offset + 1, libsizemax-nlag)
        librange, res12 = calcCCM(source_series, target_series, shadowmat_dict, 
                                distmat_dict,libsizemin, libsizemax, current_vals["E"], 
                                current_vals["tau_s"], current_vals["tau_p"], npred, pred_start; quick=true, nboots=nboots)
        rho = getrho(res12)
        if rho > best_vals["rho"] # update best value if you have an improvement
            best_vals[var] = val
            best_vals["rho"] = rho
            update_count += 1
        else
            val_count += 1
        end
        count += 1 
    end

    if val_count + update_count !=length(looplist)
        error("Missing iteration in _optvar!!") 
    end

    if val_count == size(all_vals[var],1)-1
        return true, count
    else
        return false, count
    end
end
#### End CoordDescentOpt optimization functions


############# start plot functions
function makesingleplot(vec1::AbstractVector, vec2::AbstractVector, libsizemin::Int64, libsizemax::Int64, E::Int64, 
    tau_s::Int64, tau_p::Int64, npred::Int64, pred_start::Int64, 
    var1name::ASCIIString, var2name::ASCIIString; lib_start::Int64=1, 
    xmin=false, xmax=false, ymin=false, ymax=false)
    """
    vec1: Time series 1
    vec2: Time series 2
    libsizemin: Minimum library size
    ibsizemax: Maximum library size
    E: System dimensionality
    tau_s: Lag for manifold reconstruction 
    tau_p: Lag for causal effect
    npred: Number of points to predict
    pred_start: Start for prediction 
    var1name: Name of first variable
    var2name: Name of second variable
    lib_start: Start of library
    """
    shadowmat_dict_vec1, distmat_dict_vec1 = precalc_manif_dists(3:3, 1:1, vec1)
    shadowmat_dict_vec2, distmat_dict_vec2 = precalc_manif_dists(3:3, 1:1, vec2)

    librange12, yval_12 = calcCCM(vec1, vec2, shadowmat_dict_vec1, distmat_dict_vec1, libsizemin, libsizemax, 
                                    E, tau_s, tau_p, npred, pred_start; lib_start=lib_start)
    librange21, yval_21 = calcCCM(vec2, vec1, shadowmat_dict_vec2, distmat_dict_vec2, libsizemin, libsizemax, 
                                    E, tau_s, tau_p, npred, pred_start; lib_start=lib_start)

    plt.plot(librange12, yval_12, label = "$var2name influences $var1name?")
    plt.plot(librange21, yval_21, label = "$var1name influences $var2name?")
    plt.xlabel("L")
    plt.ylabel("\$\\rho_{cm}\$")
    plt.legend(loc="lower right")
    ax = plt.gca()
    ax[:xaxis][:set_ticks_position]("bottom")
    ax[:yaxis][:set_ticks_position]("left")
    if xmin != false
        ax[:set_xlim]((xmin, xmax))
    end
    if ymin != false
        ax[:set_ylim]((ymin, ymax))
    end
    plt.show()
end


function makeoptimizationplots(vec1::AbstractVector, vec2::AbstractVector, 
    libsizemin::Int64, libsizemax::Int64, E_vals::AbstractVector,  
    tau_s_vals::AbstractVector, tau_p_vals::AbstractVector, npred::Int64, 
    pred_start::Int64, var1name::ASCIIString, var2name::ASCIIString; 
    nreps=5, b_offset=1, ncols=28, left_E=false, left_tau_p=false, right_E=false, right_tau_p=false, lagunit=1, unit=false,
    imfont="medium", nboots=0)

    @pyimport matplotlib.pyplot as plt
    println("Calculating manifolds")
    shadowmat_dict_vec1, distmat_dict_vec1 = precalc_manif_dists(E_vals, tau_s_vals, vec1)
    shadowmat_dict_vec2, distmat_dict_vec2 = precalc_manif_dists(E_vals, tau_s_vals, vec2)

    println("\nCoordDescent opt1")
    res12 = CoordDescentOpt(vec1, vec2, shadowmat_dict_vec1, distmat_dict_vec1, libsizemin, libsizemax, 
                        E_vals, tau_s_vals, tau_p_vals, npred, pred_start; nreps=nreps, nboots=nboots)
    println("\nCoordDescent opt2")
    res21 = CoordDescentOpt(vec2, vec1, shadowmat_dict_vec2, distmat_dict_vec2, libsizemin, libsizemax, 
                        E_vals, tau_s_vals, tau_p_vals, npred, pred_start; nreps=nreps, nboots=nboots)
    
    libsizemin_12 = max(res12["E"] + b_offset + 1, 10)
    libsizemin_21 = max(res21["E"] + b_offset + 1, 10)
    
    println("\nstarting calcCCM1")
    librange12, yval_12 = calcCCM(vec1, vec2, shadowmat_dict_vec1, distmat_dict_vec1, libsizemin_12, libsizemax, 
                                    res12["E"], res12["tau_s"], res12["tau_p"], npred, pred_start)
    println("starting calcCCM2")
    librange21, yval_21 = calcCCM(vec2, vec1, shadowmat_dict_vec2, distmat_dict_vec2, libsizemin_21, libsizemax, 
                                    res21["E"], res21["tau_s"], res21["tau_p"], npred, pred_start)

    fig = plt.figure()

    label1 = "$(ucfirst(var2name)) influences $var1name?"
    label2 = "$(ucfirst(var1name)) influences $var2name?"
    
    rho1   = @sprintf("%.2f", res12["rho"])
    rho2   = @sprintf("%.2f", res21["rho"])
    
    stats1 = "($(res12["E"]), $(res12["tau_p"] * lagunit), $(res12["tau_s"]))"
    stats2 = "($(res21["E"]), $(res21["tau_p"] * lagunit), $(res21["tau_s"]))"


    ax1 = plt.subplot2grid((2,ncols), (0,0), rowspan=2, colspan=ifloor(ncols/3))
    ax1[:plot](librange12, yval_12, label="$label1\n$stats1")
    ax1[:plot](librange21, yval_21, label="$label2\n$stats2")
    ax1[:yaxis][:set_ticks_position]("left")
    ax1[:xaxis][:set_ticks_position]("bottom")
    ax1[:legend](loc=4, fontsize="x-small", title ="(\$E\$, \$\\tau_p\$, \$\\tau_s\$)")
    ax1[:set_ylabel]("\$\\rho_{cm}\$", fontsize="x-large")
    ax1[:set_xlabel]("L", fontsize="large", labelpad=12)

    ylabelpad = 12
    titlesize = "medium"
    labelsize = "small"
    
    mat12, Es12, taus12 = get_E_taupcurves(vec1, vec2, shadowmat_dict_vec1, distmat_dict_vec1, 
                                            libsizemax, res12["E"], res12["tau_s"], res12["tau_p"], E_vals, tau_p_vals, npred, pred_start; 
                                            left_E=left_E, left_tau_p=left_tau_p, right_E=right_E, right_tau_p=right_tau_p
                                                                    )
    
    mat21, Es21, taus21 = get_E_taupcurves(vec2, vec1, shadowmat_dict_vec2, distmat_dict_vec2,
                                            libsizemax, res21["E"], res21["tau_s"], res21["tau_p"], E_vals, tau_p_vals, npred, pred_start;
                                            left_E=left_E, left_tau_p=left_tau_p, right_E=right_E, right_tau_p=right_tau_p
                                                                    )

    println("Plotting data")
     

    catmat = vcat(mat12, mat21)
    if minimum(catmat) < 0
        vmin = 0
        llab = "\$\\leq 0\$"
    else
        vmin = minimum(catmat)
        llab = @sprintf("%.2f", vmin)
    end

    vmax = 1  # maximum correlation
    
    ax2 = plt.subplot2grid((2,ncols), (0,ifloor(ncols/3)), colspan=2*ifloor(ncols/3))
    
    ax2[:imshow](mat12, vmin=vmin, vmax=vmax, origin="lower")
    ax2[:set_title](label1, fontsize="medium")
    
    ax2[:xaxis][:set_ticks_position]("bottom")
    ax2[:yaxis][:set_ticks_position]("right")

    xticks = 0:(length(taus12)-1)
    ax2[:set_xticks](xticks[1:2:]) # take every other tick
    ax2[:set_yticks](0:(length(Es12)-1))

    ax2[:set_xticklabels]((taus12 * lagunit)[1:2:], fontsize=imfont)
    ax2[:set_yticklabels](Es12, fontsize=imfont)

    ax2[:set_xlim]((0, length(taus21)-1))
    ax2[:set_ylim]((0, length(Es21)-1))
    
    if unit != false
        xlabel = "\$\\tau_p\$\ ($unit)"
    else
        xlabel =  "\$\\tau_p\$"
    end

    ax2[:set_xlabel](xlabel, fontsize=imfont)
    ax2[:set_ylabel]("E", fontsize=imfont, labelpad = 12)


    ax3 = plt.subplot2grid((2,ncols), (1,ifloor(ncols/3)), colspan=2*ifloor(ncols/3))
    
    imax = ax3[:imshow](mat21, vmin=vmin, vmax=vmax, origin="lower")
    ax3[:set_title](label2, fontsize="medium")

    ax3[:xaxis][:set_ticks_position]("bottom")
    ax3[:yaxis][:set_ticks_position]("right")

    xticks = 0:(length(taus21)-1)
    ax3[:set_xticks](xticks[1:2:])
    ax3[:set_yticks](0:(length(Es21)-1))
    
    ax3[:set_xticklabels]((taus21 * lagunit)[1:2:], fontsize=imfont)
    ax3[:set_yticklabels](Es21, fontsize=imfont)

    ax3[:set_xlim]((0, length(taus21)-1))
    ax3[:set_ylim]((0, length(Es21)-1))

    
    ax3[:set_xlabel](xlabel, fontsize="medium")
    ax3[:set_ylabel]("E", fontsize="small", labelpad = 12)


    ax4 = plt.subplot2grid((2,ncols), (0,ncols-1), rowspan=2)
    cbar = fig[:colorbar](imax, cax=ax4, ticks=[vmin, vmax], format = "%.2f")
    cbar[:ax][:set_yticklabels]([llab, "\$1\$"], fontsize="large")
    cbar[:set_label]("\$max\\ \\rho_{cm}\$", fontsize="large", labelpad=2)
    cbar[:ax][:get_yaxis]()[:labelpad]=0
    plt.show()
end

function get_totest(val::Int64, numtotest::Int64, minval::Int64, maxval::Int64)
    if maxval - minval - 1 < numtotest
        println("Maxval and minval for E_taup curves are inconsistent with number to test")
        println("Fixing maxval")
        maxval = minval + numtotest - 1  
    end
    left::Int64  = val-iceil(numtotest/2) 
    right::Int64 = val+ifloor(numtotest/2)-1
    if left < minval
        right += (minval-left)
        left   = minval
    end

    if right >  maxval
        left -= right%maxval
        right = maxval
    end
    
    if right-left+1 != numtotest
        error("start and stop not equal to npred")
    elseif left < minval
        println("left: $left, right: $right, Max: $maxval, min: $minval.")
        error("Left value less than minval")
    end
    return left, right 
end


function get_E_taupcurves(source_series::AbstractVector, target_series::AbstractVector, shadowmat_dict::Dict,
                        distmat_dict::Dict, libsizemax::Int64, E::Int64, tau_s::Int64, tau_p::Int64, 
                        E_vals::AbstractVector, tau_p_vals::AbstractVector, npred::Int64, pred_start::Int64;  
                        nlag=10, b_offset=1, num_E=6, Estart=2, num_tau_p=14, tau_p_start=0,
                        left_E=false, left_tau_p=false, right_E=false, right_tau_p=false)

    num_E = min(maximum(E_vals) - Estart + 1, num_E)
    num_tau_p = min(maximum(tau_p_vals-tau_p_start+1), num_tau_p)

    if (typeof(left_E) == Bool) && (left_E == false)
        left_E, right_E = get_totest(E, num_E, Estart, maximum(E_vals))
    end
    
    if (typeof(left_tau_p) == Bool) && (left_tau_p == false)
        left_tau_p, right_tau_p = get_totest(tau_p, num_tau_p, tau_p_start, maximum(tau_p_vals))
    end

    res = nans(Float64, num_E, num_tau_p)

    for (count_E, Eval) in enumerate(left_E:right_E)
        println("\nCalculating CCM max for E: $Eval")
        for (count_tau_p, tau_p_val) in enumerate(left_tau_p:right_tau_p)
            # libsizemin will be ignored. libsizemax will be reduced if it is too large
            println("\ttau_p: $tau_p_val")
            librange, rhos = calcCCM(source_series, target_series, shadowmat_dict, distmat_dict, libsizemax-nlag, 
                                    libsizemax, Eval, tau_s, tau_p_val, npred, pred_start; quick=true) 
            rhos = rhos[!isnan(rhos)]
            
            if length(rhos) > 0
                rho = median(rhos)
            else
                rho = NaN
            end

            res[count_E, count_tau_p] = rho
        end
    end
    return res, left_E:right_E, left_tau_p:right_tau_p
end
######################### End plot functions

end # module
