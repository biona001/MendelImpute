"""
    haplopair(X, H)

Calculate the best pair of haplotypes in `H` for each individual in `X`. Assumes `X` 
does not have missing data. 

# Input
* `X`: `p x n` genotype matrix. Each column is an individual.
* `H`: `p * d` haplotype matrix. Each column is a haplotype.

# Output
* `happair`: optimal haplotype pairs. `X[:, k] ≈ H[:, happair[1][k]] + H[:, happair[2][k]]`.
* `hapscore`: haplotyping score. 0 means best. Larger means worse.
"""
function haplopair(
    X::AbstractMatrix,
    H::AbstractMatrix
    )

    p, n     = size(X)
    d        = size(H, 2)
    M        = zeros(eltype(H), d, d)
    N        = zeros(promote_type(eltype(H), eltype(X)), n, d)
    happair  = ones(Int, n), ones(Int, n)
    hapscore = zeros(eltype(N), n)
    haplopair!(X, H, M, N, happair, hapscore)

    return happair, hapscore
end

"""
    haplopair!(X, H, M, N, happair, hapscore)

Calculate the best pair of haplotypes in `H` for each individual in `X`. Overwite
`M` by `M[i, j] = 2dot(H[:, i], H[:, j]) + sumabs2(H[:, i]) + sumabs2(H[:, j])`,
`N` by `2X'H`, `happair` by optimal haplotype pair, and `hapscore` by
objective value from the optimal haplotype pair.

# Input
* `X`: `p x n` genotype matrix. Each row is an individual.
* `H`: `p x d` haplotype matrix. Each row is a haplotype.
* `M`: overwritten by `M[i, j] = 2dot(H[:, i], H[:, j]) + sumabs2(H[:, i]) +
    sumabs2(H[:, j])`.
* `N`: overwritten by `n x d` matrix `2X'H`.
* `happair`: optimal haplotype pair. `X[:, k] ≈ H[:, happair[k, 1]] + H[:, happair[k, 2]]`.
* `hapscore`: haplotyping score. 0 means best. Larger means worse.
"""
function haplopair!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    M::AbstractMatrix,
    N::AbstractMatrix,
    happair::Tuple{AbstractVector, AbstractVector},
    hapscore::AbstractVector
    )

    p, n, d = size(X, 1), size(X, 2), size(H, 2)

    # assemble M (upper triangular only)
    mul!(M, Transpose(H), H)
    for j in 1:d, i in 1:(j - 1) # off-diagonal
        M[i, j] = 2M[i, j] + M[i, i] + M[j, j]
    end
    for j in 1:d # diagonal
        M[j, j] *= 4
    end

    # assemble N
    mul!(N, Transpose(X), H)
    @simd for I in eachindex(N)
        N[I] *= 2
    end

    # computational routine
    haplopair!(happair, hapscore, M, N)

    # supplement the constant terms in objective
    @inbounds for j in 1:n
        @simd for i in 1:p
            hapscore[j] += abs2(X[i, j])
        end
    end

    return nothing
end

"""
    haplopair!(happair, hapscore, M, N)

Calculate the best pair of haplotypes in `H` for each individual in `X` using
sufficient statistics `M` and `N`.

# Input
* `happair`: optimal haplotype pair for each individual.
* `hapmin`: minimum offered by the optimal haplotype pair.
* `M`: `d x d` matrix with entries `M[i, j] = 2dot(H[:, i], H[:, j]) +
    sumabs2(H[:, i]) + sumabs2(H[:, j])`, where `H` is the haplotype matrix
    with haplotypes in columns. Only the upper triangular part of `M` is used.
* `N`: `n x d` matrix `2X'H`, where `X` is the genotype matrix with individuals
    in columns.
"""
function haplopair!(
    happair::Tuple{AbstractVector, AbstractVector},
    hapmin::Vector,
    M::AbstractMatrix,
    N::AbstractMatrix
    )

    n, d = size(N)
    fill!(hapmin, typemax(eltype(hapmin)))

    Threads.@threads for k in 1:d
        @inbounds for j in 1:k
            # loop over individuals
            for i in 1:n
                score = M[j, k] - N[i, j] - N[i, k]
                if score < hapmin[i]
                    hapmin[i], happair[1][i], happair[2][i] = score, j, k
                end
            end
        end
    end

    return nothing
