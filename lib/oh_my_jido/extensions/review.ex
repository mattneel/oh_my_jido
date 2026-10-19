defmodule OhMyJido.Extensions.Review do
  @moduledoc """
  Bounded risk hints from actual workspace Git changes.

  The default source reuses `OhMyJido.Git.diff/2`, which invokes the authorized
  `OhMyJido.Process.run/4` boundary and disables external diff/text conversion.
  This route needs both `:review` and the fixed `:git` grant, not arbitrary exec.
  Alternatively an approved `:review` binding may implement `:diff`, returning
  `%{source: :workspace_git, diff: binary, truncated: boolean}` from its own
  confined Git operation. Model-submitted diff text is never an input.

  Optional host enrichment receives only the captured bounded diff and its hash
  via `:review`; it requires a separate sensitive external approval. Host findings
  are untrusted suggestions and must cite a changed path/line already present in
  the captured diff. Neither rules nor host suggestions prove exploitability,
  that a possible token is live, or complete security. Nothing is executed from
  a diff and no reviewed effect is automatically approved.

  Hosts must honor deadlines/bounds and close subprocess/model resources before
  returning. Persistent adapter resources may implement `close_session/2`.
  """

  alias OhMyJido.{Context, Git, Host, Redact, Tool, Workspace}

  @callback invoke(Context.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback close_session(Context.t(), keyword()) :: :ok | {:error, term()}
  @optional_callbacks close_session: 2

  @token ~r/\b(?:gh[pousr]_[A-Za-z0-9]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})\b/
  @assignment ~r/\b(?:api[_-]?key|secret|password|access[_-]?token|client[_-]?secret)\b\s*(?:=>|=|:)\s*["']([^"'\s]{8,})["']/i
  @private_key ~r/-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/
  @execution ~r/(?:\b(?:Code\.(?:eval_string|eval_quoted|compile_string)|System\.cmd|String\.to_atom|eval|exec)|(?<!\w)(?::os\.cmd|:erlang\.binary_to_term))\s*\(/
  @destructive ~r/(?:\bFile\.rm_rf!?\s*\(|\brm\s+(?:[^\n]{0,64}\s)?-[a-z]*r[a-z]*f|\brm\s+(?:[^\n]{0,64}\s)?-[a-z]*f[a-z]*r|\b(?:DROP|TRUNCATE)\s+TABLE\b|\bgit\s+reset\s+--hard\b|\bgit\s+clean\s+-[a-z]*f|\bgit\s+push\b[^\n]{0,128}(?:--force|-f)\b)/i
  @hunk ~r/\A@@ -(\d{1,10})(?:,\d{1,10})? \+(\d{1,10})(?:,\d{1,10})? @@/
  @risk_order %{none: 0, medium: 1, high: 2, critical: 3}

  @doc false
  def perform(context, params) do
    with {:ok, params} <- limits(context, params),
         :ok <-
           Tool.authorize(context, :review, %{
             operation: :diff,
             source: params.source,
             staged: params.staged,
             paths: params.paths,
             sensitive: false,
             external: false,
             mutates: false
           }),
         {:ok, captured} <- capture(context, params),
         scanned = scan(context, captured, params),
         {:ok, scanned} <- enrich(context, params, captured, scanned) do
      findings = Enum.reverse(scanned.findings)

      {:ok,
       %{
         source: :workspace_git,
         evidence_origin: captured.origin,
         trust: :untrusted,
         diff_sha256: captured.sha256,
         diff_bytes: byte_size(captured.diff),
         diff_truncated: captured.truncated,
         findings: findings,
         findings_truncated:
           scanned.finding_count > params.max_findings or scanned.host_findings_truncated,
         risk: scanned.risk,
         approval_required: scanned.approval_required,
         security_certainty: :limited,
         risk_assessment:
           if(captured.truncated or scanned.incomplete,
             do: :incomplete,
             else: :observed_diff_only
           ),
         limitations: scanned.limitations |> MapSet.to_list() |> Enum.sort() |> Enum.take(20),
         limits: %{diff_bytes: params.max_diff_bytes, findings: params.max_findings},
         scope: %{staged: params.staged, paths: params.paths}
       }}
    end
  end

  @doc "Human-initiated real-workspace diff smoke; never accepts supplied evidence."
  def smoke(execution_context, opts \\ []) do
    if Keyword.get(opts, :human_initiated, false) do
      OhMyJido.Tools.Review.run(
        Map.new(Keyword.take(opts, [:staged, :source, :enrich, :paths])),
        execution_context
      )
    else
      {:error, :human_initiated_required}
    end
  end

  defp limits(context, params) do
    cap = Map.get(context.limits, :review_diff_bytes, 262_144)
    findings = Map.get(context.limits, :review_findings, 100)

    if is_integer(cap) and cap >= 256 and is_integer(findings) and findings > 0 and
         Enum.all?(params.paths, fn path ->
           byte_size(path) <= 4096 and String.valid?(path) and not String.contains?(path, <<0>>)
         end) do
      {:ok,
       %{
         params
         | max_diff_bytes: min(params.max_diff_bytes, cap),
           max_findings: min(params.max_findings, findings)
       }}
    else
      {:error, :invalid_review_limits}
    end
  end

  defp capture(context, %{source: "git"} = params) do
    with {:ok, result} <-
           Git.diff(context,
             cached: params.staged,
             paths: params.paths,
             context_lines: 3,
             timeout: params.timeout_ms,
             max_output_bytes: params.max_diff_bytes
           ) do
      {:ok, captured(result.stdout, result.truncated, :process)}
    end
  end

  defp capture(context, %{source: "host"} = params) do
    with {:ok, paths} <- selected_paths(context, params.paths),
         {:ok, workspace} <- Workspace.resolve(context, "."),
         {:ok, %{source: :workspace_git, diff: diff, truncated: truncated}} <-
           invoke(context, %{
             operation: :diff,
             workspace: workspace,
             paths: paths,
             staged: params.staged,
             timeout_ms: params.timeout_ms,
             max_diff_bytes: params.max_diff_bytes
           }),
         true <- is_binary(diff) and is_boolean(truncated) do
      clipped = byte_size(diff) > params.max_diff_bytes
      diff = if clipped, do: binary_part(diff, 0, params.max_diff_bytes), else: diff
      {:ok, captured(diff, clipped or truncated, :approved_host)}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_host_response, :review_diff}}
    end
  end

  defp invoke(context, request) do
    case Host.call(context, :invoke, [:review, request]) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {:capability_unavailable, :review}} = error ->
        error

      {:error, %{effect: :uncertain}} ->
        {:error, %{reason: :host_callback_failed, capability: :review, effect: :uncertain}}

      {:error, _reason} ->
        {:error, %{reason: :host_callback_failed, capability: :review, effect: :unknown}}

      _invalid ->
        {:error, {:invalid_host_response, :review}}
    end
  end

  defp captured(diff, truncated, origin) do
    %{
      diff: diff,
      truncated: truncated,
      origin: origin,
      sha256: Base.encode16(:crypto.hash(:sha256, diff), case: :lower)
    }
  end

  defp selected_paths(context, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, selected} ->
      with {:ok, absolute} <- Workspace.resolve(context, path, allow_missing: true),
           relative when is_binary(relative) <- Workspace.relative(context, absolute) do
        {:cont, {:ok, [relative | selected]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp scan(context, captured, params) do
    scope =
      if params.staged,
        do: "Only the selected tracked staged diff is inspected",
        else: "Only the selected tracked unstaged diff is inspected"

    state = %{
      path: nil,
      old_path: nil,
      new_path: nil,
      old_line: nil,
      new_line: nil,
      deleted: MapSet.new(),
      anchors: MapSet.new(),
      findings: [],
      finding_count: 0,
      max_findings: params.max_findings,
      secrets: captured.diff |> secret_values() |> Enum.uniq(),
      risk: :none,
      approval_required: false,
      incomplete: false,
      host_findings_truncated: false,
      limitations:
        MapSet.new([
          scope,
          "Untracked files are not part of this diff",
          "Heuristic and host findings are risk hints, not proof of exploitability or complete security"
        ])
    }

    state =
      if captured.truncated,
        do:
          limitation(
            state,
            "Diff output was truncated; omitted and partial lines are not reviewed"
          ),
        else: state

    if String.valid?(captured.diff) do
      lines = String.split(captured.diff, "\n")

      lines =
        if captured.truncated and not String.ends_with?(captured.diff, "\n"),
          do: Enum.drop(lines, -1),
          else: lines

      Enum.reduce(lines, state, &scan_line(context, &1, &2))
    else
      limitation(
        %{state | incomplete: true},
        "Diff bytes are not complete UTF-8 text; no textual findings are claimed"
      )
    end
  end

  defp scan_line(_context, "diff --git " <> _header, state),
    do: %{state | path: nil, old_path: nil, new_path: nil, old_line: nil, new_line: nil}

  defp scan_line(context, "--- " <> path, %{old_line: nil} = state) do
    case diff_path(context, path, "a/") do
      {:ok, path} -> %{state | old_path: path}
      :deleted -> state
      :unknown -> limitation(%{state | incomplete: true}, "An unresolved diff path was omitted")
    end
  end

  defp scan_line(context, "+++ " <> path, %{new_line: nil} = state) do
    case diff_path(context, path, "b/") do
      {:ok, path} -> %{state | path: path, new_path: path}
      :deleted -> %{state | path: state.old_path, new_path: nil}
      :unknown -> limitation(%{state | incomplete: true}, "An unresolved diff path was omitted")
    end
  end

  defp scan_line(_context, "@@ " <> _header = line, state) do
    case Regex.run(@hunk, line) do
      [_match, old_line, new_line] ->
        %{state | old_line: String.to_integer(old_line), new_line: String.to_integer(new_line)}

      _invalid ->
        limitation(
          %{state | old_line: nil, new_line: nil, incomplete: true},
          "An unsupported or malformed diff hunk was omitted"
        )
    end
  end

  defp scan_line(_context, "+" <> text, %{path: path, new_line: line} = state)
       when is_binary(path) and is_integer(line) do
    state = %{state | new_line: line + 1, anchors: MapSet.put(state.anchors, {path, :new, line})}

    text
    |> rules()
    |> Enum.reduce(state, fn {category, risk, message}, acc ->
      add_finding(acc, %{
        path: path,
        line: line,
        side: :new,
        category: category,
        risk: risk,
        message: message,
        approval_required: true,
        confidence: :inferred,
        origin: :heuristic
      })
    end)
  end

  defp scan_line(_context, "-" <> _text, %{path: path, old_line: line} = state)
       when is_binary(path) and is_integer(line) do
    state = %{
      state
      | old_line: line + 1,
        anchors: MapSet.put(state.anchors, {path, :old, line})
    }

    if is_nil(state.new_path) and not MapSet.member?(state.deleted, path) do
      state
      |> Map.put(:deleted, MapSet.put(state.deleted, path))
      |> add_finding(%{
        path: path,
        line: line,
        side: :old,
        category: :destructive_effect,
        risk: :high,
        message: "Tracked file removed; confirm that deletion and recovery are intentional",
        approval_required: true,
        confidence: :inferred,
        origin: :heuristic
      })
    else
      state
    end
  end

  defp scan_line(_context, " " <> _text, %{old_line: old, new_line: new} = state)
       when is_integer(old) and is_integer(new),
       do: %{state | old_line: old + 1, new_line: new + 1}

  defp scan_line(_context, "Binary files " <> _header, state),
    do: limitation(%{state | incomplete: true}, "Binary diff content is not inspected")

  defp scan_line(_context, "GIT binary patch" <> _header, state),
    do: limitation(%{state | incomplete: true}, "Binary diff content is not inspected")

  defp scan_line(_context, "diff --cc " <> _header, state),
    do:
      limitation(
        %{
          state
          | path: nil,
            old_path: nil,
            new_path: nil,
            old_line: nil,
            new_line: nil,
            incomplete: true
        },
        "Combined merge diffs are not inspected"
      )

  defp scan_line(_context, _line, state), do: state

  defp rules(text) do
    []
    |> rule(
      Regex.match?(@token, text) or Regex.match?(@private_key, text) or possible_assignment?(text),
      {:secret, :critical,
       "Possible embedded credential or private key; redact and assess rotation before sharing"}
    )
    |> rule(
      Regex.match?(@execution, text),
      {:dynamic_execution, :high,
       "Added dynamic execution, process launch, unsafe deserialization or atom creation; inspect input provenance and confinement"}
    )
    |> rule(
      Regex.match?(@destructive, text),
      {:destructive_effect, :high,
       "Added potentially destructive filesystem, database or Git operation; require explicit effect approval"}
    )
  end

  defp rule(rules, true, finding), do: [finding | rules]
  defp rule(rules, false, _finding), do: rules

  defp possible_assignment?(text) do
    case Regex.run(@assignment, text) do
      [_match, value] -> not placeholder?(value)
      nil -> false
    end
  end

  defp placeholder?(value),
    do:
      String.starts_with?(value, ["${", "<", "example", "placeholder", "REDACTED", "[REDACTED]"])

  defp secret_values(text) do
    tokens = Regex.scan(@token, text) |> Enum.map(&hd/1)

    assignments =
      Regex.scan(@assignment, text)
      |> Enum.map(fn [_match, value] -> value end)
      |> Enum.reject(&placeholder?/1)

    tokens ++ assignments
  end

  defp add_finding(state, finding) do
    findings =
      if state.finding_count < state.max_findings,
        do: [finding | state.findings],
        else: state.findings

    %{
      state
      | findings: findings,
        finding_count: state.finding_count + 1,
        risk: higher_risk(state.risk, finding.risk),
        approval_required: state.approval_required or finding.approval_required
    }
  end

  defp enrich(_context, %{enrich: false}, _captured, state), do: {:ok, state}

  defp enrich(context, params, captured, state) do
    request = %{
      operation: :review,
      diff: captured.diff,
      diff_sha256: captured.sha256,
      diff_truncated: captured.truncated,
      staged: params.staged,
      paths: params.paths,
      max_findings: params.max_findings,
      timeout_ms: params.timeout_ms
    }

    with :ok <-
           Tool.authorize(context, :review, %{
             operation: :review,
             sensitive: true,
             external: true,
             mutates: false,
             diff_sha256: request.diff_sha256,
             diff_bytes: byte_size(captured.diff)
           }),
         {:ok, %{findings: findings} = result} <- invoke(context, request),
         true <- is_list(findings) do
      selected = Enum.take(findings, params.max_findings + 1)

      truncated =
        length(selected) > params.max_findings or Map.get(result, :truncated, false) == true

      state =
        if truncated,
          do:
            limitation(
              %{state | incomplete: true, host_findings_truncated: true},
              "Host review findings were truncated"
            ),
          else: state

      state = Enum.reduce(Enum.take(selected, params.max_findings), state, &host_finding/2)
      state = host_limitations(state, Map.get(result, :limitations, []))
      {:ok, state}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_host_response, :review}}
    end
  end

  defp host_finding(
         %{path: path, line: line, category: category, risk: risk, message: message} = candidate,
         state
       ) do
    side = side(Map.get(candidate, :side, :new))
    category = category(category)
    risk = risk(risk)

    if valid_location?(path, line, side) and not is_nil(category) and not is_nil(risk) and
         is_binary(message) and String.valid?(message) and
         MapSet.member?(state.anchors, {path, side, line}) do
      finding = %{
        path: path,
        line: line,
        side: side,
        category: category,
        risk: risk,
        message: bounded_message(message, state.secrets),
        confidence: :inferred,
        approval_required:
          Map.get(candidate, :approval_required, false) == true or risk in [:high, :critical],
        origin: :host_review,
        trust: :untrusted
      }

      add_finding(state, finding)
    else
      limitation(state, "Invalid or unanchored host review findings were omitted")
    end
  end

  defp host_finding(_candidate, state),
    do: limitation(state, "Invalid or unanchored host review findings were omitted")

  defp valid_location?(path, line, side) do
    is_binary(path) and byte_size(path) <= 4096 and is_integer(line) and line > 0 and
      not is_nil(side)
  end

  defp host_limitations(state, limitations) when is_list(limitations) do
    Enum.reduce(Enum.take(limitations, 10), state, fn message, acc ->
      if is_binary(message) and String.valid?(message),
        do: limitation(acc, "Host review: " <> bounded_message(message, state.secrets)),
        else: limitation(acc, "Invalid host review limitations were omitted")
    end)
  end

  defp host_limitations(state, _limitations),
    do: limitation(state, "Invalid host review limitations were omitted")

  defp bounded_message(message, secrets) do
    message = Redact.sanitize(message, secrets, 512)
    if byte_size(message) <= 512, do: message, else: valid_prefix(binary_part(message, 0, 512))
  end

  defp side(value) when value in [:new, "new"], do: :new
  defp side(value) when value in [:old, "old"], do: :old
  defp side(_value), do: nil
  defp category(value) when value in [:secret, "secret"], do: :secret

  defp category(value) when value in [:dynamic_execution, "dynamic_execution"],
    do: :dynamic_execution

  defp category(value) when value in [:destructive_effect, "destructive_effect"],
    do: :destructive_effect

  defp category(value) when value in [:correctness, "correctness"], do: :correctness
  defp category(_value), do: nil
  defp risk(value) when value in [:medium, "medium"], do: :medium
  defp risk(value) when value in [:high, "high"], do: :high
  defp risk(value) when value in [:critical, "critical"], do: :critical
  defp risk(_value), do: nil

  defp higher_risk(left, right),
    do: if(@risk_order[left] >= @risk_order[right], do: left, else: right)

  defp limitation(state, message),
    do: %{state | limitations: MapSet.put(state.limitations, message)}

  defp diff_path(_context, "/dev/null", _prefix), do: :deleted

  defp diff_path(context, encoded, prefix) do
    with true <- byte_size(encoded) <= 16_386,
         {:ok, path} <- unquote_path(encoded),
         true <- String.starts_with?(path, prefix),
         path = binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix)),
         true <- path != "" and byte_size(path) <= 4096 and String.valid?(path),
         relative when is_binary(relative) <- Workspace.relative(context, path),
         false <- ".git" in Path.split(relative) do
      {:ok, relative}
    else
      _invalid -> :unknown
    end
  end

  defp unquote_path(<<34, rest::binary>>) do
    if String.ends_with?(rest, "\""),
      do: quoted_bytes(binary_part(rest, 0, byte_size(rest) - 1), []),
      else: {:error, :invalid_quoted_path}
  end

  defp unquote_path(path), do: {:ok, path}

  defp quoted_bytes(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp quoted_bytes(<<92, a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
       do: quoted_bytes(rest, [<<(a - ?0) * 64 + (b - ?0) * 8 + c - ?0>> | acc])

  defp quoted_bytes(<<92, escaped, rest::binary>>, acc)
       when escaped in [34, 92, ?a, ?b, ?t, ?n, ?v, ?f, ?r] do
    byte =
      case escaped do
        ?a -> 7
        ?b -> 8
        ?t -> 9
        ?n -> 10
        ?v -> 11
        ?f -> 12
        ?r -> 13
        other -> other
      end

    quoted_bytes(rest, [<<byte>> | acc])
  end

  defp quoted_bytes(<<92, _rest::binary>>, _acc), do: {:error, :invalid_quoted_path}
  defp quoted_bytes(<<byte, rest::binary>>, acc), do: quoted_bytes(rest, [<<byte>> | acc])

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
