# Boundary Enforcement

ASM uses compile-time boundary checks to keep core runtime modules isolated from optional extension domains.

## Compiler Setup

`mix.exs` enables the boundary compiler before the default Mix compilers:

```elixir
compilers: [:boundary | Mix.compilers()]
```

Boundary support is added as a compile-time dependency:

```elixir
{:boundary, path: "vendor/boundary", runtime: false}
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
