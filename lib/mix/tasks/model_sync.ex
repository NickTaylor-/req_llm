defmodule Mix.Tasks.ReqLlm.ModelSync do
  @shortdoc "Synchronize model data from models.dev API"

  @moduledoc """
  Simplified model synchronization task.

  This task fetches model data from models.dev API (which now includes cost data)
  and saves provider JSON files to the /priv directory.

  ## Usage

      # Sync models from models.dev
      mix req_llm.model_sync

      # Verbose output
      mix req_llm.model_sync --verbose

  ## Output Structure

      priv/models_dev/providers/
      ├── anthropic.json         # Anthropic models with cost data
      ├── openai.json            # OpenAI models with cost data
      ├── google.json            # Google models with cost data
      └── ...                    # All other providers
  """

  use Mix.Task

  require Logger

  @preferred_cli_env ["req_llm.model_sync": :dev]

  # API endpoint
  @models_dev_api "https://models.dev/api.json"

  # Directory structure
  @providers_dir "priv/models_dev"
  @patches_dir "priv/models_local"

  # Fields we don't need from models.dev that should be filtered out
  @unused_fields ~w[
    npm
    packageName
    license
    repository
    bugs
    homepage
    engines
    keywords
    exports
    dependencies
  ]

  @spec run([String.t()]) :: :ok
  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:req_llm)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          verbose: :boolean
        ]
      )

    verbose? = Keyword.get(opts, :verbose, false)

    if verbose?, do: IO.puts("Starting model synchronization...")

    case execute_sync(verbose?) do
      :ok ->
        IO.puts("Model synchronization completed successfully")
        :ok

      {:error, reason} ->
        IO.puts("Synchronization failed: #{reason}")
        System.halt(1)
    end
  end

  @doc """
  Execute the synchronization process.
  """
  @spec execute_sync(boolean()) :: :ok | {:error, term()}
  def execute_sync(verbose? \\ false) do
    File.mkdir_p!(@providers_dir)

    with {:ok, models_data} <- fetch_models_dev_data(verbose?) do
      merged_data = merge_local_patches(models_data, verbose?)
      save_provider_files(merged_data, verbose?)
    end
  end

  defp fetch_models_dev_data(verbose?) do
    if verbose?, do: IO.puts("Fetching models.dev catalog...")

    case Req.get(@models_dev_api) do
      {:ok, %{status: 200, body: data}} ->
        if verbose? do
          provider_count = map_size(data)
          model_count = count_total_models(data)

          IO.puts(
            "Downloaded models.dev data: #{provider_count} providers, #{model_count} models"
          )
        end

        {:ok, data}

      {:ok, %{status: status}} ->
        {:error,
         ReqLLM.Error.API.Response.exception(
           reason: "models.dev API returned status #{status}",
           status: status
         )}

      {:error, reason} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "Failed to fetch models.dev data: #{inspect(reason)}"
         )}
    end
  end

  defp save_provider_files(models_data, verbose?) do
    models_data
    |> Enum.each(fn {provider_id, provider_data} ->
      models = process_provider_models(provider_data["models"] || %{}, provider_id)

      if not Enum.empty?(models) do
        provider_file = Path.join(@providers_dir, "#{provider_id}.json")
        config = get_provider_config(provider_id)

        provider_json = %{
          "provider" => %{
            "id" => provider_id,
            "name" => provider_data["name"] || format_provider_name(provider_id),
            "base_url" => config["base_url"],
            "env" => config["env"] || [],
            "doc" => provider_data["description"] || "AI model provider"
          },
          "models" => prune_model_fields(models)
        }

        File.write!(provider_file, Jason.encode!(provider_json, pretty: true))

        if verbose? do
          IO.puts("  Saved #{length(models)} models for #{provider_id}")
        end
      end
    end)

    :ok
  end

  defp process_provider_models(models_map, provider_id) do
    models_map
    |> Enum.map(fn {_model_id, model_data} ->
      Map.merge(model_data, %{
        "provider" => provider_id,
        "provider_model_id" => model_data["id"]
      })
    end)
  end

  defp prune_model_fields(models) do
    models
    |> Enum.map(fn model ->
      Enum.reduce(@unused_fields, model, fn field, acc ->
        Map.delete(acc, field)
      end)
    end)
  end

  defp count_total_models(providers_data) do
    providers_data
    |> Enum.map(fn {_, provider} -> map_size(provider["models"] || %{}) end)
    |> Enum.sum()
  end

  defp format_provider_name(provider_id) do
    provider_id
    |> String.split(["-", "_"])
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Provider-specific configuration (missing from models.dev)
  # Simplified - no module attribute, inline function
  defp get_provider_config("openai") do
    %{
      "base_url" => "https://api.openai.com/v1",
      "env" => ["OPENAI_API_KEY"]
    }
  end

  defp get_provider_config("anthropic") do
    %{
      "base_url" => "https://api.anthropic.com/v1",
      "env" => ["ANTHROPIC_API_KEY"]
    }
  end

  defp get_provider_config("openrouter") do
    %{
      "base_url" => "https://openrouter.ai/api/v1",
      "env" => ["OPENROUTER_API_KEY"]
    }
  end

  defp get_provider_config("google") do
    %{
      "base_url" => "https://generativelanguage.googleapis.com/v1",
      "env" => ["GOOGLE_API_KEY"]
    }
  end

  defp get_provider_config("cloudflare") do
    %{
      "base_url" => "https://api.cloudflare.com/client/v4/accounts",
      "env" => ["CLOUDFLARE_API_KEY"]
    }
  end

  defp get_provider_config(_provider_id) do
    %{}
  end

  defp merge_local_patches(models_data, verbose?) do
    if File.exists?(@patches_dir) do
      patch_files = Path.wildcard(Path.join(@patches_dir, "*.json"))

      if verbose? && !Enum.empty?(patch_files) do
        IO.puts("Found #{length(patch_files)} patch files to merge")
      end

      Enum.reduce(patch_files, models_data, fn patch_file, acc ->
        case load_patch_file(patch_file, verbose?) do
          {:ok, provider_id, patch_data} ->
            merge_patch_data(acc, provider_id, patch_data, verbose?)

          {:error, _reason} ->
            acc
        end
      end)
    else
      if verbose? do
        IO.puts("No patches directory found (#{@patches_dir})")
      end

      models_data
    end
  end

  defp load_patch_file(patch_file, verbose?) do
    case File.read(patch_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"provider" => %{"id" => provider_id}, "models" => patch_models}} ->
            if verbose? do
              IO.puts(
                "  Loading patch: #{Path.basename(patch_file)} (#{length(patch_models)} models)"
              )
            end

            {:ok, provider_id, patch_models}

          {:ok, _} ->
            IO.puts("Warning: Invalid patch file structure: #{patch_file}")
            {:error, :invalid_structure}

          {:error, error} ->
            IO.puts("Warning: Failed to parse patch file #{patch_file}: #{inspect(error)}")
            {:error, :json_parse_error}
        end

      {:error, error} ->
        IO.puts("Warning: Failed to read patch file #{patch_file}: #{inspect(error)}")
        {:error, :file_read_error}
    end
  end

  defp merge_patch_data(models_data, provider_id, patch_models, verbose?) do
    case Map.get(models_data, provider_id) do
      nil ->
        if verbose? do
          IO.puts("    Skipping patch for unknown provider: #{provider_id}")
        end

        models_data

      provider_data ->
        existing_models = provider_data["models"] || %{}

        # Convert patch models list to map for easier merging
        patch_models_map =
          patch_models
          |> Map.new(fn model -> {model["id"], model} end)

        # Merge patch models into existing models (patches override)
        merged_models = Map.merge(existing_models, patch_models_map)

        if verbose? do
          added_count =
            map_size(patch_models_map) -
              map_size(Map.take(existing_models, Map.keys(patch_models_map)))

          updated_count = map_size(patch_models_map) - added_count

          IO.puts(
            "    Provider #{provider_id}: added #{added_count}, updated #{updated_count} models"
          )
        end

        updated_provider_data = Map.put(provider_data, "models", merged_models)
        Map.put(models_data, provider_id, updated_provider_data)
    end
  end
end
