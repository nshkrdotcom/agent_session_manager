# Boundary Enforcement

ASM uses compile-time boundary checks to keep core runtime modules isolated from optional extension domains.

Compile-time `Boundary` rules are only one part of the contract. Runtime shape
ownership is now explicit too:

- `Zoi` is the canonical boundary-schema layer for new dynamic ASM boundary
  work.
- `ASM.Schema.ProviderOptions`, `ASM.Schema.Event`, and
  `ASM.Schema.RemoteNode` own ASM-local runtime payloads.
- provider-native CLI or protocol schemas stay in the provider repos instead of
  being copied into ASM.
- `NimbleOptions` remains at the public keyword ingress as a transitional
  adapter while schema equivalence is proven.

## Compiler Setup

`mix.exs` enables the boundary compiler before the default Mix compilers:

```elixir
compilers: [:boundary | Mix.compilers()]
```

Boundary support is added as a compile-time dependency:

```elixir
{:boundary, "~> 0.10.4", only: [:dev, :test], runtime: false}
```

## Declared Boundaries

Core boundary:

- `ASM` with `deps: []`

Extension boundaries:

- `ASM.Extensions`
- `ASM.Extensions.Persistence`
- `ASM.Extensions.Routing`
- `ASM.Extensions.Policy`
- `ASM.Extensions.Rendering`
- `ASM.Extensions.Workspace`
- `ASM.Extensions.PubSub`
- `ASM.Extensions.Provider`
- `ASM.Extensions.ProviderSDK`

Each extension boundary currently declares `deps: [ASM]`.

## Lifecycle Rule

Extension lifecycle ownership stays outside core application child specs:

- The core ASM OTP application starts core-only children.
- Host applications (or extension-owned supervisors) decide which extension processes to start.

This keeps both compile-time coupling and runtime ownership clean.

## Enforcement Signal

Running compile with warnings-as-errors executes the boundary compiler:

```bash
mix compile --warnings-as-errors
```

Any core-to-extension dependency without a declared boundary dependency fails compilation.
