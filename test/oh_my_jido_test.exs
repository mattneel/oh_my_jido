defmodule OhMyJidoTest do
  use ExUnit.Case
  doctest OhMyJido

  test "greets the world" do
    assert OhMyJido.hello() == :world
  end
end