end

#saves some subtraction compared to haplopair!, but this is slower presumable 
#because data not accessed in column major
# function haplopair2!(
#     happair::Tuple{AbstractVector, AbstractVector},
#     hapmin::Vector,
#     M::AbstractMatrix,
#     N::AbstractMatrix;
#     M_col_min::AbstractVector = zeros(eltype(N), size(N, 2)),
#     M_min_pos::AbstractVector = zeros(Int, size(N, 2))
#     )

#     n, d = size(N)

#     for i in 1:n
#         fill!(M_col_min, Inf)

#         #first find minimum entry in each columns
#         for k in 1:d
#             for j in 1:k
#                 new_score = M[j, k] - N[i, j]
#                 if new_score < M_col_min[k]
#                     M_col_min[k] = new_score 
#                     M_min_pos[k] = j #keep track which row the min occurred on
#                 end
#             end
#             M_col_min[k] -= N[i, k]
#         end

#         #store the results in correct place
#         score, col    = findmin(M_col_min)
#         hapmin[i]     = score
#         happair[1][i] = M_min_pos[col]
#         happair[2][i] = col
#     end

#     return nothing
# end

"""
    fillmissing!(X, H, haplopair)

Fill in missing genotypes in `X` according to haplotypes. Non-missing genotypes
remain same.

# Input
* `X`: `p x n` genotype matrix. Each column is an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `happair`: pair of haplotypes. `X[:, k] = H[:, happair[1][k]] + H[:, happair[2][k]]`.
"""
function fillmissing!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    happair::Tuple{AbstractVector, AbstractVector},
    )

    p, n = size(X)

    @inbounds for j in 1:n, i in 1:p
        if ismissing(X[i, j])
            X[i, j] = H[i, happair[1][j]] + H[i, happair[2][j]]
        end
    end

    return nothing
end

"""
    fillgeno!(X, H, happair)

Fill in genotypes according to haplotypes. Both missing and non-missing
genotypes may be changed.

# Input
* `X`: `p x n` genotype matrix. Each column is an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `happair`: pair of haplotypes. `X[:, k] = H[:, happair[1][k]] + H[:, happair[2][k]]`.
"""
function fillgeno!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    happair::Tuple{AbstractVector, AbstractVector}
    )

    @inbounds for j in 1:size(X, 2), i in 1:size(X, 1)
        X[i, j] = H[i, happair[1][j]] + H[i, happair[2][j]]
    end
    return nothing

end

"""
    initmissing(X, Xwork)

Initializes the matrix `Xfloat` where missing values of matrix `X` by `2 x` allele frequency.

# Input
* `X` is a `p x n` genotype matrix. Each column is an individual.
* `Xfloat` is the `p x n` matrix of X where missing values are filled by 2x allele frequency. 
"""
function initmissing!(
    X::AbstractMatrix;
    Xfloat::AbstractMatrix = zeros(Float32, size(X))
    )
    
    T = eltype(X)
    p, n = size(X)

    for i in 1:p
        # allele frequency
        cnnz = 0
        csum = zero(T)
        for j in 1:n
            if !ismissing(X[i, j])
                cnnz += 1
                csum += X[i, j]
            end
        end
        # set missing values to 2freq
        imp = csum / cnnz
        for j in 1:n
            if ismissing(X[i, j]) 
                Xfloat[i, j] = imp
            else
                Xfloat[i, j] = X[i, j]
            end
        end
    end

    return nothing
end

