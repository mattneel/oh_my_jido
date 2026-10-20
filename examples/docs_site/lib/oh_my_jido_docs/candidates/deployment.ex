defmodule OhMyJidoDocs.Candidates.Deployment do
  @moduledoc false

  alias OhMyJidoDocs.{Candidates, Workspaces}
  alias OhMyJidoDocs.Candidates.{EffectLease, Execution}

  # Staging deliberately runs before this boundary. The durable deployment lease
  # excludes canonical replacement; this workspace lease excludes managed writes
  # through the actual command. No candidate lock is held while its child runs,
  # so the Manager can persist process identity and deliver cancellation.
  def launch(candidate, context, lease, owner, cancel_ref, command)
      when is_function(command, 1) do
    result =
      Workspaces.with_workspace_lease(candidate.workspace_path, fn ->
        with :ok <- launch_permitted(owner, cancel_ref),
             {:ok, current} <- fresh_authorization(candidate, lease),
             :ok <- Execution.verify_context(current, context),
             :ok <- launch_permitted(owner, cancel_ref) do
          command.(current)
        end
      end)

    case result do
      {:error, reason} -> not_started(reason)
      receipt when is_map(receipt) -> receipt
    end
  end

  defp fresh_authorization(candidate, lease) do
    Candidates.with_candidate(candidate.id, fn current ->
      with :ok <- EffectLease.owned(lease),
           :ok <- Candidates.authorized(current, candidate.digest),
           true <- current.adoption_status == "adopted",
           :ok <- Candidates.verify_effect_base(current, deployment: true) do
        {:ok, current}
      else
        false -> {:error, :source_adoption_required}
        {:error, _} = error -> error
      end
    end)
  end

  defp launch_permitted(owner, cancel_ref) do
    if Process.alive?(owner) do
      receive do
        {:cancel, ^cancel_ref} -> {:error, :cancelled}
      after
        0 -> :ok
      end
    else
      {:error, :owner_stopped}
    end
  end

  def not_started(reason) do
    %{
      "status" =>
        if(reason in [:cancelled, :owner_stopped], do: "cancelled", else: "unavailable"),
      "remote_effect" => "not_started",
      "effect" => "not_started",
      "cleanup" => %{"status" => "not_started"},
      "reason" => inspect(reason, limit: 10, printable_limit: 512),
      "output" =>
        "Deployment command was not started: #{inspect(reason, limit: 10, printable_limit: 512)}"
    }
  end
end
