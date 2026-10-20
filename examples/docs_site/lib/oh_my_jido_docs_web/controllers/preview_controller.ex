defmodule OhMyJidoDocsWeb.PreviewController do
  use OhMyJidoDocsWeb, :controller

  alias OhMyJidoDocs.Candidates
  alias OhMyJidoDocsWeb.PreviewCapability

  @max_body_bytes 4 * 1024 * 1024
  @preview_csp "sandbox; default-src 'none'; script-src 'none'; " <>
                 "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; " <>
                 "connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; " <>
                 "form-action 'none'; frame-ancestors 'self'; navigate-to 'none'"

  def show(conn, %{"id" => id} = params) do
    conn = secure_response(conn)
    authority = conn.assigns.preview_authority
    path = Map.get(params, "path", [])

    with :ok <- allowed_path(path),
         {:ok, origin} <- verified_origin(id, authority),
         {:ok, response} <- fetch(origin, path),
         :ok <- accepted_response(response),
         {:ok, type} <- content_type(response) do
      body =
        if is_list(response.body),
          do: response.body |> Enum.reverse() |> IO.iodata_to_binary(),
          else: response.body

      body = rewrite_body(body, type, id, path, conn.assigns.preview_token)

      conn
      |> put_resp_content_type(type)
      |> send_resp(200, body)
    else
      {:error, :not_ready} ->
        send_resp(conn, 409, "The candidate preview is not running or ready.")

      {:error, :path_not_allowed} ->
        send_resp(conn, 404, "This path is not part of the public preview.")

      {:error, :response_too_large} ->
        send_resp(conn, 502, "The preview response exceeded its size limit.")

      {:error, :content_type_not_allowed} ->
        send_resp(conn, 415, "This resource type is not allowed in the preview.")

      {:error, _reason} ->
        send_resp(
          conn,
          502,
          "The isolated preview could not serve this resource. Inspect its process receipt."
        )
    end
  rescue
    _error in [Ecto.NoResultsError, Ecto.Query.CastError, Ecto.CastError, ArgumentError] ->
      conn |> secure_response() |> send_resp(404, "Candidate preview not found.")
  end

  defp secure_response(conn) do
    conn
    |> put_resp_header("content-security-policy", @preview_csp)
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("access-control-allow-origin", "*")
  end

  defp verified_origin(candidate_id, authority) do
    case Candidates.preview_target(candidate_id,
           digest: authority["digest"],
           attempt_id: authority["attempt_id"]
         ) do
      {:ok, %{url: url}} when is_binary(url) ->
        case URI.parse(url) do
          %URI{
            scheme: "http",
            host: "127.0.0.1",
            port: port,
            path: "/",
            userinfo: nil,
            query: nil,
            fragment: nil
          } = uri
          when is_integer(port) and port in 1024..65_535 ->
            {:ok, uri}

          _ ->
            {:error, :not_ready}
        end

      _ ->
        {:error, :not_ready}
    end
  end

  defp allowed_path(segments) do
    if safe_segments?(segments) and public_path?(segments),
      do: :ok,
      else: {:error, :path_not_allowed}
  end

  defp safe_segments?(segments) when is_list(segments) do
    Enum.all?(segments, fn segment ->
      is_binary(segment) and String.valid?(segment) and segment not in [".", ".."] and
        not String.contains?(segment, ["/", "\\", "%", "\0", "?", "#", ":"])
    end)
  end

  defp safe_segments?(_segments), do: false
  defp public_path?([]), do: true
  defp public_path?([""]), do: true
  defp public_path?(["docs" | _]), do: true
  defp public_path?(["assets" | _]), do: true
  defp public_path?(["images" | _]), do: true
  defp public_path?(["fonts" | _]), do: true
  defp public_path?(["favicon.ico"]), do: true
  defp public_path?(_segments), do: false

  defp fetch(origin, segments) do
    url =
      URI.to_string(%{
        origin
        | path:
            "/" <>
              Enum.map_join(segments, "/", fn segment ->
                URI.encode(segment, &URI.char_unreserved?/1)
              end)
      })

    # Construct a new request, not a forwarded Plug request. In particular there
    # are no editorial cookies, auth headers, client headers, query or redirects.
    Req.get(url,
      headers: [{"accept", "*/*"}, {"accept-encoding", "identity"}],
      redirect: false,
      retry: false,
      raw: true,
      decode_body: false,
      connect_options: [timeout: 2000],
      receive_timeout: 5000,
      request_timeout: 6000,
      into: &collect_body/2
    )
  end

  defp collect_body({:data, data}, {request, response}) do
    size = Map.get(response.private, :preview_body_bytes, 0) + byte_size(data)

    if size > @max_body_bytes do
      {:halt,
       {request,
        %{response | body: [], private: Map.put(response.private, :preview_too_large, true)}}}
    else
      body = if is_list(response.body), do: response.body, else: []

      response = %{
        response
        | body: [data | body],
          private: Map.put(response.private, :preview_body_bytes, size)
      }

      {:cont, {request, response}}
    end
  end

  defp accepted_response(%{private: %{preview_too_large: true}}),
    do: {:error, :response_too_large}

  defp accepted_response(%{status: 200}), do: :ok
  defp accepted_response(_response), do: {:error, :upstream_response_rejected}

  defp content_type(response) do
    type =
      response
      |> Req.Response.get_header("content-type")
      |> List.first("")
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.downcase()

    if type in [
         "text/html",
         "text/css",
         "text/plain",
         "image/png",
         "image/jpeg",
         "image/gif",
         "image/webp",
         "image/avif",
         "image/svg+xml",
         "image/x-icon",
         "image/vnd.microsoft.icon",
         "font/woff",
         "font/woff2",
         "font/ttf",
         "font/otf",
         "application/font-woff"
       ] do
      {:ok, type}
    else
      {:error, :content_type_not_allowed}
    end
  end

  defp rewrite_body(body, "text/html", id, path, token) do
    # Navigation plumbing only: the opaque iframe and response CSP, not regex,
    # enforce the security boundary. Every fetchable public reference carries
    # the same verified capability because sandbox requests have no Lax cookie.
    body =
      Regex.replace(
        ~r/\b(href|src|poster|srcset|style)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/iu,
        body,
        fn _match, attribute, double, single, unquoted ->
          reference = Enum.find([double, single, unquoted], &(&1 != "")) || ""

          target =
            case String.downcase(attribute) do
              "style" -> rewrite_css(reference, id, path, token)
              "srcset" -> rewrite_srcset(reference, id, path, token)
              _ -> proxy_reference(reference, id, path, token)
            end

          escaped = target |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
          attribute <> "=\"" <> escaped <> "\""
        end
      )

    Regex.replace(~r/(<style\b[^>]*>)(.*?)(<\/style\s*>)/isu, body, fn _match,
                                                                       opening,
                                                                       css,
                                                                       closing ->
      opening <> rewrite_css(css, id, path, token) <> closing
    end)
  end

  defp rewrite_body(body, "text/css", id, path, token), do: rewrite_css(body, id, path, token)
  defp rewrite_body(body, _type, _id, _path, _token), do: body

  defp rewrite_css(body, id, path, token) do
    body =
      Regex.replace(~r/url\(\s*(["']?)([^)'"\s]+)\1\s*\)/iu, body, fn _match, _quote, reference ->
        target =
          if String.starts_with?(reference, ["data:image/", "data:font/"]),
            do: reference,
            else: proxy_reference(reference, id, path, token)

        "url(\"" <> target <> "\")"
      end)

    Regex.replace(~r/(@import\s+)(["'])(.*?)\2/iu, body, fn _match, prefix, _quote, reference ->
      prefix <> "\"" <> proxy_reference(reference, id, path, token) <> "\""
    end)
  end

  defp rewrite_srcset("data:image/" <> _ = reference, _id, _path, _token), do: reference

  defp rewrite_srcset(reference, id, path, token) do
    reference
    |> String.split(",")
    |> Enum.map_join(", ", fn entry ->
      case String.split(String.trim(entry), ~r/\s+/u, parts: 2) do
        [url] -> proxy_reference(url, id, path, token)
        [url, descriptor] -> proxy_reference(url, id, path, token) <> " " <> descriptor
      end
    end)
  end

  defp proxy_reference("#" <> _ = fragment, _id, _path, _token), do: fragment

  defp proxy_reference(reference, id, path, token) do
    uri = URI.parse(reference)

    if is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.userinfo) do
      base = %URI{scheme: "http", host: "127.0.0.1", path: "/" <> Enum.join(path, "/")}
      merged = URI.merge(base, uri)
      segments = merged.path |> URI.decode() |> String.split("/", trim: true)

      if allowed_path(segments) == :ok do
        PreviewCapability.path(id, segments, token) <> fragment(merged.fragment)
      else
        "#"
      end
    else
      "#"
    end
  rescue
    ArgumentError -> "#"
  end

  defp fragment(nil), do: ""
  defp fragment(value), do: "#" <> URI.encode(value, &URI.char_unreserved?/1)
end