"""
    haploimpute!(X, H, M, N, happair, hapscore, maxiters=1, tolfun=1e-3)

Haplotying of genotype matrix `X` from the pool of haplotypes `H` and impute
missing genotypes in `X` according to haplotypes.

# Input
* `X`: `p x n` matrix with missing values. Each column is genotypes of an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `M`: overwritten by `M[i, j] = 2dot(H[:, i], H[:, j]) + sumabs2(H[:, i]) +
    sumabs2(H[:, j])`.
* `N`: overwritten by `n x d` matrix `2X'H`.
* `happair`: optimal haplotype pair. `X[:, k] ≈ H[:, happair[k, 1]] + H[:, happair[k, 2]]`.
* `hapscore`: haplotyping score. 0 means best. Larger means worse.
* `Xfloat`: copy of `X` where missing values are filled with mean. This engages in linear algebra for computing `N`
* `maxiters`: number of MM iterations. Default is 1.
* `tolfun`: convergence tolerance of MM iterations. Default is 1e-3.
"""
function haploimpute!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    M::AbstractMatrix,
    N::AbstractMatrix,
    happair::Tuple{AbstractVector, AbstractVector},
    hapscore::AbstractVector;
    Xfloat::AbstractMatrix = zeros(Float32, size(X)),
    maxiters::Int  = 1,
    tolfun::Number = 1e-3
    )

    obj = typemax(eltype(hapscore))
    initmissing!(X, Xfloat=Xfloat) #Xfloat[i, j] = X[i, j] on observed entries

    for iter in 1:maxiters

        # haplotyping
        haplopair!(Xfloat, H, M, N, happair, hapscore)

        # impute missing entries according to current haplotypes
        fillmissing!(X, H, happair)

        # CURRENTLY NOT COMPARING ERROR WITH IMPUTATION BY MEAN
        # println("discrepancy = $discrepancy")
        # convergence criterion
        # objold = obj
        # obj = sum(hapscore) - discrepancy
        # println("iter = $iter, obj = $obj")
        # if abs(obj - objold) < tolfun * (objold + 1)
        #     break
        # end
    end

    return nothing
end

