# Evaluate explicitly from the no-NIC disposable guest's IEx prompt.
# The returned task still needs fresh human Ask approvals for build/test/NEXT.
{:ok, _applications} = Application.ensure_all_started(:elixos_host)
ElixosHost.T10.stage(:healthy)
