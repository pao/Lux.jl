# # Julia & Lux for the Uninitiated

# This is a quick intro to [Lux](https://github.com/LuxDL/Lux.jl) loosely based on:
# 
# 1. [PyTorch's tutorial](https://pytorch.org/tutorials/beginner/deep_learning_60min_blitz.html).
# 2. [Flux's tutorial](https://fluxml.ai/Flux.jl/stable/tutorials/2020-09-15-deep-learning-flux/).
# 3. [Jax's tutorial](https://jax.readthedocs.io/en/latest/jax-101/index.html)
#
# It introduces basic Julia programming, as well `Zygote`, a source-to-source automatic
# differentiation (AD) framework in Julia. We'll use these tools to build a very simple
# neural network. Let's start with importing `Lux.jl`

import Pkg #hide
__DIR = @__DIR__ #hide
pkg_io = open(joinpath(__DIR, "pkg.log"), "w") #hide
Pkg.activate(__DIR; io=pkg_io) #hide
Pkg.instantiate(; io=pkg_io) #hide
Pkg.develop(; path=joinpath(__DIR, "..", ".."), io=pkg_io) #hide
Pkg.precompile(; io=pkg_io) #hide
close(pkg_io) #hide
using Lux, Random

# Now let us control the randomness in our code using proper Pseudo Random Number
# Generator (PRNG)
rng = Random.default_rng()
Random.seed!(rng, 0)

# ## Arrays

# The starting point for all of our models is the `Array` (sometimes referred to as a
# `Tensor` in other frameworks). This is really just a list of numbers, which might be
# arranged into a shape like a square. Let's write down an array with three elements.

x = [1, 2, 3]

# Here's a matrix – a square array with four elements.

x = [1 2; 3 4]

# We often work with arrays of thousands of elements, and don't usually write them down by
# hand. Here's how we can create an array of 5×3 = 15 elements, each a random number from
# zero to one.

x = rand(rng, 5, 3)

# There's a few functions like this; try replacing `rand` with `ones`, `zeros`, or `randn`.

# By default, Julia works stores numbers is a high-precision format called `Float64`. In ML
# we often don't need all those digits, and can ask Julia to work with `Float32` instead.
# We can even ask for more digits using `BigFloat`.

x = rand(BigFloat, 5, 3)
#-
x = rand(Float32, 5, 3)

# We can ask the array how many elements it has.

length(x)

# Or, more specifically, what size it has.

size(x)

# We sometimes want to see some elements of the array on their own.

x
#-
x[2, 3]

# This means get the second row and the third column. We can also get every row of the third
# column.

x[:, 3]

# We can add arrays, and subtract them, which adds or subtracts each element of the array.

x + x
#-
x - x

# Julia supports a feature called *broadcasting*, using the `.` syntax. This tiles small
# arrays (or single numbers) to fill bigger ones.

x .+ 1

# We can see Julia tile the column vector `1:5` across all rows of the larger array.

zeros(5, 5) .+ (1:5)

# The x' syntax is used to transpose a column `1:5` into an equivalent row, and Julia will
# tile that across columns.

zeros(5, 5) .+ (1:5)'

# We can use this to make a times table.

(1:5) .* (1:5)'

# Finally, and importantly for machine learning, we can conveniently do things like matrix
# multiply.

W = randn(5, 10)
x = rand(10)
W * x

# Julia's arrays are very powerful, and you can learn more about what they can do [here](https://docs.julialang.org/en/v1/manual/arrays/).

# ### CUDA Arrays

# CUDA functionality is provided separately by the
# [CUDA.jl package](https://github.com/JuliaGPU/CUDA.jl). If you have a GPU and LuxCUDA
# is installed, Lux will provide CUDA capabilities. For additional details on backends
# see the manual section.

# You can manually add `CUDA`. Once CUDA is loaded you can move any array to the GPU with
# the `cu` function (or the `gpu` function exported by `Lux``), and it supports all of the
# above operations with the same syntax.

using LuxCUDA, LuxAMDGPU

if LuxCUDA.functional()
    x_cu = cu(rand(5, 3))
    @show x_cu
elseif LuxAMDGPU.functional() # Similarly, for AMDGPU
    x_amd = roc(rand(5, 3))
    @show x_amd
end

# ## (Im)mutability

