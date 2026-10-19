# Evaluate after normal boot's Health and automatic COMMIT have completed.
{:ok, _applications} = Application.ensure_all_started(:elixos_host)
ElixosHost.T10.verify(:healthy)
