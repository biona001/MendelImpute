"""
    phase(tgtfile, reffile; [outfile], [impute], [width], [recreen], [thinning_factor], [dynamic_programming])

Main function of MendelImpute program. Phasing (haplotying) of `tgtfile` from a pool 
of haplotypes `reffile` by sliding windows and saves result in `outfile`. 

# Input
- `tgtfile`: VCF or PLINK files. VCF files should end in `.vcf` or `.vcf.gz`. PLINK files should exclude `.bim/.bed/.fam` suffixes but the trio must all be present in the directory. 
- `reffile`: VCF or compressed Julia binary files. VCF files should end in `.vcf` or `.vcf.gz`. Acceptable Julia binary formats includes `.jld2` (fastest read time) and `.jlso` (smallest file size).

# Optional Inputs
- `outfile`: output filename ending in `.vcf.gz` or `.vcf`. Output genotypes will have no missing data.
- `impute`: If `true`, untyped SNPs will be imputed, otherwise only missing snps in `tgtfile` will be imputed.  (default `false`)
- `width`: number of SNPs (markers) in each haplotype window. (default `2048`)
- `rescreen`: This option saves a number of top haplotype pairs when solving the least squares objective, and re-minimize least squares on just observed data.
- `thinning_factor`: This option solves the least squares objective on only "thining_factor" unique haplotypes.
"""
function phase(
    tgtfile::AbstractString,
    reffile::AbstractString;
    outfile::AbstractString = "imputed." * tgtfile,
    impute::Bool = true,
    width::Int = 2048,
    rescreen::Bool = false, 
    max_haplotypes::Int = 2000,
    thinning_factor::Union{Nothing, Int} = nothing,
    thinning_scale_allelefreq::Bool = false,
    dynamic_programming::Bool = true,
    lasso::Union{Nothing, Int} = nothing
    )

    # decide how to partition the data based on available memory 
    # people = nsamples(tgtfile)
    # haplotypes = 2nsamples(reffile_aligned)
    # snps_per_chunk = chunk_size(people, haplotypes)
    # chunks = ceil(Int, tgt_snps / snps_per_chunk)
    # remaining_snps = tgt_snps - ((chunks - 1) * snps_per_chunk)
    # println("Running chunk $chunks / $chunks")

    # import reference data
    import_data_start = time()
    if endswith(reffile, ".jld2")
        @load reffile compressed_Hunique 
        width == compressed_Hunique.width || error("Specified width = $width does not equal $(compressed_Hunique.width) = width in .jdl2 file")
    elseif endswith(reffile, ".jlso")
        loaded = JLSO.load(reffile)
        compressed_Hunique = loaded[:compressed_Hunique]
        width == compressed_Hunique.width || error("Specified width = $width does not equal $(compressed_Hunique.width) = width in .jlso file")
    elseif endswith(reffile, ".vcf") || endswith(reffile, ".vcf.gz")
        # for VCF files, compress into jlso files and filter for unique haplotypes in each window
        @info "VCF files detected: compressing reference file to .jlso format..."
        compressed_Hunique = compress_haplotypes(reffile, tgtfile, "compressed." * reffile, width, dims=2, flankwidth = 0)
    else
        error("Unrecognized reference file format: only VCF (ends in .vcf or .vcf.gz), `.jlso`, or `.jld2` files are acceptable.")
    end

    # import genotype data
    if endswith(tgtfile, ".vcf") || endswith(tgtfile, ".vcf.gz")
        X, X_sampleID, X_chr, X_pos, X_ids, X_ref, X_alt = VCFTools.convert_gt(UInt8, tgtfile, trans=true, save_snp_info=true, msg = "Importing genotype file...")
    elseif isfile(tgtfile * ".bed") && isfile(tgtfile * ".fam") && isfile(tgtfile * ".bim")
        # PLINK files
        X_snpdata = SnpArrays.SnpData(tgtfile)
        X = convert(Matrix{UInt8}, X_snpdata.snparray') # transpose genotypes from rows to column 
        X_sampleID = X_snpdata.person_info[!, :iid] 
        X_chr = X_snpdata.snp_info[!, :chromosome]
        X_pos = X_snpdata.snp_info[!, :position]
        X_ids = X_snpdata.snp_info[!, :snpid]
        X_ref = X_snpdata.snp_info[!, :allele1]
        X_alt = X_snpdata.snp_info[!, :allele2]
    else
        error("Unrecognized target file format: target file can only be VCF files (ends in .vcf or .vcf.gz) or PLINK files (do not include .bim/bed/fam and all three files must exist in 1 directory)")
    end
    import_data_time = time() - import_data_start

    # declare some constants
    people = size(X, 2)
    tgt_snps = size(X, 1)
    ref_snps = length(compressed_Hunique.pos)
    windows = floor(Int, tgt_snps / width)

    #
    # compute redundant haplotype sets. 
    # There are 5 timers (some may be 0):
    #     t1 = computing dist(X, H)
    #     t2 = BLAS3 mul! to get M and N
    #     t3 = haplopair search
    #     t4 = rescreen time
    #     t5 = finding redundant happairs
    #
    calculate_happairs_start = time()
    if dynamic_programming
        redundant_haplotypes = [[Tuple{Int32, Int32}[] for i in 1:windows] for j in 1:people]
        [[sizehint!(redundant_haplotypes[j][i], 1000) for i in 1:windows] for j in 1:people] # don't save >1000 redundant happairs
    else
        redundant_haplotypes = [OptimalHaplotypeSet(windows) for i in 1:people]
    end
    num_unique_haps = zeros(Int, Threads.nthreads())
    timers = [zeros(5) for _ in 1:Threads.nthreads()]
    pmeter = Progress(windows, 5, "Computing optimal haplotype pairs...")
    ThreadPools.@qthreads for w in 1:windows
        Hw_aligned = compressed_Hunique.CW_typed[w].uniqueH
        Xw_idx_start = (w - 1) * width + 1
        Xw_idx_end = (w == windows ? length(X_pos) : w * width)
        Xw_aligned = X[Xw_idx_start:Xw_idx_end, :]

        # computational routine
        if !isnothing(lasso)
            if size(Hw_aligned, 2) > max_haplotypes
                happairs, hapscore, t1, t2, t3, t4 = haplopair_lasso(Xw_aligned, Hw_aligned, r = lasso)
            else
                happairs, hapscore, t1, t2, t3, t4 = haplopair(Xw_aligned, Hw_aligned)
            end
        elseif !isnothing(thinning_factor)
            # weight each snp by frequecy if requested
            if thinning_scale_allelefreq
                Hw_range = compressed_Hunique.start[w]:(w == windows ? ref_snps : compressed_Hunique.start[w + 1] - 1)
                Hw_snp_pos = indexin(X_pos[Xw_idx_start:Xw_idx_end], compressed_Hunique.pos[Hw_range])
                altfreq = compressed_Hunique.altfreq[Hw_snp_pos]
            else
                altfreq = nothing
            end
            # run haplotype thinning 
            if size(Hw_aligned, 2) > max_haplotypes
                happairs, hapscore, t1, t2, t3, t4 = haplopair_thin_BLAS2(Xw_aligned, Hw_aligned, alt_allele_freq = altfreq, keep=thinning_factor)
            else
                happairs, hapscore, t1, t2, t3, t4 = haplopair(Xw_aligned, Hw_aligned)
            end
            # happairs, hapscore, t1, t2, t3, t4 = haplopair_thin_BLAS2(Xw_aligned, Hw_aligned, alt_allele_freq = altfreq, keep=thinning_factor)
            # happairs, hapscore, t1, t2, t3, t4 = haplopair_thin_BLAS3(Xw_aligned, Hw_aligned, alt_allele_freq = altfreq, keep=thinning_factor)
        elseif rescreen
            happairs, hapscore, t1, t2, t3, t4 = haplopair_screen(Xw_aligned, Hw_aligned)
        else
            happairs, hapscore, t1, t2, t3, t4 = haplopair(Xw_aligned, Hw_aligned)
        end

        # convert happairs (which index off unique haplotypes) to indices of full haplotype pool, and find all matching happairs
        t5 = @elapsed compute_redundant_haplotypes!(redundant_haplotypes, compressed_Hunique, happairs, w, dp = dynamic_programming)

        # record timings and haplotypes
        id = Threads.threadid()
        timers[id][1] += t1
        timers[id][2] += t2
        timers[id][3] += t3
        timers[id][4] += t4
        timers[id][5] += t5
        num_unique_haps[id] += size(Hw_aligned, 2)

        # update progress
        next!(pmeter)
    end
    avg_num_unique_haps = sum(num_unique_haps) / windows
    timers = sum(timers) ./ Threads.nthreads()
    calculate_happairs_time = time() - calculate_happairs_start

    #
    # phasing (haplotyping) step
    #
    # offset = (chunks - 1) * snps_per_chunk
    phase_start = time()
    ph = [HaplotypeMosaicPair(ref_snps) for i in 1:people]
    if dynamic_programming
        phase!(ph, X, compressed_Hunique, redundant_haplotypes, X_pos) # phase by dynamic programming + breakpoint search
    else
        phase_fast!(ph, X, compressed_Hunique, redundant_haplotypes, X_pos, 0) # phase by dynamic programming + breakpoint search
    end
    phase_time = time() - phase_start

    #
    # impute step
    #
    impute_start = time()
    H_pos = compressed_Hunique.pos
    XtoH_idx = indexin(X_pos, H_pos) # X_pos[i] == H_pos[XtoH_idx[i]]
    if impute
        # initialize whole genotype matrix and copy known entries into it
        X_full = Matrix{Union{Missing, UInt8}}(missing, ref_snps, people)
        copyto!(@view(X_full[XtoH_idx, :]), X)

        # convert phase's starting position from X's index to H's index
        update_marker_position!(ph, XtoH_idx)

        impute!(X_full, compressed_Hunique, ph, outfile, X_sampleID, XtoH_idx=nothing) # imputes X_full and writes to file
    else
        impute!(X, compressed_Hunique, ph, outfile, X_sampleID, XtoH_idx=XtoH_idx) # imputes X (only containing typed snps) and writes to file
    end
    impute_time = time() - impute_start

    println("Total windows = $windows, averaging ~ $(round(Int, avg_num_unique_haps)) unique haplotypes per window.\n")
    println("Timings: ")
    println("    Data import                     = ", round(import_data_time, sigdigits=6), " seconds")
    println("    Computing haplotype pair        = ", round(calculate_happairs_time, sigdigits=6), " seconds")
    timers[1] != 0 && println("        computing dist(X, H)           = ", round(timers[1], sigdigits=6), " seconds per thread")
    println("        BLAS3 mul! to get M and N      = ", round(timers[2], sigdigits=6), " seconds per thread")
    println("        haplopair search               = ", round(timers[3], sigdigits=6), " seconds per thread")
    timers[4] != 0 && println("        min least sq on observed data  = ", round(timers[4], sigdigits=6), " seconds per thread")
    println("        finding redundant happairs     = ", round(timers[5], sigdigits=6), " seconds per thread")
    dynamic_programming ? println("    Phasing by dynamic programming  = ", round(phase_time, sigdigits=6), " seconds") :
                          println("    Phasing by win-win intersection = ", round(phase_time, sigdigits=6), " seconds")
    println("    Imputation                      = ", round(impute_time, sigdigits=6), " seconds\n")

    return redundant_haplotypes, ph
end

"""
    phase!(X, H, width=400, verbose=true)

Phasing (haplotying) of genotype matrix `X` from a pool of haplotypes `H`
by dynamic programming. 

# Input
* `ph`: A vector of `HaplotypeMosaicPair` keeping track of each person's phase information.
* `X`: `p x n` matrix with missing values. Each column is genotypes of an individual.
* `compressed_Hunique`: A `CompressedHaplotypes` keeping track of unique haplotypes for each window and some other information
* `redundant_haplotypes`: Vector of optimal haplotype pairs across windows. The haplotype pairs are indices to the full haplotype set and NOT the compressed haplotypes
* `chunk_offset`: Shifts SNPs if a chromosome had been chunked. (not currently implemented)
"""
function phase!(
    ph::Vector{HaplotypeMosaicPair},
    X::AbstractMatrix{Union{Missing, T}},
    compressed_Hunique::CompressedHaplotypes,
    redundant_haplotypes::Vector{Vector{Vector{Tuple{Int32, Int32}}}},
    X_pos::Vector{Int};
    chunk_offset::Int = 0,
    ) where T <: Real

    # declare some constants
    people = size(X, 2)
    snps = size(X, 1)
    width = compressed_Hunique.width
    windows = floor(Int, snps / width)
    H_pos = compressed_Hunique.pos
    XtoH_idx = indexin(X_pos, H_pos)

    # allocate working arrays
    sol_path = [Vector{Tuple{Int32, Int32}}(undef, windows) for i in 1:Threads.nthreads()]
    nxt_pair = [[Int32[] for i in 1:windows] for i in 1:Threads.nthreads()]
    tree_err = [[Float64[] for i in 1:windows] for i in 1:Threads.nthreads()]
    pmeter   = Progress(people, 5, "Merging breakpoints...")

    # loop over each person
    # first  1/3: ((w - 2) * width + 1):((w - 1) * width)
    # middle 1/3: ((w - 1) * width + 1):(      w * width)
    # last   1/3: (      w * width + 1):((w + 1) * width)
    ThreadPools.@qthreads for i in 1:people
        # first find optimal haplotype pair in each window using dynamic programming
        id = Threads.threadid()
        connect_happairs!(sol_path[id], nxt_pair[id], tree_err[id], redundant_haplotypes[i], λ = 1.0)

        # phase first window 
        h1 = complete_idx_to_unique_all_idx(sol_path[id][1][1], 1, compressed_Hunique)
        h2 = complete_idx_to_unique_all_idx(sol_path[id][1][2], 1, compressed_Hunique)
        push!(ph[i].strand1.start, 1 + chunk_offset)
        push!(ph[i].strand1.window, 1) 
        push!(ph[i].strand1.haplotypelabel, h1)
        push!(ph[i].strand2.start, 1 + chunk_offset)
        push!(ph[i].strand2.window, 1)
        push!(ph[i].strand2.haplotypelabel, h2)

        # don't search breakpoints
        # for w in 2:windows
        #     u, j = sol_path[id][w - 1] # haplotype pair in previous window
        #     k, l = sol_path[id][w]     # haplotype pair in current window

        #     # switch current window's pair order if 1 or 2 haplotype match
        #     if (u == l && j == k) || (j == k && u ≠ l) || (u == l && j ≠ k)
        #         k, l = l, k 
        #         sol_path[id][w] = (k, l)
        #     end

        #     # map hap1 and hap2 back to unique index in given window
        #     h1 = complete_idx_to_unique_all_idx(k, w, compressed_Hunique)
        #     h2 = complete_idx_to_unique_all_idx(l, w, compressed_Hunique)

        #     push!(ph[i].strand1.start, chunk_offset + (w - 1) * width + 1)
        #     push!(ph[i].strand1.haplotypelabel, h1)
        #     push!(ph[i].strand1.window, w)
        #     push!(ph[i].strand2.start, chunk_offset + (w - 1) * width + 1)
        #     push!(ph[i].strand2.haplotypelabel, h2)
        #     push!(ph[i].strand2.window, w)
        # end

        # search breakpoints 
        for w in 2:windows
            # get genotype vector spanning 2 windows
            Xwi_start = (w - 2) * width + 1
            Xwi_end = (w == windows ? snps : w * width)
            Xwi = view(X, Xwi_start:Xwi_end, i)

            # find optimal breakpoint if there is one
            sol_path[id][w], bkpts = continue_haplotype(Xwi, compressed_Hunique, 
                w, sol_path[id][w - 1], sol_path[id][w])

            # record strand 1 info
            update_phase!(ph[i].strand1, compressed_Hunique, bkpts[1], sol_path[id][w - 1][1], 
                sol_path[id][w][1], w, width, chunk_offset, XtoH_idx, Xwi_start, Xwi_end)
            # record strand 2 info
            update_phase!(ph[i].strand2, compressed_Hunique, bkpts[2], sol_path[id][w - 1][2], 
                sol_path[id][w][2], w, width, chunk_offset, XtoH_idx, Xwi_start, Xwi_end)
        end

        # update progress
        next!(pmeter)
    end
end

"""
Helper function for updating phase information after breakpoints have been identified
between windows `w - 1` and `w`. Every window have 0 or 1 breakpoint. Here indices in 
`ph.start` are recorded in terms of X's index.  

Caveat: technically it is possible for a window to have 2 breakpoints (that might even overlap)
since we can have the previous and next window both extend into the current one, but hopefully
this is extremely rare.
"""
function update_phase!(ph::HaplotypeMosaic, compressed_Hunique::CompressedHaplotypes,
    bkpt::Int, hap_prev, hap_curr, w::Int, width::Int, chunk_offset::Int,
    XtoH_idx::AbstractVector, Xwi_start::Int, Xwi_end::Int)

    # no breakpoints
    if bkpt == -1
        h = complete_idx_to_unique_all_idx(hap_curr, w, compressed_Hunique)
        push!(ph.start, chunk_offset + (w - 1) * width + 1)
        push!(ph.haplotypelabel, h)
        push!(ph.window, w)
        return nothing
    end

    # previous window's haplotype completely covers current window 
    if bkpt == length(Xwi_start:Xwi_end)
        h = complete_idx_to_unique_all_idx(hap_prev, w, compressed_Hunique)
        push!(ph.start, chunk_offset + (w - 1) * width + 1)
        push!(ph.haplotypelabel, h)
        push!(ph.window, w)
        return nothing
    end

    X_bkpt_end = Xwi_start + bkpt
    Xwi_mid = (w - 1) * width + 1

    if Xwi_mid <= X_bkpt_end <= Xwi_end
        # previous window extends to current window 
        h1 = complete_idx_to_unique_all_idx(hap_prev, w, compressed_Hunique)
        push!(ph.start, chunk_offset + Xwi_mid)
        push!(ph.haplotypelabel, h1)
        push!(ph.window, w)
        # 2nd part of current window
        h2 = complete_idx_to_unique_all_idx(hap_curr, w, compressed_Hunique)
        push!(ph.start, chunk_offset + X_bkpt_end)
        push!(ph.haplotypelabel, h2)
        push!(ph.window, w)
    elseif X_bkpt_end < Xwi_mid
        # current window extends to previous window
        h1 = complete_idx_to_unique_all_idx(hap_curr, w - 1, compressed_Hunique)
        push!(ph.start, chunk_offset + X_bkpt_end)
        push!(ph.haplotypelabel, h1)
        push!(ph.window, w - 1)
        # update current window
        h2 = complete_idx_to_unique_all_idx(hap_curr, w, compressed_Hunique)
        push!(ph.start, chunk_offset + Xwi_mid)
        push!(ph.haplotypelabel, h2)
        push!(ph.window, w)
    else
        # println("H_bkpt_pos = $H_bkpt_pos, Hw_start=$Hw_start, Hw_mid=$Hw_mid, Hw_end=$Hw_end ")
        error("update_phase!: bkpt does not satisfy -1 <= bkpt <= 2width! Shouldn't be possible")
    end

    return nothing
end

function Base.intersect!(c::Set{<:Integer}, a::Set{<:Integer}, b::Set{<:Integer})
    empty!(c)
    for x in a
        x in b && push!(c, x)
    end
    return nothing
end

function phase_fast!(
    ph::Vector{HaplotypeMosaicPair},
    X::AbstractMatrix{Union{Missing, T}},
    compressed_Hunique::CompressedHaplotypes,
    hapset::Vector{OptimalHaplotypeSet},
    X_pos::Vector{Int},
    chunk_offset::Int = 0,
    ) where T <: Real

    # declare some constants
    people = size(X, 2)
    snps = size(X, 1)
    haplotypes = nhaplotypes(compressed_Hunique)
    width = compressed_Hunique.width
    windows = floor(Int, snps / width)
    H_pos = compressed_Hunique.pos
    XtoH_idx = indexin(X_pos, H_pos)

    # allocate working arrays
    haplo_chain = ([copy(hapset[i].strand1[1]) for i in 1:people], [copy(hapset[i].strand2[1]) for i in 1:people])
    chain_next  = (Set{Int32}(), Set{Int32}())
    window_span = (ones(Int, people), ones(Int, people))
    pmeter      = Progress(people, 5, "Intersecting haplotypes...")
    sizehint!(chain_next[1], haplotypes)
    sizehint!(chain_next[2], haplotypes)
    
    # begin intersecting haplotypes window by window
    @inbounds for i in 1:people
        for w in 2:windows
            # Decide whether to cross over based on the larger intersection
            # A   B      A   B
            # |   |  or    X
            # C   D      C   D
            intersect!(chain_next[1], haplo_chain[1][i], hapset[i].strand1[w]) # not crossing over
            intersect!(chain_next[2], haplo_chain[1][i], hapset[i].strand2[w]) # crossing over
            AC = length(chain_next[1])
            AD = length(chain_next[2])
            intersect!(chain_next[1], haplo_chain[2][i], hapset[i].strand1[w]) # crossing over
            intersect!(chain_next[2], haplo_chain[2][i], hapset[i].strand2[w]) # not crossing over
            BC = length(chain_next[1])
            BD = length(chain_next[2])
            if AC + BD < AD + BC
                hapset[i].strand1[w], hapset[i].strand2[w] = hapset[i].strand2[w], hapset[i].strand1[w]
            end

            # intersect all surviving haplotypes with next window
            intersect!(chain_next[1], haplo_chain[1][i], hapset[i].strand1[w])
            intersect!(chain_next[2], haplo_chain[2][i], hapset[i].strand2[w])

            # strand 1 becomes empty
            if length(chain_next[1]) == 0
                # delete all nonmatching haplotypes in previous windows
                for ww in (w - window_span[1][i]):(w - 1)
                    copy!(hapset[i].strand1[ww], haplo_chain[1][i])
                end

                # reset counters and storage
                copy!(haplo_chain[1][i], hapset[i].strand1[w])
                window_span[1][i] = 1
            else
                copy!(haplo_chain[1][i], chain_next[1])
                window_span[1][i] += 1
            end

            # strand 2 becomes empty
            if sum(chain_next[2]) == 0
                # delete all nonmatching haplotypes in previous windows
                for ww in (w - window_span[2][i]):(w - 1)
                    intersect!(hapset[i].strand2[ww], haplo_chain[2][i])
                end

                # reset counters and storage
                copy!(haplo_chain[2][i], hapset[i].strand2[w])
                window_span[2][i] = 1
            else
                copy!(haplo_chain[2][i], chain_next[2])
                window_span[2][i] += 1
            end
        end
        next!(pmeter) #update progress
    end

    # get rid of redundant haplotypes in last few windows separately, since intersection may not become empty
    for i in 1:people
        for ww in (windows - window_span[1][i] + 1):windows
            intersect!(hapset[i].strand1[ww], haplo_chain[1][i])
        end

        for ww in (windows - window_span[2][i] + 1):windows
            intersect!(hapset[i].strand2[ww], haplo_chain[2][i])
        end
    end

    # find optimal break points and record info to phase
    # first  1/3: ((w - 2) * width + 1):((w - 1) * width)
    # middle 1/3: ((w - 1) * width + 1):(      w * width)
    # last   1/3: (      w * width + 1):((w + 1) * width)
    pmeter = Progress(people, 5, "Merging breakpoints...")
    ThreadPools.@qthreads for i in 1:people
        id = Threads.threadid()

        # phase first window
        hap1 = something(findsmallest(hapset[i].strand1[1])) # complete idx
        hap2 = something(findsmallest(hapset[i].strand2[1])) # complete idx
        h1 = complete_idx_to_unique_all_idx(hap1, 1, compressed_Hunique) #unique haplotype idx in window 1
        h2 = complete_idx_to_unique_all_idx(hap2, 1, compressed_Hunique) #unique haplotype idx in window 1
        push!(ph[i].strand1.start, 1 + chunk_offset)
        push!(ph[i].strand1.window, 1) 
        push!(ph[i].strand1.haplotypelabel, h1)
        push!(ph[i].strand2.start, 1 + chunk_offset)
        push!(ph[i].strand2.window, 1)
        push!(ph[i].strand2.haplotypelabel, h2)

        # search breakpoints 
        for w in 2:windows
            # get genotype vector spanning 2 windows
            Xwi_start = (w - 2) * width + 1
            Xwi_end = (w == windows ? snps : w * width)
            Xwi = view(X, Xwi_start:Xwi_end, i)

            # let first surviving haplotype be phase
            hap1_prev = something(findsmallest(hapset[i].strand1[w - 1]))
            hap2_prev = something(findsmallest(hapset[i].strand2[w - 1]))
            hap1_curr = something(findsmallest(hapset[i].strand1[w]))
            hap2_curr = something(findsmallest(hapset[i].strand2[w]))

            # find optimal breakpoint if there is one
            _, bkpts = continue_haplotype(Xwi, compressed_Hunique, 
                w, (hap1_prev, hap2_prev), (hap1_curr, hap2_curr))

            # record strand 1 info
            update_phase!(ph[i].strand1, compressed_Hunique, bkpts[1], hap1_prev, 
                hap1_curr, w, width, chunk_offset, XtoH_idx, Xwi_start, Xwi_end)
            # record strand 2 info
            update_phase!(ph[i].strand2, compressed_Hunique, bkpts[2], hap2_prev, 
                hap2_curr, w, width, chunk_offset, XtoH_idx, Xwi_start, Xwi_end)
        end

        next!(pmeter) #update progress
    end
end
