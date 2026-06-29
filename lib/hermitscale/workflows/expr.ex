defmodule Hermitscale.Workflows.Expr do
  @moduledoc """
  Solid-backed workflow expression compilation and rendering.

  Expressions use Liquid delimiters (`{{ ... }}`) and n8n-style namespaces such
  as `$json`, `$node`, `$env`, and `$vars`. Solid does not allow `$` in variable
  identifiers, so expressions are normalized to plain Liquid identifiers only
  inside Liquid regions.
  """

  alias Hermitscale.Workflows.Expr.{Filters, Matcher}
  alias Solid.{AccessLiteral, AccessVariable, Context, Filter, Object, Template, Text, Variable}

  defmodule CompileError do
    @moduledoc false
    defexception [:message]
  end

  defmodule RenderError do
    @moduledoc false
    defexception [:message, :errors]
  end

  @type compiled ::
          {:literal, term()}
          | {:interp, Template.t()}
          | {:expr, [term()] | nil, Template.t()}
          | {:predicate, Template.t()}

  @safe_tags Solid.Tag.default_tags() |> Map.drop(["render"])
  @parse_opts [tags: @safe_tags]
  @render_opts [
    custom_filters: Filters,
    matcher_module: Matcher,
    strict_filters: true
  ]

  @doc """
  Compiles one value into a renderable expression representation.
  """
  @spec compile(term(), keyword()) :: {:ok, compiled()} | {:error, CompileError.t()}
  def compile(value, opts \\ [])
  def compile(value, _opts) when not is_binary(value), do: {:ok, {:literal, value}}

  def compile(value, opts) do
    if expression?(value) do
      compile_expression(value, opts)
    else
      {:ok, {:literal, value}}
    end
  end

  @doc """
  Compiles every string leaf in a nested value.
  """
  @spec compile_tree(term(), keyword()) :: {:ok, term()} | {:error, CompileError.t()}
  def compile_tree(value, opts \\ [])

  def compile_tree(value, opts) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, leaf}, {:ok, acc} ->
      case compile_tree(leaf, opts) do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, key, compiled)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def compile_tree(value, opts) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn leaf, {:ok, acc} ->
      case compile_tree(leaf, opts) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  def compile_tree(value, opts), do: compile(value, opts)

  @doc """
  Compiles one value or raises.
  """
  @spec compile!(term(), keyword()) :: compiled()
  def compile!(value, opts \\ []) do
    case compile(value, opts) do
      {:ok, compiled} -> compiled
      {:error, error} -> raise error
    end
  end

  @doc """
  Resolves a compiled value, or a nested structure containing compiled values.
  """
  @spec resolve(term(), map()) :: {:ok, term()} | {:error, RenderError.t()}
  def resolve(value, context) when is_map(context) do
    {:ok, do_resolve(value, context)}
  rescue
    error in RenderError -> {:error, error}
    error in Solid.RenderError -> {:error, render_error(error.errors)}
  end

  @doc """
  Resolves a compiled value or raises.
  """
  @spec resolve!(term(), map()) :: term()
  def resolve!(value, context) do
    case resolve(value, context) do
      {:ok, resolved} -> resolved
      {:error, error} -> raise error
    end
  end

  @doc """
  Compiles and resolves one expression string against a sample context.
  """
  @spec preview(binary(), map()) :: {:ok, term()} | {:error, Exception.t()}
  def preview(source, context) when is_binary(source) and is_map(context) do
    with {:ok, compiled} <- compile(source),
         {:ok, resolved} <- resolve(compiled, context) do
      {:ok, resolved}
    end
  end

  @doc """
  Builds Solid bindings from a workflow envelope and run-scoped expression data.
  """
  @spec build_context(map(), map()) :: map()
  def build_context(envelope, runtime \\ %{}) do
    now = DateTime.utc_now(:second)

    %{
      "binary" => envelope_value(envelope, "binary", nil),
      "env" => runtime_value(runtime, :env, %{}),
      "execution" => runtime_value(runtime, :execution, %{}),
      "item" => json(envelope),
      "itemIndex" => envelope_value(envelope, "itemIndex", nil),
      "json" => json(envelope),
      "node" => node_outputs(envelope),
      "now" => DateTime.to_iso8601(now),
      "today" => now |> DateTime.to_date() |> Date.to_iso8601(),
      "vars" => runtime_value(runtime, :vars, %{}),
      "workflow" => runtime_value(runtime, :workflow, %{})
    }
  end

  @doc """
  Ensures a raw fact has the expression envelope shape.
  """
  @spec ensure_envelope(term()) :: map()
  def ensure_envelope(%{"json" => _json, "node" => node} = envelope) when is_map(node) do
    envelope
  end

  def ensure_envelope(value), do: %{"json" => value, "node" => %{}}

  @doc """
  Returns the current JSON payload from an envelope or raw value.
  """
  @spec json(term()) :: term()
  def json(%{"json" => value, "node" => node}) when is_map(node), do: value
  def json(value), do: value

  @doc """
  Builds a node's transient expression view (`$json` payload and `$node` map)
  from the actual Runic inputs it received.

  Facts flow as bare values; this reconstructs the local view used to resolve
  expressions. `joined?` is true when the node has 2+ parents and therefore
  receives an ordered list of parent values (a Runic join), false when it
  receives a single parent value (or the workflow input) directly. `main_count`
  is the number of structural (non-reference) parents; their values form `$json`
  (a single value for one main, a list for a multi-input join).
  """
  @spec node_view(term(), [String.t()], non_neg_integer(), boolean()) :: {term(), map()}
  def node_view(values, parents, main_count, true) when is_list(values) do
    node_map =
      parents
      |> Enum.zip(values)
      |> Map.new(fn {id, value} -> {id, %{"json" => value}} end)

    main =
      case Enum.take(values, main_count) do
        [single] -> single
        mains -> mains
      end

    {main, node_map}
  end

  def node_view(value, parents, _main_count, false) do
    node_map =
      case parents do
        [parent] -> %{parent => %{"json" => value}}
        _other -> %{}
      end

    {value, node_map}
  end

  @doc """
  Extracts static `$node["id"]` dependencies from compiled params.
  """
  @spec node_references(term()) :: [String.t()]
  def node_references(value) do
    value
    |> collect_node_references(MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc false
  def normalize(source) when is_binary(source), do: normalize(source, [])

  defp compile_expression(source, opts) do
    normalized = normalize(source)

    with {:ok, template} <- parse_template(normalized),
         :ok <- validate_filters(template) do
      compiled =
        case lone_object(template) do
          {:ok, object} ->
            if Keyword.get(opts, :predicate, false) do
              {:predicate, template}
            else
              {:expr, fast_path(object), template}
            end

          :error ->
            {:interp, template}
        end

      {:ok, compiled}
    end
  end

  defp parse_template(source) do
    case Solid.parse(source, @parse_opts) do
      {:ok, template} -> {:ok, template}
      {:error, error} -> {:error, compile_error(Exception.message(error))}
    end
  end

  defp expression?(source), do: String.contains?(source, "{{") or String.contains?(source, "{%")

  defp do_resolve({:literal, value}, _context), do: value

  defp do_resolve({:interp, template}, context) do
    case Solid.render(template, context, @render_opts) do
      {:ok, rendered, _errors} -> IO.iodata_to_binary(rendered)
      {:error, errors, _partial} -> raise render_error(errors)
    end
  end

  defp do_resolve({:expr, nil, template}, context), do: render_object_value!(template, context)

  defp do_resolve({:expr, path, _template}, context) do
    case fetch_path(context, path) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp do_resolve({:predicate, template}, context) do
    template
    |> render_object_value!(context)
    |> truthy?()
  end

  defp do_resolve(value, context) when is_map(value) do
    Map.new(value, fn {key, leaf} -> {key, do_resolve(leaf, context)} end)
  end

  defp do_resolve(value, context) when is_list(value) do
    Enum.map(value, &do_resolve(&1, context))
  end

  defp do_resolve(value, _context), do: value

  defp render_object_value!(template, bindings) do
    {:ok, object} = lone_object(template)

    context = %Context{
      matcher_module: Matcher,
      tags: @safe_tags,
      vars: bindings
    }

    {:ok, value, context} =
      Solid.Argument.get(object.argument, context, object.filters, @render_opts)

    case context.errors do
      [] -> value
      errors -> raise render_error(Enum.reverse(errors))
    end
  end

  defp lone_object(%Template{parsed_template: parts}) do
    parts
    |> Enum.reject(&blank_text?/1)
    |> case do
      [%Object{} = object] -> {:ok, object}
      _other -> :error
    end
  end

  defp blank_text?(%Text{text: text}), do: String.trim(text) == ""
  defp blank_text?(_part), do: false

  defp fast_path(%Object{argument: %Variable{} = variable, filters: []}) do
    with {:ok, accesses} <- literal_access_path(variable.accesses) do
      [variable.identifier | accesses]
    end
  end

  defp fast_path(_object), do: nil

  defp literal_access_path(accesses) do
    Enum.reduce_while(accesses, {:ok, []}, fn
      %AccessLiteral{value: value}, {:ok, path} ->
        {:cont, {:ok, [value | path]}}

      %AccessVariable{}, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, path} -> {:ok, Enum.reverse(path)}
      :error -> :error
    end
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [key | rest]) do
    case Matcher.match(value, [key]) do
      {:ok, next} -> fetch_path(next, rest)
      {:error, :not_found} -> :error
    end
  end

  defp validate_filters(template) do
    template
    |> collect_filters([])
    |> Enum.reduce_while(:ok, fn filter, :ok ->
      case validate_filter(filter) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_filter(%Filter{function: name} = filter) do
    arity = filter_arity(filter)

    cond do
      not Filters.allowed_filter?(name) ->
        {:error, compile_error("unknown expression filter #{inspect(name)}")}

      not Filters.valid_arity?(name, arity) ->
        {:error, compile_error("invalid arity #{arity} for expression filter #{inspect(name)}")}

      true ->
        :ok
    end
  end

  defp filter_arity(%Filter{positional_arguments: args, named_arguments: named_args}) do
    1 + length(args) + named_args_arity(named_args)
  end

  defp named_args_arity(named_args) when map_size(named_args) == 0, do: 0
  defp named_args_arity(_named_args), do: 1

  defp collect_filters(%Template{parsed_template: parts}, acc), do: collect_filters(parts, acc)

  defp collect_filters(%Object{argument: argument, filters: filters}, acc) do
    acc = Enum.reduce(filters, acc, &collect_filters/2)
    collect_filters(argument, acc)
  end

  defp collect_filters(%Filter{} = filter, acc) do
    acc
    |> then(&collect_filters(filter.positional_arguments, &1))
    |> then(&collect_filters(Map.values(filter.named_arguments), &1))
    |> then(&[filter | &1])
  end

  defp collect_filters(%Variable{accesses: accesses}, acc), do: collect_filters(accesses, acc)

  defp collect_filters(%AccessVariable{variable: variable}, acc),
    do: collect_filters(variable, acc)

  defp collect_filters(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_filters/2)

  defp collect_filters(map, acc) when is_map(map), do: map |> Map.values() |> collect_filters(acc)
  defp collect_filters(_value, acc), do: acc

  defp collect_node_references({:literal, _value}, acc), do: acc

  defp collect_node_references({:interp, template}, acc),
    do: collect_node_references(template, acc)

  defp collect_node_references({:expr, _path, template}, acc),
    do: collect_node_references(template, acc)

  defp collect_node_references({:predicate, template}, acc),
    do: collect_node_references(template, acc)

  defp collect_node_references(%Template{parsed_template: parts}, acc) do
    collect_node_references(parts, acc)
  end

  defp collect_node_references(%Object{argument: argument, filters: filters}, acc) do
    acc
    |> then(&collect_node_references(argument, &1))
    |> then(&collect_node_references(filters, &1))
  end

  defp collect_node_references(
         %Variable{identifier: "node", accesses: [%AccessLiteral{value: node_id} | accesses]},
         acc
       )
       when is_binary(node_id) do
    accesses
    |> collect_node_references(MapSet.put(acc, node_id))
  end

  defp collect_node_references(%Variable{accesses: accesses}, acc) do
    collect_node_references(accesses, acc)
  end

  defp collect_node_references(%AccessVariable{variable: variable}, acc) do
    collect_node_references(variable, acc)
  end

  defp collect_node_references(%Filter{} = filter, acc) do
    acc
    |> then(&collect_node_references(filter.positional_arguments, &1))
    |> then(&collect_node_references(Map.values(filter.named_arguments), &1))
  end

  defp collect_node_references(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_node_references/2)
  end

  defp collect_node_references(map, acc) when is_map(map) do
    map
    |> Map.values()
    |> collect_node_references(acc)
  end

  defp collect_node_references(_value, acc), do: acc

  defp normalize("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp normalize(<<"{{", rest::binary>>, acc) do
    normalize_liquid_region(rest, ["{{" | acc], "}}")
  end

  defp normalize(<<"{%", rest::binary>>, acc) do
    normalize_liquid_region(rest, ["{%" | acc], "%}")
  end

  defp normalize(<<char::utf8, rest::binary>>, acc), do: normalize(rest, [<<char::utf8>> | acc])

  defp normalize_liquid_region(rest, acc, closing) do
    case :binary.match(rest, closing) do
      {index, length} ->
        body = binary_part(rest, 0, index)
        tail = binary_part(rest, index + length, byte_size(rest) - index - length)

        normalize(tail, [closing, rewrite_dollar_idents(body) | acc])

      :nomatch ->
        [rewrite_dollar_idents(rest) | acc]
        |> Enum.reverse()
        |> IO.iodata_to_binary()
    end
  end

  defp rewrite_dollar_idents(body) do
    Regex.replace(~r/\$([A-Za-z_][A-Za-z0-9_]*)/, body, "\\1")
  end

  defp node_outputs(%{"node" => node}) when is_map(node), do: node
  defp node_outputs(_envelope), do: %{}

  defp envelope_value(envelope, key, default) do
    Map.get(envelope, key) || Map.get(envelope, atom_key(key)) || default
  end

  defp runtime_value(runtime, key, default) do
    Map.get(runtime, key) || Map.get(runtime, Atom.to_string(key)) || default
  end

  defp atom_key("binary"), do: :binary
  defp atom_key("itemIndex"), do: :item_index

  defp truthy?(value) when value in [nil, false, ""], do: false
  defp truthy?([]), do: false
  defp truthy?(%{} = value), do: map_size(value) > 0
  defp truthy?(_value), do: true

  defp compile_error(message), do: %CompileError{message: message}

  defp render_error(errors) do
    message =
      errors
      |> Enum.map(&Exception.message/1)
      |> Enum.join("\n")

    %RenderError{message: message, errors: errors}
  end
end
