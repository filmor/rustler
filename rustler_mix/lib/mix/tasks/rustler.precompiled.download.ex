defmodule Mix.Tasks.Rustler.Precompiled.Download do
  @shortdoc "Download precompiled NIF artifacts for a given module"

  @moduledoc """
  Downloads all precompiled NIF artifacts for a module that uses `Rustler.Precompiled`.

  ## Usage

      mix rustler.precompiled.download MODULE [--all] [--only-local] [--ignore-unavailable]

  * `MODULE` - The Elixir module that `use Rustler.Precompiled` (e.g. `MyApp.MyNIF`).

  ## Options

    * `--all` - Download NIF artifacts for all configured targets (default).

    * `--only-local` - Download only the NIF for the current machine's target.

    * `--ignore-unavailable` - Skip artifacts that cannot be downloaded instead of raising.

  After downloading, the task writes a `checksum-<MODULE>.exs` file in the project root.
  This file maps each artifact filename to its SHA-256 checksum and **must** be committed
  to source control so that end-users can verify integrity at install time.

  ## Example

      mix rustler.precompiled.download MyApp.MyNIF --all

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [all: :boolean, only_local: :boolean, ignore_unavailable: :boolean]
      )

    module_name =
      case positional do
        [name | _] -> name
        [] -> Mix.raise("Expected a module name. Usage: mix rustler.precompiled.download MODULE")
      end

    nif_module = Module.concat([module_name])

    Mix.Task.run("compile")

    nifs_with_urls =
      if opts[:only_local] do
        Rustler.Precompiled.current_target_nifs(nif_module)
      else
        Rustler.Precompiled.available_nifs(nif_module)
      end

    if nifs_with_urls == [] do
      Mix.shell().info("No NIF artifacts found for #{module_name}.")
    else
      Mix.shell().info("Downloading #{length(nifs_with_urls)} NIF artifact(s) for #{module_name}...")

      checksums =
        Rustler.Precompiled.download_nif_artifacts_with_checksums!(
          nifs_with_urls,
          ignore_unavailable: opts[:ignore_unavailable] || false
        )

      Rustler.Precompiled.write_checksum!(nif_module, checksums)

      checksum_file = Rustler.Precompiled.checksum_file(nif_module)
      Mix.shell().info("Wrote checksum file: #{checksum_file}")
      Mix.shell().info("Remember to commit this file to source control.")
    end
  end
end
