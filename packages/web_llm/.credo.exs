%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"]},
      plugins: [{ExSlop, []}],
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {ExSlop.Check.Readability.NarratorDoc, false}
      ]
    }
  ]
}
