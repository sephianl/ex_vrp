defmodule ExVrp.Literature.Download do
  @moduledoc "HTTPS GET with certificate verification, through OTP's `:httpc`."

  @spec get(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def get(url) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    url
    |> String.to_charlist()
    |> then(&:httpc.request(:get, {&1, []}, [ssl: ssl_options(), timeout: 300_000], body_format: :binary))
    |> response_body(url)
  end

  defp response_body({:ok, {{_version, 200, _reason}, _headers, body}}, _url), do: {:ok, body}
  defp response_body({:ok, {{_version, status, _reason}, _headers, _body}}, url), do: {:error, "#{url}: HTTP #{status}"}
  defp response_body({:error, reason}, url), do: {:error, "#{url}: #{inspect(reason)}"}

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
