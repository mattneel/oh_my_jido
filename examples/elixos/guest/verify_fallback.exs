# Evaluate after the shim exhausts normal bad-generation attempts and returns
# to the healthy last-good generation. Retain the actual serial transcript.
{:ok, _applications} = Application.ensure_all_started(:elixos_host)
ElixosHost.T10.verify(:fallback)
