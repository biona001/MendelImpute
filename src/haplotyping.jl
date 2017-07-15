using NullableArrays

"""
    haplopair!(happair, hapscore, M, N)

Calculate the best pair of haplotypes in `H` for each individual in `X` using
sufficient statistics `M` and `N`.

# Input
* `happair`: optimal haplotype pair for each individual.
* `hapmin`: minimum offered by the optimal haplotype pair.
* `M`: `d x d` matrix with entries `M[i, j] = 2dot(H[i, :], H[j, :]) +
    sumabs2(H[i, :]) + sumabs2(H[j, :])`, where `H` is the haplotype matrix
    with haplotypes in rows. Only the upper triangular part of `M` is used.
* `N`: `n x d` matrix `2XH'`, where `X` is the genotype matrix with individuals
    in rows.
"""
function haplopair!(
    happair::Tuple{Vector, Vector},
    hapmin::Vector,
    M::AbstractMatrix,
    N::AbstractMatrix
    )

    n, d = size(N)
#    for i in 1:n
#        j, k = happair[1][i], happair[2][i]
#        hapmin[i] = M[j, k] - N[i, j] - N[i, k]
#    end
    fill!(hapmin, typemax(eltype(hapmin)))
    # TODO: parallel computing
    @inbounds for k in 1:d, j in 1:k
        # loop over individuals
        @simd for i in 1:n
            score = M[j, k] - N[i, j] - N[i, k]
            if score < hapmin[i]
                hapmin[i], happair[1][i], happair[2][i] = score, j, k
            end
        end
    end
    return nothing

end

"""
    haplopair(X, H)

Calculate the best pair of haplotypes in `H` for each individual in `X`.

# Input
* `X`: `n x p` genotype matrix. Each row is an individual.
* `H`: `d x p` haplotype matrix. Each row is a haplotype.

# Output
* `happair`: haplotype pair. `X[k, :] ≈ H[happair[1][k], :] + H[happair[2][k], :]`
* `hapscore`: haplotyping score. 0 means best. Larger means worse.
"""
function haplopair(
    X::AbstractMatrix,
    H::AbstractMatrix
    )

    n, p     = size(X)
    d        = size(H, 1)
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
`M` by `M[i, j] = 2dot(H[i, :], H[j, :]) + sumabs2(H[i, :]) + sumabs2(H[j, :])`,
`N` by `2XH'`, `happair` by optimal haplotype pair, and `hapscore` by
objective value from the optimal haplotype pair.

# Input
* `X`: `n x p` genotype matrix. Each row is an individual.
* `H`: `d x p` haplotype matrix. Each row is a haplotype.
* `M`: overwritten by `M[i, j] = 2dot(H[i, :], H[j, :]) + sumabs2(H[i, :]) +
    sumabs2(H[j, :])`.
* `N`: overwritten by `n x d` matrix `2XH'`.
* `happair`: optimal haplotype pair. `X[k, :] ≈ H[happair[k, 1], :] + H[happair[k, 2], :]`
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

    n, p = size(X)
    d    = size(H, 1)
    # assemble M
    A_mul_Bt!(M, H, H)
    for j in 1:d, i in 1:(j - 1) # off-diagonal
        M[i, j] = 2M[i, j] + M[i, i] + M[j, j]
    end
    for j in 1:d # diagonal
        M[j, j] *= 4
    end
    # assemble N
    A_mul_Bt!(N, X, H)
    for I in eachindex(N)
        N[I] *= 2
    end
    # computational routine
    haplopair!(happair, hapscore, M, N)
    # supplement the constant terms in objective
    @inbounds for j in 1:p
        @simd for i in 1:n
            hapscore[i] += abs2(X[i, j])
        end
    end
    return nothing

end

"""
    fillmissing!(X, H, haplopair)

Fill in missing genotypes in `X` according to haplotypes. Non-missing gentypes
remain same.

# Input
* `X`: `n x p` genotype matrix. Each row is an individual.
* `H`: `d x p` haplotype matrix. Each row is a haplotype.
* `happair`: pair of haplotypes. `X[k, :] = H[happair[1][k], :] + H[happair[2][k], :]`.

# Output
* `discrepancy`: sum of squared errors between current values in missing genotypes
    and the imputed genotypes.
"""
function fillmissing!(
    X::NullableMatrix,
    H::AbstractMatrix,
    happair::Tuple{AbstractVector, AbstractVector}
    )

    discrepancy = zero(promote_type(eltype(X.values), eltype(H)))
    @inbounds for j in 1:size(X, 2), i in 1:size(X, 1)
        if X.isnull[i, j]
            tmp = H[happair[1][i], j] + H[happair[2][i], j]
            discrepancy += abs2(X.values[i, j] - tmp)
            X.values[i, j] = tmp
        end
    end
    return discrepancy

end