# Lux as you might have read is
# [Immutable by convention](https://lux.csail.mit.edu/dev/introduction/overview#design-principles)
# which means that the core library is built without any form of mutation and all functions
# are pure. However, we don't enforce it in any form. We do **strongly recommend** that
# users extending this framework for their respective applications don't mutate their
# arrays.

x = reshape(1:8, 2, 4)

# To update this array, we should first copy the array.

x_copy = copy(x)
view(x_copy, :, 1) .= 0

println("Original Array ", x)
println("Mutated Array ", x_copy)

# Note that our current default AD engine (Zygote) is unable to differentiate through this
# mutation, however, for these specialized cases it is quite trivial to write custom
# backward passes. (This problem will be fixed once we move towards Enzyme.jl)

# ## Managing Randomness

# We rely on the Julia StdLib `Random` for managing the randomness in our execution. First,
# we create an PRNG (pseudorandom number generator) and seed it.
rng = Xoshiro(0)     # Creates a Xoshiro PRNG with seed 0

# If we call any function that relies on `rng` and uses it via `randn`, `rand`, etc. `rng`
# will be mutated. As we have already established we care a lot about immutability, hence we
# should use `Lux.replicate` on PRNGs before using them.

# First, let us run a random number generator 3 times with the `replicate`d rng.
random_vectors = Vector{Vector{Float64}}(undef, 3)
for i in 1:3
    random_vectors[i] = rand(Lux.replicate(rng), 10)
    println("Iteration $i ", random_vectors[i])
end
@assert random_vectors[1] ≈ random_vectors[2] ≈ random_vectors[3]

# As expected we get the same output. We can remove the `replicate` call and we will get
# different outputs.

for i in 1:3
    println("Iteration $i ", rand(rng, 10))
end

# ## Automatic Differentiation

# Julia has quite a few (maybe too many) AD tools. For the purpose of this tutorial, we will
# use:
#
# 1. [ForwardDiff.jl](https://github.com/JuliaDiff/ForwardDiff.jl) -- For Jacobian-Vector
#    Product (JVP)
# 2. [Zygote.jl](https://github.com/FluxML/Zygote.jl) -- For Vector-Jacobian Product (VJP)
#
# *Slight Detour*: We have had several questions regarding if we will be considering any
# other AD system for the reverse-diff backend. For now we will stick to Zygote.jl, however
# once we have tested Lux extensively with [Enzyme.jl](https://github.com/EnzymeAD/Enzyme.jl),
# we will make the switch.

# Even though, theoretically, a VJP (Vector-Jacobian product - reverse autodiff) and a JVP
# (Jacobian-Vector product - forward-mode autodiff) are similar—they compute a product of a
# Jacobian and a vector—they differ by the computational complexity of the operation. In
# short, when you have a large number of parameters (hence a wide matrix), a JVP is less
# efficient computationally than a VJP, and, conversely, a JVP is more efficient when the
# Jacobian matrix is a tall matrix.

using ComponentArrays, ForwardDiff, Zygote

# ### Gradients

# For our first example, consider a simple function computing ``f(x) = \frac{1}{2}x^T x``,
# where ``\nabla f(x) = x``

f(x) = x' * x / 2
∇f(x) = x  # `∇` can be typed as `\nabla<TAB>`
v = randn(rng, Float32, 4)

# Let's use ForwardDiff and Zygote to compute the gradients.

println("Actual Gradient: ", ∇f(v))
println("Computed Gradient via Reverse Mode AD (Zygote): ", only(Zygote.gradient(f, v)))
println("Computed Gradient via Forward Mode AD (ForwardDiff): ", ForwardDiff.gradient(f, v))

# Note that `AD.gradient` will only work for scalar valued outputs.

# ### Jacobian-Vector Product

# I will defer the discussion on forward-mode AD to
# [https://book.sciml.ai/notes/08-Forward-Mode_Automatic_Differentiation_(AD)_via_High_Dimensional_Algebras/](https://book.sciml.ai/notes/08-Forward-Mode_Automatic_Differentiation_(AD)_via_High_Dimensional_Algebras/). Here let us just look
# at a mini example on how to use it.

f(x) = x .* x ./ 2
x = randn(rng, Float32, 5)
v = ones(Float32, 5)

# Construct the pushforward function. We will write out the function here but in
# practice we recommend using [SparseDiffTools.auto_jacvec](https://docs.sciml.ai/SparseDiffTools/stable/#Jacobian-Vector-and-Hessian-Vector-Products)!

