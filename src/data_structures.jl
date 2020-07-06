"""
Data structure for recording haplotype mosaic of one strand:
`start[i]` to `start[i+1]` has haplotype `haplotypelabel[i]`
in window `window[i]` of a `CompressedWindow`. `start[end]` to
`length` has haplotype `haplotypelabel[end]` in `window[end]`
"""
struct HaplotypeMosaic
    length::Int
    start::Vector{Int}
    window::Vector{Int}
    haplotypelabel::Vector{Int32}
end
HaplotypeMosaic(len) = HaplotypeMosaic(len, Int[], Int[], Int32[])

# data structure for recording haplotype mosaic of two strands
struct HaplotypeMosaicPair
    strand1::HaplotypeMosaic
    strand2::HaplotypeMosaic
end
HaplotypeMosaicPair(len) = HaplotypeMosaicPair(HaplotypeMosaic(len), HaplotypeMosaic(len))

"""
Data structure for keeping track of unique haplotypes in each window. 

- `uniqueindex`: the unique haplotype indices of each window.
- `hapmap`: information to map every haplotype in each window to the unique one
- `range`: range of SNPs in each window (may have overlaps in the first 2 due to flanking windows)

Let `w` be the current window, then `uniqueindex[w]` is the unique haplotype indices
of window `w`. `hapmap[w]` maps every haplotype to its unique haplotype. `range[w]`
is where the range of SNPs where the unique haplotypes are computed (may have overlaps
in beginning and end). Once the best haplotype pair (h1, h2) is identified, one can 
use `hapmap` to generate a set of redundant haplotypes in window `w`. 

# Example:

Suppose in window `w` there are 9 haplotypes (represented by different letters):

    H[w, :] = [a b b c b d a d a]

then

    uniqueindex[w]  = [1 2 4 6]
    hapmap[w] = [1 2 2 4 2 6 1 6 1].

`hapmap` is used to find the set of matching haplotypes after identifying the best
haplotype pair. If (b, c) is the optimal haplotype pair in the current window, then 
the set of haplotypes that matches (b, c) is in columns {2, 3, 4, 5}
"""
struct UniqueHaplotypeMaps
    uniqueindex::Vector{Vector{Int}}
    hapmap::Vector{Vector{Int}}
    range::Vector{UnitRange}
end
UniqueHaplotypeMaps(windows::Int, haps::Int) = UniqueHaplotypeMaps(Vector{Vector{Int}}(undef, windows), [zeros(Int, haps) for i in 1:windows], [1:0 for i in 1:windows])

"""
Data structure for storing all haplotypes that match the optimal haplotype in each window for a person, keeping track of strand.

+ strand1[w] stores a BitVector for window `w`. length(strand1[w]) = number of haplotypes. Entries of this BitVector is 1 if that haplotype matches the optimal haplotype.
"""
struct OptimalHaplotypeSet
    strand1::Vector{BitSet}
    strand2::Vector{BitSet}
end
OptimalHaplotypeSet(windows::Int) = OptimalHaplotypeSet([BitSet() for i in 1:windows], [BitSet() for i in 1:windows])

function findsmallest(x::AbstractSet{<:Integer})
    length(x) == 0 && return nothing
    s = first(x)
    for i in x
        if i < s
            s = i
        end
    end
    return s
end
