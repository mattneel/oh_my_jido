%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "e2e/fixture/", "test/"]},
      plugins: [{ExSlop, []}],
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {ExSlop.Check.Readability.NarratorDoc, false}
      ]
    }
  ]
}
