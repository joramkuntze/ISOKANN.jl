### ISOKANN target transformations

"""
    TransformPseudoInv(normalize, direct, eigenvecs, permute)

Compute the target by approximately inverting the action of K with the Moore-Penrose pseudoinverse.

If `direct==true` solve `chi * pinv(K(chi))`, otherwise `inv(K(chi) * pinv(chi)))`.
`eigenvecs` specifies whether to use the eigenvectors of the schur matrix.
`normalize` specifies whether to renormalize the resulting target vectors.
`permute` specifies whether to permute the target for stability.
"""
@kwdef struct TransformPseudoInv
  normalize::Bool = true
  direct::Bool = true
  eigenvecs::Bool = true
  permute::Bool = true
end

function isotarget(model, xs, ys, t::TransformPseudoInv)
  (; normalize, direct, eigenvecs, permute) = t
  chi = model(xs)
  size(chi, 1) > 1 || error("TransformPseudoInv does not work with one dimensional chi functions")

  cs = model(ys)::AbstractArray{<:Number,3}
  kchi = StatsBase.mean(cs[:, :, :], dims=2)[:, 1, :]

  if direct
    Kinv = chi * pinv(kchi)
    s = schur(Kinv)
    T = eigenvecs ? inv(s.vectors) : I
    target = T * Kinv * kchi
  else
    K = kchi * pinv(chi)
    s = schur(K)
    T = eigenvecs ? inv(s.vectors) : I
    target = T * inv(K) * kchi
  end

  normalize && (target = target ./ norm.(eachrow(target), 1) .* size(target, 2))
  permute && (target = fixperm(target, chi))

  return target
end


""" TransformISA(permute)

Compute the target via the inner simplex algorithm (without feasiblization routine).
`permute` specifies whether to apply the stabilizing permutation """
@kwdef struct TransformISA
  permute::Bool = true
end

# we cannot use the PCCAPAlus inner simplex algorithm because it uses feasiblize!,
# which in turn assumes that the first column is equal to one.
function myisa(X)
  inv(X[PCCAPlus.indexmap(X), :])
end

function isotarget(model, xs::T, ys, t::TransformISA) where {T}
  chi = model(xs)
  size(chi, 1) > 1 || error("TransformISA does not work with one dimensional chi functions")
  cs = model(ys)
  ks = StatsBase.mean(cs[:, :, :], dims=2)[:, 1, :]
  ks = cpu(ks)
  chi = cpu(chi)
  target = myisa(ks')' * ks
  t.permute && (target = fixperm(target, chi))
  return T(target)
end

""" TransformShiftscale()

Classical 1D shift-scale (ISOKANN 1) """
struct TransformShiftscale end

function isotarget(model, xs, ys, t::TransformShiftscale)
  cs = model(ys)
  size(cs, 1) == 1 || error("TransformShiftscale only works with one dimensional chi functions")
  ks = StatsBase.mean(cs[:, :, :], dims=2)[:, 1, :]
  target = (ks .- minimum(ks)) ./ (maximum(ks) - minimum(ks))
  return target
end


# TODO: design decision: do we want this as outer type or as part of what we have inside the other transforms?
""" TransformStabilize(transform, last=nothing)

Wraps another transform and permutes its target to match the previous target

Currently we also have the stablilization (wrt to the model though) inside each Transform. TODO: Decide which to keep
"""
@kwdef mutable struct Stabilize2
  transform
  last = nothing
end

function isotarget(model, xs, ys, t::Stabilize2)
  target = isotarget(model, xs, ys, t.transform)
  isnothing(t.last) && (t.last = target)
  if t.transform isa TransformShiftscale  # TODO: is this even necessary?
    if (sum(abs, target - t.last)) > length(target) / 2
      println("flipping")
      target .= 1 .- target
    end
    t.last = target
    return target
  else
    return fixperm(target, t.last)
  end
end


### Permutation - stabilization
import Combinatorics

"""
    fixperm(new, old)

Permutes the rows of `new` such as to minimize L1 distance to `old`.

# Arguments
- `new`: The data to match to the reference data.
- `old`: The reference data.
"""
function fixperm(new, old)
  # TODO: use the hungarian algorithm for larger systems
  n = size(new, 1)
  p = argmin(Combinatorics.permutations(1:n)) do p
    norm(new[p, :] - old, 1)
  end
  new[p, :]
end

using Random: shuffle
function test_fixperm(n=3)
  old = rand(n, n)
  @show old
  new = old[shuffle(1:n), :]
  new = fixperm(new, old)
  @show new
  norm(new - old) < 1e-9
end