"""
    phase(X, H, width=400, verbose=true)

Phasing (haplotying) of genotype matrix `X` from a pool of haplotypes `H`
by sliding windows.

# Input
* `X`: `p x n` matrix with missing values. Each column is genotypes of an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `width`: width of the sliding window.
* `verbose`: display algorithmic information.
"""
function phase(
    X::AbstractMatrix{Union{Missing, T}},
    H::AbstractMatrix{T},
    width::Int    = 400,
    verbose::Bool = true
    ) where T <: Real

    #set BLAS threads to 1 if more than 1 Julia threads
    Threads.nthreads() > 1 && BLAS.set_num_threads(1)

    people, snps, haplotypes = size(X, 2), size(X, 1), size(H, 2)
    # allocate working arrays
    M        = zeros(T, haplotypes, haplotypes)
    N        = zeros(T,     people, haplotypes)
    happair  = ones(Int, people), ones(Int, people)
    hapscore = zeros(T, people)
    phase    = [HaplotypeMosaicPair(snps) for i in 1:people]

    # no need for sliding window
    if snps ≤ 3width
        haploimpute!(X, H, M, N, happair, hapscore)
        for i in 1:people
            push!(phase[i].strand1.start, 1)
            push!(phase[i].strand1.haplotypelabel, happair[1][i])
            push!(phase[i].strand2.start, 1)
            push!(phase[i].strand2.haplotypelabel, happair[2][i])
        end
        return phase
    end

    # allocate working arrays
    Xwork = X[1:3width, :]
    Xwork_float = zeros(T, size(Xwork))
    # Hwork = view(H, 1:3width, :)
    Hwork = unique_haplotypes(H, 1:3width)
    happair_prev = deepcopy(happair)

    # number of windows
    windows = floor(Int, snps / width)

    # phase and impute window 1
    verbose && println("Imputing SNPs 1:$width")
    haploimpute!(Xwork, Hwork, M, N, happair, hapscore, Xfloat=Xwork_float)
    for i in 1:people
        push!(phase[i].strand1.start, 1)
        push!(phase[i].strand1.haplotypelabel, happair[1][i])
        push!(phase[i].strand2.start, 1)
        push!(phase[i].strand2.haplotypelabel, happair[2][i])
    end

    # first  1/3: ((w - 2) * width + 1):((w - 1) * width)
    # middle 1/3: ((w - 1) * width + 1):(      w * width)
    # last   1/3: (      w * width + 1):((w + 1) * width)
    for w in 2:(windows - 1)
        if verbose
            println("Imputing SNPs $((w - 1) * width + 1):$(w * width)")
        end
        # sync Xwork and Hwork with original data
        # Hwork = view(H, ((w - 2) * width + 1):((w + 1) * width), :)
        Hwork = unique_haplotypes(H, ((w - 2) * width + 1):((w + 1) * width))
        copyto!(Xwork, view(X, ((w - 2) * width + 1):((w + 1) * width), :))

        # phase current window
        copyto!(happair_prev[1], happair[1])
        copyto!(happair_prev[2], happair[2])
        haploimpute!(Xwork, Hwork, M, N, happair, hapscore, Xfloat=Xwork_float)

        # find optimal break points and record info into phase
        Hw12 = view(Hwork, 1:2width, :)
        for i in 1:people
            Xi = view(Xwork, 1:2width, i)
            (happair[1][i], happair[2][i]), bkpts =
                continue_haplotype(Xi, Hw12,
                (happair_prev[1][i], happair_prev[2][i]),
                (     happair[1][i],      happair[2][i]))
            # strand 1
            if bkpts[1] > -1 && bkpts[1] < 2width
                push!(phase[i].strand1.start, (w - 2) * width + 1 + bkpts[1])
                push!(phase[i].strand1.haplotypelabel, happair[1][i])
            end
            # strand 2
            if bkpts[2] > -1 && bkpts[2] < 2width
                push!(phase[i].strand2.start, (w - 2) * width + 1 + bkpts[2])
                push!(phase[i].strand2.haplotypelabel, happair[2][i])
            end
            # # for debug
            if verbose == true && i == 1
                println("happair = ($(happair[1][i]), $(happair[2][i]))")
                println("bkpts = $bkpts")
            end
        end
    end

    # phase last window
    if verbose
        println("Imputing SNPs $((windows - 1) * width + 1):$snps")
    end
    Xwork = X[((windows - 2) * width + 1):snps, :]
    # Hwork = view(H, ((windows - 2) * width + 1):snps, :)
    Hwork = unique_haplotypes(H, ((windows - 2) * width + 1):snps)
    copyto!(happair_prev[1], happair[1])
    copyto!(happair_prev[2], happair[2])
    haploimpute!(Xwork, Hwork, M, N, happair, hapscore, Xfloat=Xwork_float)

    # find optimal break points and record info to phase
    for i in 1:people
        (happair[1][i], happair[2][i]), bkpts =
        continue_haplotype(Xwork[:, i], Hwork,
            (happair_prev[1][i], happair_prev[2][i]),
            (happair[1][i], happair[2][i]))
        # strand 1
        if bkpts[1] > -1 && bkpts[1] < 2width
            push!(phase[i].strand1.start, (windows - 2) * width + 1 + bkpts[1])
            push!(phase[i].strand1.haplotypelabel, happair[1][i])
        end
        # strand 2
        if bkpts[2] > -1 && bkpts[2] < 2width
            push!(phase[i].strand2.start, (windows - 2) * width + 1 + bkpts[2])
            push!(phase[i].strand2.haplotypelabel, happair[2][i])
        end
    end

    return phase
end

