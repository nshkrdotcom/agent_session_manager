defmodule Boundary do
  @moduledoc """
  Minimal boundary declaration macro used by the local boundary compiler.
  """

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    deps = Keyword.get(opts, :deps, [])
    exports = Keyword.get(opts, :exports, [])

    quote bind_quoted: [deps: deps, exports: exports] do
      @boundary_deps deps
      @boundary_exports exports

      @doc false
      @spec __boundary__(:deps | :exports | :module | :opts) :: term()
      def __boundary__(:deps), do: @boundary_deps
      def __boundary__(:exports), do: @boundary_exports
      def __boundary__(:module), do: __MODULE__
      def __boundary__(:opts), do: [deps: @boundary_deps, exports: @boundary_exports]
    end
  end
end
