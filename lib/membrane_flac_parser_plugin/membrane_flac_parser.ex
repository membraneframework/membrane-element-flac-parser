defmodule Membrane.FLACParser do
  @moduledoc """
  An element parsing FLAC encoded audio stream.

  Wraps `Membrane.FLACParser.Parser`, see its docs for more info.
  """
  use Membrane.Filter
  alias Membrane.Caps.Audio.FLAC
  alias Membrane.Buffer
  alias Membrane.FLACParser.Parser

  @initial_demand 1024

  def_output_pad :output,
    caps: FLAC

  def_input_pad :input,
    caps: :any,
    demand_unit: :bytes

  def_options streaming?: [
                description: """
                This option set to `true` allows parser to accept FLAC stream,
                e.g. only frames without header
                """,
                default: false,
                type: :boolean
              ]

  @impl true
  def handle_init(opts) do
    {:ok, opts |> Map.from_struct() |> Map.merge(%{parser: nil})}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, %{streaming?: streaming?} = state) do
    state = %{state | parser: Parser.init(streaming?)}
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    state = %{state | parser: nil}
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, %{parser: parser} = state) do
    with {:ok, results, parser} <- Parser.parse(payload, parser) do
      actions =
        results
        |> Enum.map(fn
          %FLAC{} = caps -> {:caps, {:output, caps}}
          %Buffer{} = buf -> {:buffer, {:output, buf}}
        end)

      {{:ok, actions ++ [redemand: :output]}, %{state | parser: parser}}
    else
      {:error, reason} -> raise "Parsing error: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_demand(:output, size, :bytes, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  def handle_demand(:output, size, :buffers, ctx, state) do
    caps = ctx.pads.output.caps

    demand =
      if caps != nil and caps.max_frame_size != nil do
        caps.max_frame_size * size
      else
        @initial_demand * size
      end

    {{:ok, demand: {:input, demand}}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {:ok, buffer} = Parser.flush(state.parser)

    actions = [
      buffer: {:output, buffer},
      end_of_stream: :output,
      notify: {:end_of_stream, :input}
    ]

    {{:ok, actions}, state}
  end
end