"""
    continue_haplotype(X, H, happair_prev, happair_next)

Find the optimal concatenated haplotypes from unordered haplotype pairs in two
consecutive windows.

# Input
* `X`: an `n` vector of genotypes with {0, 1, 2} entries
* `H`: an `n x d` reference panel of haplotypes with {0, 1} entries
* `happair_prev`: unordered haplotypes `(i, j)` in the first window
* `happair_next`: unordered haplotypes `(k, l)` in the second window

# Output
* `happair_next_optimal`: optimal ordered haplotypes in the second window
* `breakpt`: break points in the ordered haplotypes
"""
function continue_haplotype(
    X::AbstractVector,
    H::AbstractMatrix,
    happair_prev::Tuple{Int, Int},
    happair_next::Tuple{Int, Int}
    )

    i, j = happair_prev
    k, l = happair_next

    # both strands match
    if i == k && j == l
        return (k, l), (-1, -1)
    end

    if i == l && j == k
        return (l, k), (-1, -1)
    end

    # only one strand matches
    if i == k && j ≠ l
        breakpt, errors = search_breakpoint(X, H, i, (j, l))
        return (k, l), (-1, breakpt)
    elseif i == l && j ≠ k
        breakpt, errors = search_breakpoint(X, H, i, (j, k))
        return (l, k), (-1, breakpt)
    elseif j == k && i ≠ l
        breakpt, errors = search_breakpoint(X, H, j, (i, l))
        return (l, k), (breakpt, -1)
    elseif j == l && i ≠ k
        breakpt, errors = search_breakpoint(X, H, j, (i, k))
        return (k, l), (breakpt, -1)
    end

    return (k, l), (0, 0)

end

"""
    search_breakpoint(X, H, s1, s2)

Find the optimal break point between s2[1] and s2[2] in configuration
s1 | s2[1]
s1 | s2[2]
"""
function search_breakpoint(
    X::AbstractVector,
    H::AbstractMatrix,
    s1::Int,
    s2::Tuple{Int, Int}
    )

    n = length(X)
    # count number of errors if second haplotype is all from H[:, s2[2]]
    errors = 0
    for pos in 1:n
        if !ismissing(X[pos])
            errors += X[pos] ≠ H[pos, s1] + H[pos, s2[2]]
        end
    end
    bkpt_optim, err_optim = 0, errors

    # quick return if perfect match
    err_optim == 0 && return 0, 0

    # extend haplotype H[:, s2[1]] position by position
    @inbounds for bkpt in 1:n
        if !ismissing(X[bkpt]) && H[bkpt, s2[1]] ≠ H[bkpt, s2[2]]
            errors -= X[bkpt] ≠ H[bkpt, s1] + H[bkpt, s2[2]]
            errors += X[bkpt] ≠ H[bkpt, s1] + H[bkpt, s2[1]]
            if errors < err_optim
                bkpt_optim, err_optim = bkpt, errors
                # quick return if perfect match
                err_optim == 0 && return bkpt_optim, err_optim
            end
        end
    end

    return bkpt_optim, err_optim
end

"""
    search_breakpoint(X, H, s1, s2)

Find the optimal break point between s2[1] and s2[2] in configuration
s1[1] | s2[1]
s1[2] | s2[2]
"""
function search_breakpoint(
    X::AbstractVector,
    H::AbstractMatrix,
    s1::Tuple{Int, Int},
    s2::Tuple{Int, Int}
    )

    err_optim   = typemax(Int)
    bkpts_optim = (0, 0)

    # search over all combintations of break points in two strands
    @inbounds for bkpt1 in 0:length(X)

        # count number of errors if second haplotype is all from H[:, s2[2]]
        errors = 0
        for pos in 1:bkpt1
            if !ismissing(X[pos])
                errors += X[pos] ≠ H[pos, s1[1]] + H[pos, s2[2]]
            end
        end
        for pos in (bkpt1 + 1):length(X)
            if !ismissing(X[pos])
                errors += X[pos] ≠ H[pos, s1[2]] + H[pos, s2[2]]
            end
        end
        if errors < err_optim
            err_optim = errors
            bkpts_optim = (bkpt1, 0)

            # quick return if perfect match
            err_optim == 0 && return bkpts_optim, err_optim
        end

        # extend haplotype H[:, s2[1]] position by position
        for bkpt2 in 1:bkpt1
            if !ismissing(X[bkpt2])
                errors -= X[bkpt2] ≠ H[bkpt2, s1[1]] + H[bkpt2, s2[2]]
                errors += X[bkpt2] ≠ H[bkpt2, s1[1]] + H[bkpt2, s2[1]]
                if errors < err_optim
                    err_optim = errors
                    bkpts_optim = (bkpt1, bkpt2)
                end
            end
        end
        for bkpt2 in (bkpt1 + 1):length(X)
            if !ismissing(X[bkpt2])
                errors -= X[bkpt2] ≠ H[bkpt2, s1[2]] + H[bkpt2, s2[2]]
                errors += X[bkpt2] ≠ H[bkpt2, s1[2]] + H[bkpt2, s2[1]]
                if errors < err_optim
                    err_optim = errors
                    bkpts_optim = (bkpt1, bkpt2)
                    # quick return if perfect match
                    err_optim == 0 && return bkpts_optim, err_optim
                end
            end
        end
    end

    return bkpts_optim, err_optim
