defmodule Rustler.Precompiled.Config do
  @moduledoc false

  # Internal struct representing validated configuration for precompiled NIF downloads.
  defstruct [
    :otp_app,
    :module,
    :base_url,
    :version,
    :crate,
    :base_cache_dir,
    :load_data,
    :force_build?,
    :targets,
    :nif_versions,
    variants: %{},
    max_retries: 3
  ]

  @default_targets ~w(
    aarch64-apple-darwin
    aarch64-unknown-linux-gnu
    aarch64-unknown-linux-musl
    arm-unknown-linux-gnueabihf
    riscv64gc-unknown-linux-gnu
    x86_64-apple-darwin
    x86_64-pc-windows-gnu
    x86_64-pc-windows-msvc
    x86_64-unknown-linux-gnu
    x86_64-unknown-linux-musl
  )

  @available_nif_versions ~w(2.14 2.15 2.16 2.17 2.18)
  @default_nif_versions ~w(2.15 2.16 2.17)

  def default_targets, do: @default_targets
  def available_nif_versions, do: @available_nif_versions
  def default_nif_versions, do: @default_nif_versions

  def new(opts) do
    otp_app = opts |> Keyword.fetch!(:otp_app) |> validate_otp_app!()
    crate = opts[:crate]

    version =
      case Keyword.fetch(opts, :version) do
        {:ok, v} ->
          v

        :error ->
          crate_path = opts[:path] || "native/#{crate || otp_app}"
          version_from_cargo_toml!(crate_path)
      end
      |> validate_version!()

    base_url = opts |> Keyword.fetch!(:base_url) |> validate_base_url!()

    targets =
      opts
      |> Keyword.get(:targets, @default_targets)
      |> validate_list!(:targets, @default_targets)

    nif_versions =
      opts
      |> Keyword.get(:nif_versions, @default_nif_versions)
      |> validate_list!(:nif_versions, @available_nif_versions)

    force_build =
      if Keyword.has_key?(opts, :force_build) do
        Keyword.fetch!(opts, :force_build)
      else
        pre_release?(version)
      end

    %__MODULE__{
      otp_app: otp_app,
      base_url: base_url,
      module: Keyword.fetch!(opts, :module),
      version: version,
      force_build?: force_build or pre_release?(version),
      crate: crate,
      load_data: Keyword.get(opts, :load_data, 0),
      base_cache_dir: opts[:base_cache_dir],
      targets: targets,
      nif_versions: nif_versions,
      variants: validate_variants!(targets, Keyword.get(opts, :variants, %{})),
      max_retries: validate_max_retries!(Keyword.get(opts, :max_retries, 3))
    }
  end

  @doc """
  Reads the crate version from a `Cargo.toml` file at `crate_path`.

  Requires the `toml` package to be available.
  """
  def version_from_cargo_toml!(crate_path) do
    cargo_toml = Path.join(crate_path, "Cargo.toml")

    unless File.exists?(cargo_toml) do
      raise "Cannot auto-detect version: #{cargo_toml} does not exist. " <>
              "Please provide `:version` explicitly in `use Rustler.Precompiled`."
    end

    unless Code.ensure_loaded?(Toml) do
      raise "The `toml` package is required to auto-detect the crate version from Cargo.toml. " <>
              "Add `{:toml, \"~> 0.7\"}` to your `mix.exs` dependencies, or provide " <>
              "`:version` explicitly in `use Rustler.Precompiled`."
    end

    cargo_toml
    |> File.read!()
    |> Toml.decode!()
    |> get_in(["package", "version"])
    |> case do
      nil ->
        raise "Could not find `[package].version` in #{cargo_toml}. " <>
                "Please provide `:version` explicitly in `use Rustler.Precompiled`."

      version ->
        version
    end
  end

  defp validate_version!(nil), do: raise_for_nil_field_value(:version)
  defp validate_version!(version) when is_binary(version), do: version

  defp validate_version!(other),
    do: raise("`:version` must be a string. Got: #{inspect(other)}")

  defp validate_otp_app!(nil), do: raise_for_nil_field_value(:otp_app)

  defp validate_otp_app!(otp_app) when is_atom(otp_app), do: otp_app

  defp validate_otp_app!(_),
    do: raise("`:otp_app` is required to be an atom for `Rustler.Precompiled`")

  defp validate_base_url!(nil), do: raise_for_nil_field_value(:base_url)

  defp validate_base_url!(base_url) when is_binary(base_url) do
    validate_base_url!({base_url, []})
  end

  defp validate_base_url!({base_url, headers}) when is_binary(base_url) and is_list(headers) do
    case :uri_string.parse(base_url) do
      %{} ->
        if Enum.all?(headers, &match?({k, v} when is_binary(k) and is_binary(v), &1)) do
          {base_url, headers}
        else
          raise "`:base_url` headers for `Rustler.Precompiled` must be a list of `{binary(), binary()}`"
        end

      {:error, :invalid_uri, error} ->
        raise "`:base_url` for `Rustler.Precompiled` is invalid: #{inspect(to_string(error))}"
    end
  end

  defp validate_base_url!({module, function}) when is_atom(module) and is_atom(function) do
    Code.ensure_compiled!(module)

    if Kernel.function_exported?(module, function, 1) do
      {module, function}
    else
      raise "`:base_url` for `Rustler.Precompiled` references a function that does not exist: " <>
              "`#{inspect(module)}.#{function}/1`"
    end
  end

  defp validate_list!(nil, field, _valid), do: raise_for_nil_field_value(field)

  defp validate_list!([_ | _] = values, field, valid) do
    uniq = Enum.uniq(values)

    case uniq -- valid do
      [] ->
        uniq

      invalid ->
        raise """
        `:#{field}` contains values that are not supported:

        #{inspect(invalid, pretty: true)}
        """
    end
  end

  defp validate_list!(_values, field, _valid),
    do: raise("`:#{field}` must be a non-empty list")

  defp validate_max_retries!(n) when n in 0..15, do: n

  defp validate_max_retries!(other),
    do: raise("`:max_retries` must be an integer between 0 and 15. Got: #{inspect(other)}")

  defp raise_for_nil_field_value(field),
    do: raise("`#{inspect(field)}` is required for `Rustler.Precompiled`")

  defp pre_release?(version) do
    case Version.parse(version) do
      {:ok, parsed} -> parsed.pre != []
      :error -> false
    end
  end

  defp validate_variants!(_targets, nil), do: %{}

  defp validate_variants!(targets, variants) when is_map(variants) do
    for target <- Map.keys(variants) do
      if target not in targets do
        raise "`:variants` contains a target not in the list of valid targets: #{inspect(target)}"
      end

      for {name, fun} <- Map.fetch!(variants, target) do
        unless is_atom(name) do
          raise "`:variants` expects keyword list keys to be atoms, got: #{inspect(name)}"
        end

        unless is_function(fun, 0) or is_function(fun, 1) do
          raise "`:variants` values must be arity-0 or arity-1 functions"
        end
      end
    end

    variants
  end
end