# First we need to create a Tag for ForwardDiff. It is enough to know that this is something
# that you must do. For more details, see the [ForwardDiff Documentation](https://juliadiff.org/ForwardDiff.jl/dev/user/advanced/#Custom-tags-and-tag-checking)!
struct TestTag end

# Going in the details of what is function is doing is beyond the scope of this tutorial.
# But in short, it is constructing a new Dual Vector with the partials set to the input
# to the pushforward function. When this is propagated through the original function
# we get the value and the jvp
function pushforward_forwarddiff(f, x)
    T = eltype(x)
    function pushforward(v)
        v_ = reshape(v, axes(x))
        y = ForwardDiff.Dual{
            ForwardDiff.Tag{TestTag, T}, T, 1}.(x, ForwardDiff.Partials.(tuple.(v_)))
        res = vec(f(y))
        return ForwardDiff.value.(res), vec(ForwardDiff.partials.(res, 1))
    end
    return pushforward
end

pf_f = pushforward_forwarddiff(f, x)

# Compute the jvp.

val, jvp = pf_f(v)
println("Computed Value: f(", x, ") = ", val)
println("JVP: ", jvp[1])

# ### Vector-Jacobian Product

# Using the same function and inputs, let us compute the VJP.

val, pb_f = Zygote.pullback(f, x)

# Compute the vjp.

vjp = only(pb_f(v))
println("Computed Value: f(", x, ") = ", val)
println("VJP: ", vjp[1])

# ## Linear Regression

# Finally, now let us consider a linear regression problem. From a set of data-points
# $\{ (x_i, y_i), i \in \{ 1, \dots, k \}, x_i \in \mathbb{R}^n, y_i \in \mathbb{R}^m \}$,
# we try to find a set of parameters $W$ and $b$, s.t. $f_{W,b}(x) = Wx + b$, which
# minimizes the mean squared error:

# $$L(W, b) \longrightarrow \sum_{i = 1}^{k} \frac{1}{2} \| y_i - f_{W,b}(x_i) \|_2^2$$

# We can write `f` from scratch, but to demonstrate `Lux`, let us use the `Dense` layer.

model = Dense(10 => 5)

rng = Random.default_rng()
Random.seed!(rng, 0)

# Let us initialize the parameters and states (in this case it is empty) for the model.
ps, st = Lux.setup(rng, model)
ps = ps |> ComponentArray

# Set problem dimensions.
n_samples = 20
x_dim = 10
y_dim = 5

# Generate random ground truth W and b.
W = randn(rng, Float32, y_dim, x_dim)
b = randn(rng, Float32, y_dim)

# Generate samples with additional noise.
x_samples = randn(rng, Float32, x_dim, n_samples)
y_samples = W * x_samples .+ b .+ 0.01f0 .* randn(rng, Float32, y_dim, n_samples)
println("x shape: ", size(x_samples), "; y shape: ", size(y_samples))

# For updating our parameters let's use
# [Optimisers.jl](https://github.com/FluxML/Optimisers.jl). We will use Stochastic Gradient
# Descent (SGD) with a learning rate of `0.01`.

using Optimisers

opt = Optimisers.Descent(0.01f0)

# Initialize the initial state of the optimiser
opt_state = Optimisers.setup(opt, ps)

# Define the loss function
function mse(model, ps, st, X, y)
    y_pred, st_new = model(X, ps, st)
    return sum(abs2, y_pred .- y), st_new
end
mse(weight, bias, X, y) = sum(abs2, weight * X .+ bias .- y)
loss_function(ps, X, y) = mse(model, ps, st, X, y)

println("Loss Value with ground true parameters: ", mse(W, b, x_samples, y_samples))

for i in 1:100
    ## In actual code, don't use globals. But here I will simply for the sake of
    ## demonstration
    global ps, st, opt_state
    ## Compute the gradient using the pullback API to update the states
    (loss, st), pb_f = Zygote.pullback(loss_function, ps, x_samples, y_samples)
    ## We pass nothing as the seed for `st`, since we don't want to propagate any gradient
    ## for st
    gs = pb_f((one(loss), nothing))[1]
    ## Update model parameters
    ## `Optimisers.update` can be used if mutation is not desired
    opt_state, ps = Optimisers.update!(opt_state, ps, gs)
    (i % 10 == 1 || i == 100) && println(lazy"Loss Value after $i iterations: $loss")
end