end

function impute!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    phase::Vector{HaplotypeMosaicPair}
    )

    fill!(X, 0)
    # loop over individuals
    for i in 1:size(X, 2)
        for s in 1:(length(phase[i].strand1.start) - 1)
            idx = phase[i].strand1.start[s]:(phase[i].strand1.start[s + 1] - 1)
            X[idx, i] = H[idx, phase[i].strand1.haplotypelabel[s]]
        end
        idx = phase[i].strand1.start[end]:phase[i].strand1.length
        X[idx, i] = H[idx, phase[i].strand1.haplotypelabel[end]]
        for s in 1:(length(phase[i].strand2.start) - 1)
            idx = phase[i].strand2.start[s]:(phase[i].strand2.start[s + 1] - 1)
            X[idx, i] += H[idx, phase[i].strand2.haplotypelabel[s]]
        end
        idx = phase[i].strand2.start[end]:phase[i].strand2.length
        X[idx, i] += H[idx, phase[i].strand2.haplotypelabel[end]]
    end
end

"""
    unique_haplotypes(H, window)

Finds the unique haplotypes determined by the reference haplotypes stored 
in the columns of H. 

# Input
* `H`: an `p x d` reference panel of haplotypes within a genomic window. 
* `window`: a small window of `H` that is currently undergoing haplotyping.

# Output
* A `view` of `H` at the appropriate window with all redundant haplotypes eliminated
"""
function unique_haplotypes(
    H::AbstractMatrix, 
    window::UnitRange{Int}
    )

    lw = length(window)
    cur_chunk = view(H, window, :)

    # if eltype(H) == Bool && lw in Set([8, 16, 32, 64, 128])
    #     unique_hap_index = unique_haplotype_idx(cur_chunk)
    # else
    #     unique_hap_index = unique(groupslices(cur_chunk))
    # end

    unique_hap_index = unique(groupslices(cur_chunk, 2))
    return view(H, window, unique_hap_index)
end

#ken's code for making a copy of the unique haplotype matrix
# function unique_haplotypes(H::BitArray{2})
#     p, d = size(H) 

#     # reinterpret each haplotype as an integer
#     if p == 8 
#         HR = reinterpret(UInt8, H.chunks) 
#     elseif p == 16
#         HR = reinterpret(UInt16, H.chunks)
#     elseif p == 32
#         HR = reinterpret(UInt32, H.chunks)
#     elseif p == 64
#         HR = reinterpret(UInt64, H.chunks)
#     elseif p == 128
#         HR = reinterpret(UInt128, H.chunks)
#     else
#         return convert(Matrix{Float32}, unique(H, dims=1))
#     end
    
#     Hrank = denserank(HR) # map to unique integers with no gap
#     HU    = unique(HR)    # find unique integers
#     n     = length(HU)
#     Hrep  = zeros(Int, n) # representative haplotype for integer 

#     m = 0
#     for j = 1:d
#         if Hrep[Hrank[j]] == 0
#             Hrep[Hrank[j]] = j
#             m += 1
#             m == n && break
#         end
#     end

#     Hunique = convert(Matrix{Float32}, H[:, Hrep])
#     return (Hunique, Hrank)
# end

