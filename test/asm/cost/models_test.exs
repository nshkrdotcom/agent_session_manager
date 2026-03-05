defmodule ASM.Cost.ModelsTest do
  use ASM.TestCase

  alias ASM.Cost.Models

  test "lookup/2 returns amp default rates" do
    assert %{input_rate: 0.0000018, output_rate: 0.0000072} = Models.lookup(:amp, nil)
  end

  test "lookup/2 returns amp model-specific rates" do
    assert %{input_rate: 0.0000015, output_rate: 0.000006} =
             Models.lookup(:amp, "amp-1")
  end
end
