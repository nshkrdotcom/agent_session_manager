defmodule ASM.TestCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: true

      import Supertester.Assertions, only: [assert_process_alive: 1, assert_process_dead: 1]
      import Supertester.OTPHelpers, only: [wait_for_process_death: 1, wait_for_process_death: 2]

      import Supertester.SupervisorHelpers,
        only: [wait_for_supervisor_stabilization: 1, wait_for_supervisor_stabilization: 2]
    end
  end
end
