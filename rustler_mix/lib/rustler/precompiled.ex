defmodule Rustler.Precompiled do
  @moduledoc """
  Download and use precompiled NIFs safely with checksums.

  `Rustler.Precompiled` is a tool for library maintainers that rely on Rustler.
  It helps by removing the need to have the Rust compiler installed in the user's
  machine.

  ## Example

      defmodule MyApp.MyNative do
        use Rustler.Precompiled,
          otp_app: :my_app,
          crate: "my_app_nif",
          base_url: "https://github.com/me/my_project/releases/download/v0.1.0",
          version: "0.1.0"
      end

  ## Options

    * `:otp_app` - The OTP app name that the dynamic library will be loaded from.

    * `:crate` - The name of the Rust crate if different from the `:otp_app`. Optional.

    * `:base_url` - Location where to find the NIFs. Can be:
        - A URL string pointing to a directory of NIFs.
        - A `{URL, headers}` tuple for authenticated sources.
        - A `{module, function}` tuple for dynamic URL resolution (arity 1).

    * `:version` - The version string for the precompiled assets (part of the NIF filename).

    * `:force_build` - Force compilation with Rustler instead of downloading. Defaults to
      `false` unless the version is a pre-release (e.g. `"1.0.0-dev"`).

      You can also set this per OTP app:

          config :rustler_precompiled, :force_build, my_otp_app: true

    * `:targets` - A list of Rust target triples for which precompiled assets are available.
      Defaults to a common set of platforms.

    * `:nif_versions` - A list of NIF versions to support. Defaults to `~w(2.15 2.16 2.17)`.

    * `:max_retries` - Maximum number of download retries. Defaults to `3`.

    * `:variants` - A map of target-triple to keyword list of `{name, fn}` pairs for
      selecting alternative builds of a target (e.g. old glibc).

    * `:load_data` - Term passed to the NIF on load. Defaults to `0`.

  Any options not consumed by `Rustler.Precompiled` are forwarded to `Rustler` when a
  force-build is triggered.

  ## Environment variables

    * `RUSTLER_PRECOMPILED_FORCE_BUILD_ALL` - Set to `"1"` or `"true"` to force all
      packages to build from source.

    * `RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH` - Override the directory used to cache
      downloaded NIF tarballs.

    * `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` - Proxy settings for downloads.

    * `HEX_CACERTS_PATH` - Path to a CA certificates file.

    * `TARGET_ARCH`, `TARGET_ABI`, `TARGET_OS`, `TARGET_VENDOR` - Override the detected
      Rust target triple (useful for cross-compilation with Nerves).

  """

  require Logger

  alias Rustler.Precompiled.Config

  @checksum_algo :sha256
  @native_dir "priv/native"

  # ---------------------------------------------------------------------------
  # Macro entry point
  # ---------------------------------------------------------------------------

  defmacro __using__(opts) do
    force =
      if Code.ensure_loaded?(Rustler) do
        quote do
          use Rustler, only_rustler_opts
        end
      else
        quote do
          raise "Rustler is needed to force a build. " <>
                  "Add `{:rustler, \">= 0.0.0\", optional: true}` to your `mix.exs`."
        end
      end

    quote do
      require Logger

      opts = unquote(opts)

      otp_app = Keyword.fetch!(opts, :otp_app)

      opts =
        if Application.compile_env(
             :rustler_precompiled,
             :force_build_all,
             System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL") in ["1", "true"]
           ) do
          Keyword.put(opts, :force_build, true)
        else
          Keyword.put_new(
            opts,
            :force_build,
            Application.compile_env(:rustler_precompiled, [:force_build, otp_app])
          )
        end

      case Rustler.Precompiled.__using__(__MODULE__, opts) do
        {:force_build, only_rustler_opts} ->
          unquote(force)

        {:ok, config} ->
          @on_load :load_rustler_precompiled
          @rustler_precompiled_load_from config.load_from
          @rustler_precompiled_load_data config.load_data

          @doc false
          def load_rustler_precompiled do
            :code.purge(__MODULE__)
            {otp_app, path} = @rustler_precompiled_load_from

            load_path =
              otp_app
              |> Application.app_dir(path)
              |> to_charlist()

            :erlang.load_nif(load_path, @rustler_precompiled_load_data)
          end

        {:error, precomp_error} ->
          raise precomp_error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Public API used from the macro (and by Mix tasks)
  # ---------------------------------------------------------------------------

  @doc false
  def __using__(module, opts) do
    config =
      opts
      |> Keyword.put_new(:module, module)
      |> Config.new()

    case build_metadata(config) do
      {:ok, metadata} ->
        with {:error, reason} <- write_metadata(module, metadata) do
          Logger.warning(
            "Cannot write metadata file for #{inspect(module)}: #{inspect(reason)}. " <>
              "Mix tasks for publishing may not work correctly."
          )
        end

        if config.force_build? do
          rustler_opts =
            Keyword.drop(opts, [
              :base_url,
              :version,
              :force_build,
              :targets,
              :nif_versions,
              :max_retries,
              :variants
            ])

          {:force_build, rustler_opts}
        else
          case download_or_reuse_nif_file(config, metadata) do
            {:ok, result} ->
              {:ok, result}

            {:error, precomp_error} ->
              message = """
              Error while downloading precompiled NIF: #{precomp_error}.

              You can force the project to build from scratch with:

                  config :rustler_precompiled, :force_build, #{config.otp_app}: true

              In order to force the build, you also need to add Rustler as a dependency:

                  {:rustler, ">= 0.0.0", optional: true}
              """

              {:error, message}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the current Rust target string used for NIF lookup.

  The result has the form `"nif-NIF_VERSION-ARCH-VENDOR-OS[-ABI]"`.
  """
  def target(
        config \\ target_config(),
        available_targets \\ Config.default_targets(),
        available_nif_versions \\ Config.available_nif_versions()
      ) do
    arch_os =
      case config.os_type do
        {:unix, _} ->
          config.target_system
          |> normalize_arch_os()
          |> system_arch_to_string()

        {:win32, _} ->
          existing = system_arch_to_string(config.target_system)

          if existing in available_targets do
            existing
          else
            arch =
              case config.word_size do
                4 -> "i686"
                8 -> "x86_64"
                _ -> "unknown"
              end

            config.target_system
            |> Map.put_new(:arch, arch)
            |> Map.put_new(:vendor, "pc")
            |> Map.put_new(:os, "windows")
            |> Map.put_new(:abi, "msvc")
            |> system_arch_to_string()
          end
      end

    cond do
      arch_os not in available_targets ->
        {:error,
         "precompiled NIF is not available for this target: #{inspect(arch_os)}.\n" <>
           "The available targets are:\n - #{Enum.join(available_targets, "\n - ")}"}

      config.nif_version not in available_nif_versions ->
        {:error,
         "precompiled NIF is not available for NIF version: #{inspect(config.nif_version)}.\n" <>
           "The available NIF versions are:\n - #{Enum.join(available_nif_versions, "\n - ")}"}

      true ->
        {:ok, "nif-#{config.nif_version}-#{arch_os}"}
    end
  end

  @doc """
  Returns a list of `{lib_name, {url, headers}}` tuples for all targets configured in
  the metadata file written for `nif_module`.
  """
  def available_nifs(nif_module) when is_atom(nif_module) do
    nif_module
    |> metadata_file()
    |> read_map_from_file()
    |> nifs_from_metadata()
    |> case do
      {:ok, nifs} ->
        nifs

      {:error, meta} ->
        raise "metadata for #{inspect(nif_module)} is not available. " <>
                "Please recompile with: `mix compile --force`\n" <>
                "Metadata: #{inspect(meta, limit: :infinity, pretty: true)}"
    end
  end

  @doc """
  Returns a list of `{lib_name, {url, headers}}` tuples for the current target only.
  """
  def current_target_nifs(nif_module) when is_atom(nif_module) do
    metadata =
      nif_module
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{base_url: base_url, target: target} ->
        [nif_version, target_triple] = parts_from_nif_target(target)

        tar_gz_urls(
          base_url,
          metadata[:basename],
          metadata[:version],
          nif_version,
          target_triple,
          metadata[:variants]
        )

      _ ->
        raise "metadata about current target for #{inspect(nif_module)} is not available. " <>
                "Please recompile with: `mix compile --force`"
    end
  end

  @doc false
  def nifs_from_metadata(metadata) when is_map(metadata) do
    case metadata do
      %{
        targets: targets,
        base_url: base_url,
        basename: basename,
        nif_versions: nif_versions,
        version: version
      } ->
        all =
          for target_triple <- targets, nif_version <- nif_versions do
            tar_gz_urls(
              base_url,
              basename,
              version,
              nif_version,
              target_triple,
              metadata[:variants]
            )
          end

        {:ok, List.flatten(all)}

      wrong ->
        {:error, wrong}
    end
  end

  @doc false
  def build_metadata(%Config{} = config) do
    basic = %{
      base_url: config.base_url,
      crate: config.crate,
      otp_app: config.otp_app,
      targets: config.targets,
      variants: variants_for_metadata(config.variants),
      nif_versions: config.nif_versions,
      version: config.version
    }

    case target(target_config(config.nif_versions), config.targets, config.nif_versions) do
      {:ok, nif_target} ->
        basename = config.crate || to_string(config.otp_app)
        [nif_version, target_triple] = parts_from_nif_target(nif_target)

        lib_name =
          lib_name(basename, config.version, nif_version, target_triple) <>
            variant_suffix(target_triple, config)

        file_name = lib_name_with_ext(nif_target, lib_name)

        cache_dir = cache_dir(config.base_cache_dir, "precompiled_nifs")
        cached_tar_gz = Path.join(cache_dir, file_name)

        {:ok,
         Map.merge(basic, %{
           cached_tar_gz: cached_tar_gz,
           basename: basename,
           lib_name: lib_name,
           file_name: file_name,
           target: nif_target
         })}

      {:error, _} = error ->
        if config.force_build? do
          {:ok, basic}
        else
          error
        end
    end
  end

  @doc false
  def download_or_reuse_nif_file(%Config{} = config, metadata) when is_map(metadata) do
    name = config.otp_app

    native_dir = Application.app_dir(name, @native_dir)

    lib_name = Map.fetch!(metadata, :lib_name)
    cached_tar_gz = Map.fetch!(metadata, :cached_tar_gz)
    file_name = Map.fetch!(metadata, :file_name)
    lib_file = Path.join(native_dir, file_name)

    result = %{
      load?: true,
      load_from: {name, Path.join("priv/native", lib_name)},
      load_data: config.load_data
    }

    if File.exists?(cached_tar_gz) do
      File.rm(lib_file)

      with :ok <- check_file_integrity(cached_tar_gz, config.module),
           :ok <- :erl_tar.extract(cached_tar_gz, [:compressed, cwd: Path.dirname(lib_file)]) do
        Logger.debug("Extracted cached NIF to #{lib_file}")
        {:ok, result}
      end
    else
      tar_gz_url = tar_gz_file_url(config.base_url, lib_name_with_ext(cached_tar_gz, lib_name))

      with :ok <- File.mkdir_p(Path.dirname(cached_tar_gz)),
           :ok <- File.mkdir_p(Path.dirname(lib_file)),
           {:ok, tar_gz} <-
             with_retry(fn -> download_nif_artifact(tar_gz_url) end, config.max_retries),
           :ok <- File.write(cached_tar_gz, tar_gz),
           :ok <- check_file_integrity(cached_tar_gz, config.module),
           :ok <- :erl_tar.extract({:binary, tar_gz}, [:compressed, cwd: Path.dirname(lib_file)]) do
        Logger.debug("Downloaded NIF to #{cached_tar_gz} and extracted to #{lib_file}")
        {:ok, result}
      end
    end
  end

  @doc false
  def check_integrity_from_map(checksum_map, file_path, nif_module) do
    with {:ok, {algo, hash}} <- find_checksum(checksum_map, file_path, nif_module),
         :ok <- validate_checksum_algo(algo),
         do: compare_checksum(file_path, algo, hash)
  end

  @doc """
  Downloads all precompiled NIF artifacts for the given module and returns a list
  of `{lib_name, checksum_string}` entries suitable for writing to a checksum file.
  """
  def download_nif_artifacts_with_checksums!(nifs_with_urls, options \\ []) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)
    attempts = Keyword.get(options, :max_retries, 3)

    results =
      for {lib_name, url_spec} <- nifs_with_urls,
          do: {lib_name, with_retry(fn -> download_nif_artifact(url_spec) end, attempts)}

    cache_dir = cache_dir("precompiled_nifs")
    :ok = File.mkdir_p(cache_dir)

    Enum.flat_map(results, fn {lib_name, download_result} ->
      case download_result do
        {:ok, body} ->
          hash =
            @checksum_algo
            |> :crypto.hash(body)
            |> Base.encode16(case: :lower)

          cached = Path.join(cache_dir, lib_name)
          File.write!(cached, body)
          Logger.debug("Cached #{lib_name} to #{cached}")

          [{lib_name, "#{@checksum_algo}:#{hash}"}]

        {:error, reason} ->
          if ignore_unavailable? do
            Logger.warning("Could not download #{lib_name}: #{reason}")
            []
          else
            raise "Could not download #{lib_name}: #{reason}"
          end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Checksum file helpers
  # ---------------------------------------------------------------------------

  @doc false
  def checksum_file(nif_module) when is_atom(nif_module) do
    # Convention: checksum file lives next to mix.exs
    Path.join(File.cwd!(), "checksum-#{inspect(nif_module)}.exs")
  end

  @doc false
  def write_checksum!(nif_module, checksums) when is_list(checksums) do
    file = checksum_file(nif_module)
    pairs = Map.new(checksums)

    lines =
      pairs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> ~s(  #{inspect(k)} => #{inspect(v)}) end)
      |> Enum.join(",\n")

    File.write!(file, "%{\n#{lines}\n}\n")
  end

  # ---------------------------------------------------------------------------
  # Metadata file helpers
  # ---------------------------------------------------------------------------

  @doc false
  def metadata_file(nif_module) when is_atom(nif_module) do
    Path.join(priv_dir(), "precompiled_metadata_#{inspect(nif_module)}.exs")
  end

  defp write_metadata(nif_module, metadata) when is_map(metadata) do
    file = metadata_file(nif_module)

    case File.mkdir_p(Path.dirname(file)) do
      :ok ->
        File.write(file, inspect(metadata, limit: :infinity, pretty: true))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_map_from_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {map, _} = Code.eval_string(content)
        map

      _ ->
        %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Naming helpers
  # ---------------------------------------------------------------------------

  defp lib_prefix(target) do
    if String.contains?(target, "windows"), do: "", else: "lib"
  end

  defp lib_name(basename, version, nif_version, target_triple) do
    "#{lib_prefix(target_triple)}#{basename}-v#{version}-nif-#{nif_version}-#{target_triple}"
  end

  defp lib_name_with_ext(target, lib_name) do
    ext = if String.contains?(target, "windows"), do: "dll", else: "so"
    "#{lib_name}.#{ext}.tar.gz"
  end

  defp tar_gz_file_url({module, function_name}, file_name)
       when is_atom(module) and is_atom(function_name) do
    apply(module, function_name, [file_name])
  end

  defp tar_gz_file_url({base_url, headers}, file_name) when is_list(headers) do
    uri = URI.parse(base_url)
    uri = Map.update!(uri, :path, fn path -> Path.join(path || "", file_name) end)
    {to_string(uri), headers}
  end

  defp tar_gz_file_url(base_url, file_name) when is_binary(base_url) do
    tar_gz_file_url({base_url, []}, file_name)
  end

  defp tar_gz_urls(base_url, basename, version, nif_version, target_triple, variants) do
    lib = lib_name(basename, version, nif_version, target_triple)
    file = lib_name_with_ext(target_triple, lib)

    [
      {file, tar_gz_file_url(base_url, file)}
      | maybe_variants_tar_gz_urls(variants, base_url, target_triple, lib)
    ]
  end

  defp maybe_variants_tar_gz_urls(nil, _, _, _), do: []
  defp maybe_variants_tar_gz_urls(variants, _, target, _) when not is_map_key(variants, target), do: []

  defp maybe_variants_tar_gz_urls(variants, base_url, target_triple, lib_name) do
    for {variant, _fun} <- Map.fetch!(variants, target_triple) do
      vlib = lib_name_with_ext(target_triple, lib_name <> "--" <> Atom.to_string(variant))
      {vlib, tar_gz_file_url(base_url, vlib)}
    end
  end

  defp parts_from_nif_target(nif_target) do
    ["nif", nif_version, triple] = String.split(nif_target, "-", parts: 3)
    [nif_version, triple]
  end

  defp variants_for_metadata(variants) do
    Map.new(variants, fn {target, kw} -> {target, Keyword.keys(kw)} end)
  end

  defp variant_suffix(target, %Config{variants: variants}) when is_map_key(variants, target) do
    kw = Map.fetch!(variants, target)

    case Enum.find(kw, fn {_name, fun} ->
           if is_function(fun, 1), do: fun.(target), else: fun.()
         end) do
      {name, _} -> "--" <> Atom.to_string(name)
      nil -> ""
    end
  end

  defp variant_suffix(_, _), do: ""

  # ---------------------------------------------------------------------------
  # Checksum validation
  # ---------------------------------------------------------------------------

  defp check_file_integrity(file_path, nif_module) when is_atom(nif_module) do
    nif_module
    |> checksum_file()
    |> read_map_from_file()
    |> check_integrity_from_map(file_path, nif_module)
  end

  defp find_checksum(checksum_map, file_path, nif_module) do
    basename = Path.basename(file_path)

    case Map.fetch(checksum_map, basename) do
      {:ok, algo_with_hash} ->
        [algo, hash] = String.split(algo_with_hash, ":")
        {:ok, {String.to_existing_atom(algo), hash}}

      :error ->
        {:error,
         "#{basename} is not in the checksum file. " <>
           "Run `mix rustler.precompiled.download #{inspect(nif_module)} --only-local` to " <>
           "generate it."}
    end
  end

  defp validate_checksum_algo(algo) do
    if algo == @checksum_algo do
      :ok
    else
      {:error, "unsupported checksum algorithm: #{inspect(algo)}"}
    end
  end

  defp compare_checksum(file_path, algo, expected) do
    case File.read(file_path) do
      {:ok, content} ->
        actual =
          algo
          |> :crypto.hash(content)
          |> Base.encode16(case: :lower)

        if actual == expected do
          :ok
        else
          {:error, "checksum mismatch for #{Path.basename(file_path)}"}
        end

      {:error, reason} ->
        {:error, "cannot read #{file_path} for checksum: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP download
  # ---------------------------------------------------------------------------

  defp download_nif_artifact(url) when is_binary(url) do
    download_nif_artifact({url, []})
  end

  defp download_nif_artifact({url, headers}) do
    Logger.debug("Downloading NIF from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    no_proxy = parse_no_proxy(System.get_env("NO_PROXY") || System.get_env("no_proxy"))

    http_proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
    http_proxy_auth = configure_proxy(http_proxy, :proxy, "HTTP_PROXY", no_proxy)

    https_proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")
    https_proxy_auth = configure_proxy(https_proxy, :https_proxy, "HTTPS_PROXY", no_proxy)

    proxy_auth = https_proxy_auth || http_proxy_auth

    http_options =
      [
        ssl: [
          verify: :verify_peer,
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts_options()
      ]
      |> maybe_add_proxy_auth(proxy_auth)

    request_headers =
      Enum.map(headers, fn {k, v} when is_binary(k) -> {String.to_charlist(k), v} end)

    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, request_headers}, http_options, body_format: :binary) do
      {:ok, {{_, 200, _}, _resp_headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _resp_headers, _body}} ->
        {:error, "HTTP #{status} downloading NIF from #{url}"}

      {:error, reason} ->
        {:error, "could not download NIF from #{url}: #{inspect(reason)}"}
    end
  end

  defp with_retry(_fun, 0), do: {:error, "max retries exceeded"}

  defp with_retry(fun, attempts) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, _reason} when attempts > 1 ->
        with_retry(fun, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configure_proxy(proxy, type, env_name, no_proxy) when is_binary(proxy) do
    case URI.parse(proxy) do
      %{host: host, port: port, userinfo: userinfo} when is_binary(host) and is_integer(port) ->
        Logger.debug("Using #{env_name}: #{redact_userinfo(proxy)}")
        :httpc.set_options([{type, {{String.to_charlist(host), port}, no_proxy}}])
        parse_proxy_auth(userinfo)

      _ ->
        nil
    end
  end

  defp configure_proxy(_proxy, _type, _env_name, _no_proxy), do: nil

  @doc false
  def parse_no_proxy(nil), do: []
  def parse_no_proxy(""), do: []

  def parse_no_proxy(no_proxy) do
    no_proxy
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(".") |> String.to_charlist()))
    |> Enum.reject(&(&1 == ~c""))
  end

  @doc false
  def parse_proxy_auth(nil), do: nil
  def parse_proxy_auth(""), do: nil

  def parse_proxy_auth(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {String.to_charlist(user), String.to_charlist(pass)}
      [user] -> {String.to_charlist(user), ~c""}
    end
  end

  defp redact_userinfo(url) do
    uri = URI.parse(url)
    if uri.userinfo, do: %{uri | userinfo: "[REDACTED]"} |> to_string(), else: url
  end

  defp maybe_add_proxy_auth(opts, nil), do: opts
  defp maybe_add_proxy_auth(opts, auth), do: [{:proxy_auth, auth} | opts]

  defp cacerts_options do
    cond do
      path = System.get_env("HEX_CACERTS_PATH") ->
        [cacertfile: path]

      certs = otp_cacerts() ->
        [cacerts: certs]

      true ->
        warn_no_cacerts()
        []
    end
  end

  defp otp_cacerts do
    if System.otp_release() >= "25" do
      try do
        :public_key.cacerts_get()
      rescue
        _ -> nil
      end
    end
  end

  defp warn_no_cacerts do
    Logger.warning("""
    No certificate trust store was found.

    A certificate trust store is required in order to download precompiled NIF
    artifacts. One of the following actions may be taken:

    1. Set the path to a CA certificates file:

           export HEX_CACERTS_PATH="/path/to/cacerts.pem"

    2. Use OTP 25+ on an OS that has a built-in certificate trust store.
    """)
  end

  # ---------------------------------------------------------------------------
  # Target detection
  # ---------------------------------------------------------------------------

  defp target_config(available_nif_versions \\ Config.available_nif_versions()) do
    current_nif = :erlang.system_info(:nif_version) |> List.to_string()

    nif_version =
      case find_compatible_nif_version(current_nif, available_nif_versions) do
        {:ok, v} -> v
        :error -> current_nif
      end

    %{
      os_type: :os.type(),
      target_system: system_arch() |> maybe_override_with_env_vars(),
      word_size: :erlang.system_info(:wordsize),
      nif_version: nif_version
    }
  end

  @doc false
  def find_compatible_nif_version(vsn, available) do
    if vsn in available do
      {:ok, vsn}
    else
      [major, minor | _] = parse_version(vsn)

      available
      |> Enum.map(&parse_version/1)
      |> Enum.filter(fn
        [^major, av_minor | _] when av_minor <= minor -> true
        _ -> false
      end)
      |> case do
        [] -> :error
        matches -> {:ok, matches |> Enum.max() |> Enum.join(".")}
      end
    end
  end

  defp parse_version(vsn), do: vsn |> String.split(".") |> Enum.map(&String.to_integer/1)

  defp system_arch do
    base =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.split("-")

    keys =
      case length(base) do
        4 -> [:arch, :vendor, :os, :abi]
        3 -> [:arch, :vendor, :os]
        _ -> []
      end

    keys |> Enum.zip(base) |> Enum.into(%{})
  end

  @doc false
  def maybe_override_with_env_vars(sys_arch, get_env \\ &System.get_env/1) do
    env_keys = [arch: "TARGET_ARCH", vendor: "TARGET_VENDOR", os: "TARGET_OS", abi: "TARGET_ABI"]

    updated =
      Enum.reduce(env_keys, sys_arch, fn {key, env_key}, acc ->
        if value = get_env.(env_key), do: Map.put(acc, key, value), else: acc
      end)

    if sys_arch != updated and sys_arch.vendor == updated.vendor and
         updated.os == "linux" do
      Map.put(updated, :vendor, "unknown")
    else
      updated
    end
  end

  defp normalize_arch_os(sys) do
    cond do
      sys.os =~ "darwin" ->
        arch = with "arm" <- sys.arch, do: "aarch64"
        %{sys | arch: arch, os: "darwin"}

      sys.os =~ "linux" ->
        arch = normalize_arch(sys.arch)
        vendor = with v when v in ~w(pc redhat suse alpine) <- sys.vendor, do: "unknown"
        %{sys | arch: arch, vendor: vendor}

      sys.os =~ "freebsd" ->
        arch = normalize_arch(sys.arch)
        vendor = with "portbld" <- sys.vendor, do: "unknown"
        %{sys | arch: arch, vendor: vendor, os: "freebsd"}

      true ->
        sys
    end
  end

  defp normalize_arch("amd64"), do: "x86_64"
  defp normalize_arch("riscv64"), do: "riscv64gc"
  defp normalize_arch(arch), do: arch

  defp system_arch_to_string(sys) do
    [:arch, :vendor, :os, :abi]
    |> Enum.flat_map(fn key -> if v = sys[key], do: [v], else: [] end)
    |> Enum.join("-")
  end

  # ---------------------------------------------------------------------------
  # Cache directory
  # ---------------------------------------------------------------------------

  defp cache_dir(sub_dir) do
    global = System.get_env("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH")

    if global do
      Logger.info("Using global cache path: #{global}")
      global
    else
      opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
      :filename.basedir(:user_cache, Path.join("rustler_precompiled", sub_dir), opts)
    end
  end

  defp cache_dir(nil, sub_dir), do: cache_dir(sub_dir)
  defp cache_dir(basedir, sub_dir), do: Path.join(basedir, sub_dir)

  defp priv_dir, do: "priv"
end
