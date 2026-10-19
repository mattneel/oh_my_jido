# Evaluate only after the healthy candidate reboot/Health/automatic COMMIT and
# healthy verification have passed. No byte corruption or protected mutations.
{:ok, _applications} = Application.ensure_all_started(:elixos_host)
ElixosHost.T10.stage(:fallback)
