module CompensatedAlgorithms

export sum_kahan, sum_oro

import VectorizationBase
import SIMDPirates: Vec, evadd, evsub, vifelse, vabs, vload, vsum, vbroadcast, vless


# D. E. Knuth, The Art of Computer Programming: Seminumerical Algorithms, 1969.
function two_sum(a::T, b::T) where T <: Real
    x = a + b
    z = x - a
    e = (a - (x-z)) + (b-z)
    (x, e)
end

function two_sum(a::T, b::T) where T <: NTuple
    x = evadd(a, b)
    z = evsub(x, a)
    e = evadd(evsub(a, evsub(x, z)),
              evsub(b, z))
    (x, e)
end


# T. J. Dekker. "A Floating-Point Technique for Extending the Available Precision". 1971
function fast_two_sum(a::T, b::T) where T <: Real
    x = a + b

    if abs(a) < abs(b)
        (a_,b_) = (b,a)
    else
        (a_,b_) = (a,b)
    end

    z = x - a_
    e = b_ - z

    x, e
end

function fast_two_sum(a::T, b::T) where T <: NTuple
    x = evadd(a, b)

    t = vless(vabs(a), vabs(b))
    a_ = vifelse(t, b, a)
    b_ = vifelse(t, a, b)

    z = evsub(x, a_)
    e = evsub(b_, z)

    x, e
end


# T. Ogita, S. Rump and S. Oishi, "Accurate sum and dot product",
# SIAM Journal on Scientific Computing, 6(26), 2005.
# DOI: 10.1137/030601818
@generated function cascaded_eft(x::AbstractArray{T},
                                 eft,
                                 rem_handling = Val{:scalar},
                                 ::Val{Ushift} = Val{2}()
                                 )  where {T <: Union{Float32,Float64}, Ushift}
    @assert 0 ≤ Ushift < 6
    U = 1 << Ushift

    W, shift = VectorizationBase.pick_vector_width_shift(T)
    sizeT = sizeof(T)
    WT = W * sizeT
    WU = W * U
    V = Vec{W,T}

    q = quote
        px = pointer(x)
        N = length(x)
        Base.Cartesian.@nexprs $U u -> begin
            s_u = vbroadcast($V, zero($T))
            e_u = vbroadcast($V, zero($T))
        end

        Nshift = N >> $(shift + Ushift)
        offset = 0
        for n in 1:Nshift
            Base.Cartesian.@nexprs $U u -> begin
                xi = vload($V, px + offset)

                s_u, ei = eft(s_u, xi)
                e_u = evadd(e_u, ei)

                offset += $WT
            end
        end

        rem = N & $(WU-1)
        for n in 1:(rem >> $shift)
            xi = vload($V, px + offset)

            s_1, ei = eft(s_1, xi)
            e_1 = evadd(e_1, ei)

            offset += $WT
        end
    end

    if rem_handling <: Val{:mask}
        q_rem = quote
            rem &= $(W-1)
            if rem > 0
                mask = VectorizationBase.mask(Val{$W}(), rem)
                xi = vload($V, px + offset, mask)
                s_1, ei = eft(s_1, xi)
                e_1 = evadd(e_1, ei)
            end
        end
        push!(q.args, q_rem)
    end

    q_reduce = quote
        Base.Cartesian.@nexprs $U u -> let t = u>1
          if t
              (s_1, e) = eft(s_1, s_u)
              e_1 = evadd(e_1, e_u)
              e_1 = evadd(e_1, e)
          end
        end

        s = zero(T)
        e = vsum(e_1)
        for xi in s_1
            s, ei = eft(s, xi.value)
            e += ei
        end
    end
    push!(q.args, q_reduce)

    if rem_handling <: Val{:scalar}
        q_rem = quote
            offset = div(offset, $sizeT) + 1
            while offset <= N
                @inbounds xi = x[offset]
                s, ei = eft(s, xi)
                e += ei

                offset += 1
            end
        end
        push!(q.args, q_rem)
    end

    push!(q.args, :(s+e))

    q
end


sum_kahan(x) = cascaded_eft(x, fast_two_sum)
sum_oro(x) = cascaded_eft(x, two_sum)


relative_error(x, y) = (x - y) / y

using BenchmarkTools

function check(x, eft, rem_handling, ushift)
    v = cascaded_eft(x, eft, Val(rem_handling), Val(ushift))
    e = relative_error(v, Float64(sum(Rational{BigInt}, x)))
    b = @benchmark cascaded_eft($x, $eft, $(Val(rem_handling)), $(Val(ushift)))

    println((nameof(eft), rem_handling, ushift, e, minimum(b.times)))
end

function bench(siz)
    x = siz |> N->randn(N) .* exp.(10 .* randn(N)) |> x->[x;-x;1.0] |> x->x[sortperm(rand(length(x)))];
    for eft in (two_sum, fast_two_sum)
        for rem_handling in (:scalar, :mask)
            for ushift in 0:5
                check(x, eft, rem_handling, ushift)
            end
        end
    end
end

end # module
