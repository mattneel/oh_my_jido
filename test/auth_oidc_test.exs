defmodule OhMyJido.Auth.OIDCTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Auth.{Error, OIDC}

  @issuer "https://auth.openai.com"
  @client "oaiapp_local_test"
  @now 1_800_000_000

  setup_all do
    {[exponent, modulus], private} = :crypto.generate_key(:rsa, {2048, 65_537})

    jwk = %{
      "kty" => "RSA",
      "kid" => "fixture-rsa",
      "alg" => "RS256",
      "use" => "sig",
      "key_ops" => ["verify"],
      "n" => Base.url_encode64(modulus, padding: false),
      "e" => Base.url_encode64(exponent, padding: false)
    }

    %{private: private, jwks: %{"keys" => [jwk]}}
  end

  test "verifies an RSA signature before returning identity claims", fixture do
    token = token(fixture.private, claims())
    assert {:ok, verified} = OIDC.verify(token, fixture.jwks, expectations())
    assert verified["sub"] == "verified-account"
    assert verified["aud"] == @client
  end

  test "rejects forged signatures, unsecured JWTs and algorithm confusion", fixture do
    valid = token(fixture.private, claims())
    [header, payload, signature] = String.split(valid, ".")
    forged_payload = encode(Map.put(claims(), "sub", "forged-account"))

    assert {:error, %Error{code: :oidc_signature_invalid}} =
             OIDC.verify(
               Enum.join([header, forged_payload, signature], "."),
               fixture.jwks,
               expectations()
             )

    for algorithm <- ["none", "HS256", "PS256"] do
      unsupported =
        Enum.join(
          [encode(%{"alg" => algorithm, "kid" => "fixture-rsa"}), payload, signature],
          "."
        )

      assert {:error, %Error{code: :oidc_algorithm_unsupported}} =
               OIDC.verify(unsupported, fixture.jwks, expectations())
    end
  end

  test "validates issuer, audience, nonce, expiry and required issued-at claim", fixture do
    for {changes, code} <- [
          {%{"iss" => "https://attacker.invalid"}, :oidc_issuer_mismatch},
          {%{"aud" => "another-client"}, :oidc_audience_mismatch},
          {%{"nonce" => "another-attempt"}, :oidc_nonce_mismatch},
          {%{"exp" => @now - 10, "iat" => @now - 600}, :oidc_token_expired},
          {%{"iat" => @now + 30}, :oidc_claims_invalid},
          {%{"nbf" => @now + 30}, :oidc_claims_invalid},
          {%{"sub" => ""}, :oidc_claims_invalid}
        ] do
      jwt = token(fixture.private, Map.merge(claims(), changes))
      assert {:error, %Error{code: ^code}} = OIDC.verify(jwt, fixture.jwks, expectations())
    end

    jwt = token(fixture.private, Map.delete(claims(), "iat"))

    assert {:error, %Error{code: :oidc_claims_invalid}} =
             OIDC.verify(jwt, fixture.jwks, expectations())
  end

  test "multi-audience tokens require matching authorized party and returning subject", fixture do
    values = Map.merge(claims(), %{"aud" => [@client, "other"], "azp" => @client})
    assert {:ok, _} = OIDC.verify(token(fixture.private, values), fixture.jwks, expectations())

    for bad <- [Map.delete(values, "azp"), Map.put(values, "azp", "other")] do
      assert {:error, %Error{code: :oidc_audience_mismatch}} =
               OIDC.verify(token(fixture.private, bad), fixture.jwks, expectations())
    end

    assert {:error, %Error{code: :oidc_subject_mismatch}} =
             OIDC.verify(
               token(fixture.private, claims()),
               fixture.jwks,
               Keyword.put(expectations(), :subject, "another-account")
             )
  end

  test "rejects ambiguous or non-signing keys and malformed JWT input", fixture do
    [jwk] = fixture.jwks["keys"]
    jwt = token(fixture.private, claims())

    for jwks <- [
          %{"keys" => [jwk, jwk]},
          %{"keys" => [Map.put(jwk, "use", "enc")]},
          %{"keys" => [Map.put(jwk, "key_ops", ["encrypt"])]},
          %{"keys" => [Map.put(jwk, "kid", "other-key")]}
        ] do
      assert {:error, %Error{code: :oidc_key_invalid}} = OIDC.verify(jwt, jwks, expectations())
    end

    for malformed <- ["", "not.a.jwt", "a.b.c.d", jwt <> "=", nil] do
      assert {:error, %Error{}} = OIDC.verify(malformed, fixture.jwks, expectations())
    end
  end

  test "discovery never accepts an alternate issuer or credential endpoint" do
    for mutation <- [
          %{"issuer" => "https://attacker.invalid"},
          %{"token_endpoint" => "https://attacker.invalid/token"},
          %{"jwks_uri" => "http://auth.openai.com/keys"},
          %{"revocation_endpoint" => "https://auth.openai.com@attacker.invalid/revoke"},
          %{"id_token_signing_alg_values_supported" => ["HS256"]}
        ] do
      plug = fn conn ->
        Req.Test.json(conn, Map.merge(discovery(), mutation))
      end

      assert {:error, %Error{}} = OIDC.discover(req_options: [plug: plug])
    end
  end

  defp claims do
    %{
      "iss" => @issuer,
      "aud" => @client,
      "sub" => "verified-account",
      "iat" => @now - 10,
      "exp" => @now + 600,
      "nonce" => "attempt-nonce"
    }
  end

  defp expectations, do: [issuer: @issuer, client_id: @client, nonce: "attempt-nonce", now: @now]

  defp token(private, claims) do
    signed =
      encode(%{"alg" => "RS256", "kid" => "fixture-rsa", "typ" => "JWT"}) <> "." <> encode(claims)

    signature = :crypto.sign(:rsa, :sha256, signed, private, rsa_padding: :rsa_pkcs1_padding)
    signed <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp discovery do
    %{
      "issuer" => @issuer,
      "authorization_endpoint" => @issuer <> "/api/accounts/authorize",
      "token_endpoint" => @issuer <> "/api/accounts/oauth/token",
      "jwks_uri" => @issuer <> "/.well-known/jwks.json",
      "revocation_endpoint" => @issuer <> "/oauth/revoke",
      "id_token_signing_alg_values_supported" => ["RS256"]
    }
  end
end
