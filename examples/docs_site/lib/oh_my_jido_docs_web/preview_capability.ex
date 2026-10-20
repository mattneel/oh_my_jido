defmodule OhMyJidoDocsWeb.PreviewCapability do
  @moduledoc """
  Short-lived, GET-only access to one verified public preview attempt. Opaque
  sandbox documents cannot use the operator's SameSite=Lax session cookie.
  These signed links grant no editorial API authority and never reach the child.
  """
  import Plug.Conn

  alias OhMyJidoDocs.Candidates
  alias OhMyJidoDocsWeb.{Endpoint, OperatorAuth}

  @salt "docs-public-preview-v1"
  @lifetime_seconds 300

  def init(options), do: options

  def call(conn, _options) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")

    with true <-
           conn.method == "GET" and Map.get(conn.private, :docs_original_method, "GET") == "GET",
         token when is_binary(token) <- conn.params["preview_token"],
         {:ok, claims} <- verify(token, conn.params["id"]) do
      conn |> assign(:preview_authority, claims) |> assign(:preview_token, token)
    else
      false ->
        conn
        |> put_resp_header("allow", "GET")
        |> send_resp(405, "Preview access is GET-only.")
        |> halt()

      _ ->
        conn
        |> send_resp(
          403,
          "This preview link is invalid or expired. Reopen it from the authenticated Studio."
        )
        |> halt()
    end
  end

  def url_for_candidate(candidate_id, session) do
    with true <- OperatorAuth.valid_session?(session),
         {:ok, target} <- Candidates.preview_target(candidate_id),
         {:ok, token} <- sign(target, session) do
      {:ok, path(target.candidate_id, [], token)}
    else
      false -> {:error, :unauthorized}
      {:error, _reason} = error -> error
    end
  end

  def path(candidate_id, segments, token) do
    "/studio/previews/" <>
      URI.encode(candidate_id, &URI.char_unreserved?/1) <>
      "/" <>
      Enum.map_join(segments, "/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end) <>
      "?" <> URI.encode_query(%{"preview_token" => token})
  end

  defp sign(target, session) do
    if OperatorAuth.valid_session?(session) do
      expires_at = min(System.system_time(:second) + @lifetime_seconds, session["expires_at"])

      claims = %{
        "scope" => "public-preview",
        "method" => "GET",
        "candidate_id" => target.candidate_id,
        "digest" => target.digest,
        "attempt_id" => target.attempt_id,
        "credential_version" => session["version"],
        "session_nonce" => session["nonce"],
        "session_expires_at" => session["expires_at"],
        "expires_at" => expires_at
      }

      {:ok, Phoenix.Token.sign(Endpoint, @salt, claims)}
    else
      {:error, :unauthorized}
    end
  end

  defp verify(token, candidate_id) do
    with {:ok,
          %{
            "scope" => "public-preview",
            "method" => "GET",
            "candidate_id" => ^candidate_id,
            "digest" => digest,
            "attempt_id" => attempt,
            "credential_version" => version,
            "session_nonce" => nonce,
            "session_expires_at" => session_expires_at,
            "expires_at" => expires_at
          } = claims} <- Phoenix.Token.verify(Endpoint, @salt, token, max_age: @lifetime_seconds),
         true <-
           is_binary(digest) and is_binary(attempt) and is_binary(version) and is_binary(nonce),
         true <- is_integer(expires_at) and is_integer(session_expires_at),
         true <- expires_at > System.system_time(:second) and expires_at <= session_expires_at,
         true <- OperatorAuth.current_credential_version?(version) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_preview_capability}
    end
  end
end