"""
    groupslices(A, dim)

Returns a vector of integers where each integer element of the returned vector
is a group number corresponding to the unique slices along dimension `dim` as
returned from `unique(A, dim)`, where `A` can be a multidimensional array.

# Example usage:
If `C = unique(A, dim)`, `ic = groupslices(A, dim)`, and
`ndims(A) == ndims(C) == 3`, then:
```
if dim == 1
   all(A .== C[ic,:,:])
elseif dim == 2
   all(A .== C[:,ic,:])
elseif dim == 3
   all(A .== C[:,:,ic])
end
```

Function from: https://github.com/mcabbott/GroupSlices.jl/blob/master/src/GroupSlices.jl
Can delete this function when this issue gets resolved: https://github.com/JuliaLang/julia/issues/1845 
"""
@generated function groupslices(A::AbstractArray{T,N}, dim::Int) where {T,N}
    quote
        if !(1 <= dim <= $N)
            ArgumentError("Input argument dim must be 1 <= dim <= $N, but is currently $dim")
        end
        hashes = zeros(UInt, size(A, dim))

        # Compute hash for each row
        k = 0
        @nloops $N i A d->(if d == dim; k = i_d; end) begin
            @inbounds hashes[k] = hash(hashes[k], hash((@nref $N A i)))
        end

        # Collect index of first row for each hash
        uniquerow = Vector{Int}(undef, size(A, dim))
        firstrow = Dict{Prehashed,Int}()
        for k = 1:size(A, dim)
            uniquerow[k] = get!(firstrow, Prehashed(hashes[k]), k)
        end
        uniquerows = collect(values(firstrow))

        # Check for collisions
        collided = falses(size(A, dim))
        @inbounds begin
            @nloops $N i A d->(if d == dim
                k = i_d
                j_d = uniquerow[k]
            else
                j_d = i_d
            end) begin
                if (@nref $N A j) != (@nref $N A i)
                    collided[k] = true
                end
            end
        end

        if any(collided)
            nowcollided = BitArray(size(A, dim))
            while any(collided)
                # Collect index of first row for each collided hash
                empty!(firstrow)
                for j = 1:size(A, dim)
                    collided[j] || continue
                    uniquerow[j] = get!(firstrow, Prehashed(hashes[j]), j)
                end
                for v in values(firstrow)
                    push!(uniquerows, v)
                end

                # Check for collisions
                fill!(nowcollided, false)
                @nloops $N i A d->begin
                    if d == dim
                        k = i_d
                        j_d = uniquerow[k]
                        (!collided[k] || j_d == k) && continue
                    else
                        j_d = i_d
                    end
                end begin
                    if (@nref $N A j) != (@nref $N A i)
                        nowcollided[k] = true
                    end
                end
                (collided, nowcollided) = (nowcollided, collided)
            end
        end
        ie = unique(uniquerow)
        ic_dict = Dict{Int,Int}()
        for k = 1:length(ie)
            ic_dict[ie[k]] = k
        end

        ic = similar(uniquerow)
        for k = 1:length(ic)
            ic[k] = ie[ic_dict[uniquerow[k]]]
        end
        return ic
    end
end

"""
    unique_haplotype_idx(H)

Returns the columns of `H` that are unique. 

# Input
* `H`: an abstract bitarray of haplotypes within a genomic window.

# Output
* Vector containing the unique column index of H.
"""
function unique_haplotype_idx(H::AbstractMatrix)
    p = size(H, 1) 

    # reinterpret each haplotype as an integer
    if p == 8 
        HR = reinterpret(UInt8, H.chunks) 
    elseif p == 16
        HR = reinterpret(UInt16, H.chunks)
    elseif p == 32
        HR = reinterpret(UInt32, H.chunks)
    elseif p == 64
        HR = reinterpret(UInt64, H.chunks)
    elseif p == 128
        HR = reinterpret(UInt128, H.chunks)
    end

    return unique_index(HR)
end

function unique_index(v::AbstractVector)
    seen = Set{eltype(v)}()
    lv   = length(v)
    unique_index = trues(lv)

    @inbounds for i in 1:lv
        if in(v[i], seen)
            unique_index[i] = false
        else
            push!(seen, v[i])
        end
    end

    return unique_index
end
