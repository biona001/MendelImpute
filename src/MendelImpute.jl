__precompile__()

module MendelImpute

import Base.hash
import Base.Cartesian, Base.Cartesian.@nloops, Base.Cartesian.@nref

using LinearAlgebra
using StatsBase

export continue_haplotype,
    haplopair!, haplopair, haploimpute!,
    impute!, phase,
    search_breakpoint,
    unique_haplotypes, unique_haplotype_idx,
    groupslices, groupinds

"""
Data structure for recording haplotype mosaic of one strand:
`start[i]` to `start[i+1]` has haplotype `haplotypelabel[i]`
`start[end]` to `length` has haplotype `haplotypelabel[end]`
"""
struct HaplotypeMosaic
    length::Int
    start::Vector{Int}
    haplotypelabel::Vector{Int}
end
HaplotypeMosaic(len) = HaplotypeMosaic(len, Int[], Int[])

# data structure for recording haplotype mosaic of two strands
struct HaplotypeMosaicPair
    strand1::HaplotypeMosaic
    strand2::HaplotypeMosaic
end
HaplotypeMosaicPair(len) = HaplotypeMosaicPair(HaplotypeMosaic(len), HaplotypeMosaic(len))

struct Prehashed
    hash::UInt
end
hash(x::Prehashed) = x.hash

# utilities for haplotyping
include("haplotyping.jl")

end # module
