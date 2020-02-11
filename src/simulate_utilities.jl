"""
    make_refvcf_file(H, filename, phased)

Creates a .vcf file with `filename` based on reference panels `H`. Consecutive columns are treated as genotypes.
REF/ALT alleles are always A/C.

# Inputs:
+ `H`: BitMatrix of haplotypes. Each column is a haplotype. e.g. Columns 1 and 2 form the genotype for sample 1. 
+ `filename`: A string for the resulting .vcf file. 
+ `phased`: True uses '|' as separator. False uses '/' as separator. 
"""
function make_refvcf_file(
    H::BitArray{2};
    vcffilename::AbstractString = "simulated_ref.vcf", 
    phased::Bool = true,
    marker_chrom::Vector{String} = ["1" for i in 1:size(H, 1)],
    marker_pos::Vector{Int} = collect(1:size(H, 1)),
    marker_ID::Vector{String} = ["tgt_snp_$i" for i in 1:size(H, 1)],
    marker_REF::Vector{String} = ["A" for i in 1:size(H, 1)],
    marker_ALT::Vector{String} = ["C" for i in 1:size(H, 1)]
    )

    p, d = size(H)
    separator = (phased ? '|' : '/')
    iseven(d) || error("make_vcf_file: number of haplotypes must be even but was $d")

    # first write minimal meta information
    io = openvcf(vcffilename, "w")
    write(io, "##fileformat=VCFv4.3\n")
    write(io, "##source=MendelImpute\n")
    write(io, "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">\n")

    # header line
    write(io, "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT")
    for i in 1:Int(d / 2)
        write(io, "\tref$i")
    end
    write(io, "\n")

    # write phase info
    for snp in 1:p
        write(io, "1\t$snp\tref_snp_$snp\tA\tC\t.\tPASS\t.\tGT")
        for i in 1:2:d
            write(io, string("\t", Int(H[snp, i]), separator, Int(H[snp, i + 1])))
        end
        write(io, "\n")
    end
    close(io)
end

"""
    make_tgtvcf_file(X, filename)

Creates a .vcf file given a genotype matrix `X`. Missing entries in `X` will become `./.`. 
Otherwise, X[i, j] should be either 0, 1, or 2. 0 = '0/0', 1 = '1/0', and 2 = '1/1'. REF/ALT 
alleles are always A/C.

# Inputs:
+ `X`: Matrix of 0, 1, or 2. Each column is a person's genotype. 
+ `filename`: A string for the resulting .vcf file. 
"""
function make_tgtvcf_file(
    X::AbstractMatrix;
    vcffilename::AbstractString = "simulated_tgt.vcf", 
    phased::Bool = false,
    marker_chrom::Vector{String} = ["1" for i in 1:size(X, 1)],
    marker_pos::Vector{Int} = collect(1:size(X, 1)),
    marker_ID::Vector{String} = ["tgt_snp_$i" for i in 1:size(X, 1)],
    marker_REF::Vector{String} = ["A" for i in 1:size(X, 1)],
    marker_ALT::Vector{String} = ["C" for i in 1:size(X, 1)]
    )

    p, d = size(X)
    lc = length(marker_chrom)
    lp = length(marker_pos)
    li = length(marker_ID)
    lr = length(marker_REF)
    la = length(marker_ALT)
    p == lc == lp == li == lr == la || error("There are $p markers in X but CHROM/POS/ID/REF/ALT vectors are of length $lc, $lp, $li, $lr, $la")
    separator = (phased ? '|' : '/')

    # first write minimal meta information
    io = openvcf(vcffilename, "w")    
    write(io, "##fileformat=VCFv4.3\n")
    write(io, "##source=MendelImpute\n")
    write(io, "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">\n")

    # header line
    write(io, "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT")
    for i in 1:d
        write(io, "\ttarget$i")
    end
    write(io, "\n")

    # write phase info
    for snp in 1:p
        write(io, marker_chrom[snp], '\t', string(marker_pos[snp]), '\t', marker_ID[snp], '\t', 
            marker_REF[snp], '\t', marker_ALT[snp], "\t.\tPASS\t.\tGT")
        @inbounds for i in 1:d
            if ismissing(X[snp, i])
                genotype = "./."
            elseif X[snp, i] == 2
                genotype = "1/1"
            elseif X[snp, i] == 1
                genotype = "1/0"
            elseif X[snp, i] == 0
                genotype = "0/0"
            else
                error("genotypes can only be 0, 1, 2, or missing, but was $(X[snp, i])")
            end
            write(io, '\t', genotype)
        end
        write(io, '\n')
    end
    close(io)
end

"""
    simulate_markov_haplotypes(p, d, prob)

Simulates a haplotype matrix as a markov chain. The `i`th allele (0 or 1) will transition 
to the opposite allele (0 or 1) with probability `prob` at the `i + 1`th allele. 

# Inputs
- `p`: Length of each haplotype.
- `d`: Total number of haplotypes. 
- `prob`: transition probability.

# Output
- `H`: `p x d` haplotype matrix. Each column is a haplotype
"""
function simulate_markov_haplotypes(
    p::Int64, 
    d::Int64;
    prob = 0.25,
    )
    @assert 0 < prob < 1 "transition probably `prob` should be between 0 and 1, got $prob"

    H = falses(p, d)
    @inbounds for j in 1:d
        H[1, j] = rand(Bool)
        for i in 2:p
            H[i, j] = (rand() < prob ? !H[i - 1, j] : H[i - 1, j])
        end
    end
    return H
end

"""
    simulate_uniform_haplotypes(p, d, prob)

Simulates a haplotype matrix `H` where `H[i, j] = 1` with probability `prob`. 

# Inputs
- `p`: Length of each haplotype.
- `d`: Total number of haplotypes. 
- `prob`: probability that an entry in H is 1.

# Output
- `H`: `p x d` haplotype matrix. Each column is a haplotype
"""
function simulate_uniform_haplotypes(
    p::Int64, 
    d::Int64;
    prob = 0.25,
    )
    @assert 0 < prob < 1 "prob should be between 0 and 1, got $prob"

    H = falses(p, d)
    @inbounds for j in 1:d, i in 1:p
        if rand() < prob
            H[i, j] = true
        end
    end
    return H
end

"""
    simulate_genotypes(H; block_length)

Simulates a genotype matrix `X` from a pool of haplotypes `H`. Each person's
genotype are divided into contiguous segments, and 2 haplotypes are randomly
chosen from a pool of haplotypes `H` to form the genotype in that segment. 

# Arguments:
- `H`: `p x d` haplotype matrix. Each column is a haplotype. 
- `people`: number of samples
- `T`: Type of output matrix. 
- `min_cross_over`: Minimum number of breakpoints for each person's genotype. 
- `max_cross_over`: Maximum number of breakpoints for each person's genotype. 

# Output:
* `X`: `p x people` genotype matrix. Each column is a person's genotype. 
"""
function simulate_genotypes(
    H::AbstractMatrix,
    people::Int;
    T::Type = Union{Int, Missing},
    min_cross_over::Int64=1,
    max_cross_over::Int64=5,
    )
    
    p, d = size(H)
    X = zeros(Union{T, Missing}, p, people)
    min_cross_over <= max_cross_over || error("Please supply min_cross_over and max_cross_over satisfying min_cross_over <= max_cross_over.")

    # loop through each person
    segments = UnitRange{Int64}[]
    sizehint!(segments, max_cross_over)
    for i in 1:people
        cross_overs = rand(min_cross_over:max_cross_over)
        cross_over_location = sample(2:(p - 1), cross_overs, replace=false)
        #create various segments vased on cross over points
        empty!(segments)
        push!(segments, 1:cross_over_location[1])
        for i in 1:(length(cross_over_location) - 1)
            push!(segments, (cross_over_location[i] + 1):cross_over_location[i + 1])
        end
        push!(segments, (cross_over_location[end] + 1):p)
        # fill X with sum of 2 randomly chosen haplotypes in each segment
        for cur_range in segments
            h1, h2 = rand(1:d), rand(1:d)
            X[cur_range, i] .= convert.(T, H[cur_range, h1] .+ H[cur_range, h2])
        end
    end
    return X
end

# choose 2 haplotypes block by block
# function simulate_genotypes2(
#     H::BitArray{2}; 
#     people::Int = size(H, 2),
#     block_length::Int64=1447
#     )
    
#     p, d = size(H)
#     X = zeros(Int, p, people)
#     blocks = Int(ceil(p / block_length))

#     # for each block, sample 2 ` with replacement from the pool of haplotypes
#     for b in 1:(blocks - 1), i in 1:people
#         hap1 = rand(1:d)
#         hap2 = rand(1:d)
#         block_start = (b - 1) * block_length
#         for j in 1:block_length
#             X[block_start + j, i] = H[block_start + j, hap1] + H[block_start + j, hap2]
#         end
#     end

#     # treat last block separately
#     for i in 1:people
#         hap1 = rand(1:d)
#         hap2 = rand(1:d)
#         block_start = (blocks - 1) * block_length
#         for j in 1:(p - block_start)
#             X[block_start + j, i] = H[block_start + j, hap1] + H[block_start + j, hap2]
#         end
#     end

#     return X
# end
