defmodule Mix.Tasks.Rustler.Precompiled.CheckIntegrity do
  @shortdoc "Verify the integrity of downloaded precompiled NIF artifacts"

  @moduledoc """
  Verifies checksums of downloaded precompiled NIF artifacts.

  ## Usage

      mix rustler.precompiled.check_integrity MODULE

  * `MODULE` - The Elixir module that `use Rustler.Precompiled`.

  The task reads the `checksum-<MODULE>.exs` file from the project root and verifies
  every entry against the corresponding cached artifact.

  Returns a non-zero exit code if any artifact fails verification.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {_opts, positional, _} = OptionParser.parse(args, switches: [])

    module_name =
      case positional do
        [name | _] ->
          name

        [] ->
          Mix.raise(
            "Expected a module name. Usage: mix rustler.precompiled.check_integrity MODULE"
          )
      end

    nif_module = Module.concat([module_name])

    Mix.Task.run("compile")

    checksum_file = Rustler.Precompiled.checksum_file(nif_module)

    if not File.exists?(checksum_file) do
      Mix.raise(
        "Checksum file not found: #{checksum_file}.\n" <>
          "Run `mix rustler.precompiled.download #{module_name}` first."
      )
    end

    {checksum_map, _} = Code.eval_file(checksum_file)

    results =
      for {filename, algo_hash} <- checksum_map do
        cache_dir_path =
          System.get_env("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH") ||
            :filename.basedir(
              :user_cache,
              Path.join("rustler_precompiled", "precompiled_nifs"),
              if(System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{})
            )

        file_path = Path.join(cache_dir_path, filename)

        result =
          Rustler.Precompiled.check_integrity_from_map(
            %{filename => algo_hash},
            file_path,
            nif_module
          )

        {filename, result}
      end

    failures = Enum.filter(results, fn {_file, res} -> res != :ok end)
    successes = Enum.filter(results, fn {_file, res} -> res == :ok end)

    for {file, :ok} <- successes do
      Mix.shell().info("  ✓ #{file}")
    end

    for {file, {:error, reason}} <- failures do
      Mix.shell().error("  ✗ #{file}: #{reason}")
    end

    if failures != [] do
      Mix.raise("#{length(failures)} artifact(s) failed integrity check.")
    else
      Mix.shell().info("All #{length(successes)} artifact(s) passed integrity check.")
    end
  end
end