"""
    fillgeno!(X, H, happair)

Fill in genotypes according to haplotypes. Both missing and non-missing
genotypes may be changed.

# Input
* `X`: `n x p` genotype matrix. Each row is an individual.
* `H`: `d x p` haplotype matrix. Each row is a haplotype.
* `happair`: pair of haplotypes. `X[k, :] = H[happair[1][k], :] + H[happair[2][k], :]`.
"""
function fillgeno!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    happair::Tuple{AbstractVector, AbstractVector}
    )

    @inbounds for j in 1:size(X, 2), i in 1:size(X, 1)
        X[i, j] = H[happair[1][i], j] + H[happair[2][i], j]
    end
    return nothing

end

"""
    initmissing(X)

Initialize the missing values in a nullable matrix `X` by `2 x` allele frequency.
"""
function initmissing!(X::NullableMatrix)
    T = eltype(X.values)
    for j in 1:size(X, 2)
        # allele frequency
        cnnz = 0
        csum = zero(T)
        for i in 1:size(X, 1)
            if ~X.isnull[i, j]
                cnnz += 1
                csum += X.values[i, j]
            end
        end
        # set missing values to 2freq
        imp = csum / cnnz
        for i in 1:size(X, 1)
            if X.isnull[i, j]
                X.values[i, j] = imp
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
* `X`: `n x p` nullable matrix. Each row is genotypes of an individual.
* `H`: `d x p` haplotype matrix. Each row is a haplotype.
* `M`: overwritten by `M[i, j] = 2dot(H[i, :], H[j, :]) + sumabs2(H[i, :]) +
    sumabs2(H[j, :])`.
* `N`: overwritten by `n x d` matrix `2XH'`.
* `happair`: optimal haplotype pair. `X[k, :] ≈ H[happair[k, 1], :] + H[happair[k, 2], :]`
* `hapscore`: haplotyping score. 0 means best. Larger means worse.
* `maxiters`: number of MM iterations. Defaultis 1.
* `tolfun`: convergence tolerance of MM iterations. Default is 1e-3.
"""
function haploimpute!(
    X::NullableMatrix,
    H::AbstractMatrix,
    M::AbstractMatrix,
    N::AbstractMatrix,
    happair::Tuple{AbstractVector, AbstractVector},
    hapscore::AbstractVector,
    maxiters::Int  = 1,
    tolfun::Number = 1e-3
    )

    obj = typemax(eltype(hapscore))
    initmissing!(X)
    for iter in 1:maxiters
        # haplotyping
        haplopair!(X.values, H, M, N, happair, hapscore)
        # impute missing entries according to current haplotypes
        discrepancy = fillmissing!(X, H, happair)
        #println("discrepancy = $discrepancy")
        # convergence criterion
        objold = obj
        obj = sum(hapscore) - discrepancy
        #println("iter = $iter, obj = $obj")
        if abs(obj - objold) < tolfun * (objold + 1)
            break
        end
    end
    return nothing

end

"""
    haploimpute!(X, H, width=500, maxiters=5, tolfun=1e-3)

Haplotying of genotype matrix `X` from a pool of haplotypes `H` and impute
missing genotypes in `X` according to haplotypes.

# Input
* `X`: `n x p` nullable matrix. Each row is genotypes of an individual.
* `H`: `d x p` haplotype matrix. Each row is a haplotype.
* `width`: width of the sliding window.
* `maxiters`: number of MM iterations. Defaultis 1.
* `tolfun`: convergence tolerance of MM iterations. Default is 1e-3.
"""
function haploimpute!(
    X::NullableMatrix,
    H::AbstractMatrix,
    width::Int     = 500,
    verbose::Bool  = true
    )

    people, snps, haplotypes = size(X, 1), size(X, 2), size(H, 1)
    # allocate working arrays
    M        = zeros(eltype(H), haplotypes, haplotypes)
    N        = zeros(promote_type(eltype(H), eltype(X.values)), people, haplotypes)
    happair  = ones(Int, people), ones(Int, people)
    hapscore = zeros(eltype(N), people)

    # no need for sliding window
    if snps ≤ 3width
        haploimpute!(X, H, M, N, happair, hapscore)
        fillgeno!(X.values, H, happair)
        return nothing
    end

    # allocate working arrays
    Xwork = X[:, 1:3width] # NullableMatrix
    Xw1   = view(Xwork.values, :, 1:width)
    Xwb1  = view(Xwork.isnull, :, 1:width)
    Xw23  = view(Xwork.values, :, (width + 1):3width)
    Xwb23 = view(Xwork.isnull, :, (width + 1):3width)
    Hwork = view(H, :, 1:3width)

    # number of windows
    windows = floor(Int, snps / width)

    # phase and impute window 1
    if verbose; println("Imputing SNPs 1:$width"); end
    haploimpute!(Xwork, Hwork, M, N, happair, hapscore)
    fill!(Xwb1, false)

    # first  1/3: ((w - 2) * width + 1):((w - 1) * width)
    # middle 1/3: ((w - 1) * width + 1):(      w * width)
    # last   1/3: (      w * width + 1):((w + 1) * width)
    for w in 2:(windows - 1)
        if verbose
            println("Imputing SNPs $((w - 1) * width + 1):$(w * width)")
            println([happair[1][5], happair[2][5]])
        end
        # overwrite first 1/3 by phased haplotypes
        H1    = view(H,        :, ((w - 2) * width + 1):((w - 1) * width))
        X1    = view(X.values, :, ((w - 2) * width + 1):((w - 1) * width))
        fillgeno!(X1, H1, happair)
        copy!(Xw1, X1)
        # refresh second and third 1/3 to original data
        X23   = view(X.values, :, ((w - 1) * width + 1):((w + 1) * width))
        Xb23  = view(X.isnull, :, ((w - 1) * width + 1):((w + 1) * width))
        copy!(Xw23, X23)
        copy!(Xwb23, Xb23)
        # phase + impute
        Hwork = view(H, :, ((w - 2) * width + 1):((w + 1) * width))
        haploimpute!(Xwork, Hwork, M, N, happair, hapscore)
    end

    # last window
    if verbose
        println("Imputing SNPs $((windows - 1) * width + 1):$snps")
    end
    Xwork = X[:, ((windows - 2) * width + 1):snps]
    Hwork = view(H,        :, ((windows - 2) * width + 1):snps)
    H1    = view(H,        :, ((windows - 2) * width + 1):((windows - 1) * width))
    H23   = view(H,        :, ((windows - 1) * width + 1):snps)
    X1    = view(X.values, :, ((windows - 2) * width + 1):((windows - 1) * width))
    X23   = view(X.values, :, ((windows - 1) * width + 1):snps)
    Xw1   = view(Xwork.values, :, 1:width)
    fillgeno!(X1, H1, happair)
    copy!(Xw1, X1)
    haploimpute!(Xwork, Hwork, M, N, happair, hapscore)
    fillgeno!(X23, H23, happair)

    return nothing

end

"""
    continue_haplotype(X, H, happair_prev, happair_next, breakpt)

