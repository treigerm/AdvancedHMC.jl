abstract type AbstractProposal end
abstract type AbstractHamiltonianTrajectory{I<:AbstractIntegrator} <: AbstractProposal end

abstract type StaticTrajectory{I<:AbstractIntegrator} <: AbstractHamiltonianTrajectory{I} end
struct TakeLastProposal{I<:AbstractIntegrator} <: StaticTrajectory{I}
    integrator  ::  I
    n_steps     ::  Int
end

function propose(prop::TakeLastProposal, h::Hamiltonian, θ::AbstractVector{T}, r::AbstractVector{T}) where {T<:Real}
    θ, r, _ = steps(prop.integrator, h, θ, r, prop.n_steps)
    return θ, -r
end

abstract type DynamicTrajectory{I<:AbstractIntegrator} <: AbstractHamiltonianTrajectory{I} end
abstract type NoUTurnTrajectory{I<:AbstractIntegrator} <: DynamicTrajectory{I} end
struct SliceNUTS{I<:AbstractIntegrator} <: NoUTurnTrajectory{I}
    integrator  ::  I
end

struct MultinomialNUTS{I<:AbstractIntegrator} <: NoUTurnTrajectory{I}
    integrator  ::  I
end

function SliceNUTS(h::Hamiltonian, θ::AbstractVector{T}) where {T<:Real}
    return SliceNUTS(Leapfrog(find_good_eps(h, θ)))
end

# TODO: implement a more efficient way to build the balance tree
function build_tree(rng::AbstractRNG, nt::NoUTurnTrajectory{I}, h::Hamiltonian, θ::AbstractVector{T}, r::AbstractVector{T}, logu::AbstractFloat, v::Int, j::Int;
                    Δ_max::AbstractFloat=1000.0) where {I<:AbstractIntegrator,T<:Real}
    if j == 0
        _H = hamiltonian_energy(h, θ, r)
        # Base case - take one leapfrog step in the direction v.
        θ′, r′, _is_valid = step(nt.integrator, h, θ, r)
        # TODO: pass old H to save computation
        _H′ = _is_valid ? hamiltonian_energy(h, θ′, r′) : Inf
        n′ = (logu <= -_H′) ? 1 : 0
        s′ = (logu < Δ_max + -_H′) ? 1 : 0
        α′ = exp(min(0, _H′ -_H))

        return θ′, r′, θ′, r′, θ′, r′, n′, s′, α′, 1
    else
        # Recursion - build the left and right subtrees.
        θm, rm, θp, rp, θ′, r′, n′, s′, α′, n′α = build_tree(rng, nt, h, θ, r, logu, v, j - 1)

        if s′ == 1
            if v == -1
                θm, rm, _, _, θ′′, r′′, n′′, s′′, α′′, n′′α = build_tree(rng, nt, h, θm, rm, logu, v, j - 1)
            else
                _, _, θp, rp, θ′′, r′′, n′′, s′′, α′′, n′′α = build_tree(rng, nt, h, θp, rp, logu, v, j - 1)
            end
            if rand(rng) < n′′ / (n′ + n′′)
                θ′ = θ′′
                r′ = r′′
            end
            α′ = α′ + α′′
            n′α = n′α + n′′α
            s′ = s′′ * (dot(θp - θm, ∂H∂r(h, rm)) >= 0 ? 1 : 0) * (dot(θp - θm, ∂H∂r(h, rp)) >= 0 ? 1 : 0)
            n′ = n′ + n′′
        end

        return θm, rm, θp, rp, θ′, r′, n′, s′, α′, n′α
    end
end

build_tree(nt::NoUTurnTrajectory{I}, h::Hamiltonian, θ::AbstractVector{T}, r::AbstractVector{T}, logu::AbstractFloat, v::Int, j::Int;
           Δ_max::AbstractFloat=1000.0) where {I<:AbstractIntegrator,T<:Real} = build_tree(GLOBAL_RNG, nt, h, θ, r, logu, v, j; Δ_max=Δ_max)

function propose(rng::AbstractRNG, nt::NoUTurnTrajectory{I}, h::Hamiltonian, θ::AbstractVector{T}, r::AbstractVector{T}; j_max::Int=10) where {I<:AbstractIntegrator,T<:Real}
    _H = hamiltonian_energy(h, θ, r)
    logu = log(rand(rng)) - _H

    θm = θ; θp = θ; rm = r; rp = r; j = 0; θ_new = θ; r_new = r; n = 1; s = 1

    # local da_stats

    while s == 1 && j <= j_max

        v = rand(rng, [-1, 1])
        if v == -1
            θm, rm, _, _, θ′, r′,n′, s′, α, nα = build_tree(rng, nt, h, θm, rm, logu, v, j)
        else
            _, _, θp, rp, θ′, r′,n′, s′, α, nα = build_tree(rng, nt, h, θp, rp, logu, v, j)
        end

        if s′ == 1
            if rand(rng) < min(1, n′ / n)
                θ_new = θ′
                r_new = r′
            end
        end

        n = n + n′
        s = s′ * (dot(θp - θm, ∂H∂r(h, rm)) >= 0 ? 1 : 0) * (dot(θp - θm, ∂H∂r(h, rp)) >= 0 ? 1 : 0)
        j = j + 1

        # da_stats = α / nα

    end

    return θ_new, r_new, 2^j
end

propose(nt::NoUTurnTrajectory{I}, h::Hamiltonian, θ::AbstractVector{T}, r::AbstractVector{T};
        j_max::Int=10) where {I<:AbstractIntegrator,T<:Real} = propose(GLOBAL_RNG, nt, h, θ, r; j_max=j_max)

function MultinomialNUTS(h::Hamiltonian, θ::AbstractVector{T}) where {T<:Real}
    return MultinomialNUTS(Leapfrog(find_good_eps(h, θ)))
end