Find the optimal concatenated haplotypes from unordered haplotype pairs in two
consecutive windows.

# Input
* `X`: an `n` vector of genotypes with {0, 1, 2} entries
* `H`: an `n x d` reference panel of haplotypes with {0, 1} entries
* `happair_prev`: unordered haplotypes `(i, j)` in the first window
* `happair_next`: unordered haplotypes `(k, l)` in the next window
* `breakpt`: break points in the ordered haplotypes

# Output
`happair_next` and `breakpt` are updated with the optimal configuration.
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

    # no strand matches
    # i | j
    # k | l
    bkpts1, errors1 = search_breakpoint(X, H, (i, k), (j, l))
    # i | j
    # l | k
    bkpts2, errors2 = search_breakpoint(X, H, (i, l), (j, k))
    # choose the best one
    if errors1 < errors2
        return (k, l), bkpts1
    else
        return (l, k), bkpts2
    end

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

    # count number of errors if second haplotype is all from H[:, s2[2]]
    errors = 0
    for pos in 1:length(X)
        if !isnull(X[pos])
            errors += X[pos] ≠ H[pos, s1] + H[pos, s2[2]]
        end
    end
    err_optim  = errors
    bkpt_optim = 0
    # extend haplotype H[:, s2[1]] position by position
    for bkpt in 1:length(X)
        if !isnull(X[bkpt])
            errors -= X[bkpt] ≠ H[bkpt, s1] + H[bkpt, s2[2]]
            errors += X[bkpt] ≠ H[bkpt, s1] + H[bkpt, s2[1]]
            if errors < err_optim
                err_optim = errors
                bkpt_optim = bkpt
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
    for bkpt1 in 0:length(X)
        # count number of errors if second haplotype is all from H[:, s2[2]]
        errors = 0
        for pos in 1:bkpt1
            isnull(X[pos]) || (errors += (X[pos] ≠ H[pos, s1[1]] + H[pos, s2[2]]))
        end
        for pos in (bkpt1 + 1):length(X)
            isnull(X[pos]) || (errors += (X[pos] ≠ H[pos, s1[2]] + H[pos, s2[2]]))
        end
        if errors < err_optim
            err_optim = errors
            bkpts_optim = (bkpt1, 0)
        end
        # extend haplotype H[:, s2[1]] position by position
        for bkpt2 in 1:bkpt1
            if !isnull(X[bkpt2])
                errors -= X[bkpt2] ≠ H[bkpt2, s1[1]] + H[bkpt2, s2[2]]
                errors += X[bkpt2] ≠ H[bkpt2, s1[1]] + H[bkpt2, s2[1]]
                if errors < err_optim
                    err_optim = errors
                    bkpts_optim = (bkpt1, bkpt2)
                end
            end
        end
        for bkpt2 in (bkpt1 + 1):length(X)
            if !isnull(X[bkpt2])
                errors -= X[bkpt2] ≠ H[bkpt2, s1[2]] + H[bkpt2, s2[2]]
                errors += X[bkpt2] ≠ H[bkpt2, s1[2]] + H[bkpt2, s2[1]]
                if errors < err_optim
                    err_optim = errors
                    bkpts_optim = (bkpt1, bkpt2)
                end
            end
        end
    end
    return bkpts_optim, err_optim

end
