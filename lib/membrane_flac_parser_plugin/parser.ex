defmodule Membrane.FLACParser.Parser do
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  @moduledoc """
  Stateful parser based on FLAC format specification available [here](https://xiph.org/flac/format.html#stream)

  The parser outputs:
  1. `Membrane.Caps.Audio.FLAC`
  2. `Membrane.Buffer` with "fLaC" - the FLAC stream marker in ASCII
  3. At least one `Membrane.Buffer` with metadata block(s)
  4. `Membrane.Buffer`s containing one frame each, with decoded metadata from its header
     (as `Membrane.Caps.Audio.FLAC.FrameMetadata` struct)

  The parsing is done by calling `init/0` and than `parse/2` with the data to parse.
  The last buffer can be obtained by calling `flush/1`

  The parser returns a frame once it encounters a beginning of the next one since there's no other
  way to determine where the frame ends.
  """
  alias Membrane.{Buffer, Caps}
  alias Membrane.Caps.Audio.FLAC

  @frame_start <<0b111111111111100::15>>
  @frame_start_size byte_size(@frame_start)

  @blocking_stg_fixed 0
  @blocking_stg_variable 1

  @fixed_frame_start <<@frame_start::bitstring, @blocking_stg_fixed::1>>
  @variable_frame_start <<@frame_start::bitstring, @blocking_stg_variable::1>>

  @metadata_block_streaminfo 0
  @metadata_block_padding 1
  @metadata_block_application 2
  @metadata_block_seektable 3
  @metadata_block_vorbis_comment 4
  @metadata_block_cuesheet 5
  @metadata_block_picture 6

  @typedoc """
  Opaque struct containing state of the parser.
  """
  @opaque state() :: %__MODULE__{
            queue: binary(),
            continue: atom(),
            pos: non_neg_integer(),
            caps: %FLAC{} | nil,
            blocking_strategy: 0 | 1 | nil,
            current_metadata: FLAC.FrameMetadata.t() | nil
          }

  defstruct queue: "",
            continue: :stream,
            pos: 0,
            caps: nil,
            blocking_strategy: nil,
            current_metadata: nil,
            streaming?: false

  @doc """
  Returns an initialized parser state
  """
  @spec init(boolean()) :: state()
  def init(streaming? \\ false) do
    %__MODULE__{streaming?: streaming?}
  end

  @doc """
  Parses FLAC stream, splitting it into `Membrane.Buffer`s and providing caps.

  See moduledoc (`#{inspect(__MODULE__)}`) for more info

  The call without `state` provided is an equivalent of using `init/0` as `state`
  """
  @spec parse(binary(), state()) :: {:ok, [Caps.t() | Buffer.t()], state()}
  def parse(binary_data, state \\ init())

  def parse(binary_data, %{queue: queue, continue: continue} = state) do
    res = do_parse(continue, queue <> binary_data, [], %{state | queue: ""})

    with {:ok, acc, state} <- res do
      {:ok, acc |> Enum.reverse(), state}
    end
  end

  @doc """
  Outputs the last buffer queued in parser. Should be called afer providing
  all data to the parser.
  """
  @spec flush(state()) :: {:ok, Membrane.Buffer.t()}
  def flush(%{current_metadata: metadata, queue: queue}) do
    buf = %Buffer{payload: queue, metadata: metadata}
    {:ok, buf}
  end

  # STREAM parsing
  # Don't start parsing until we have at least streaminfo header
  defp do_parse(:stream, binary_data, acc, state) when byte_size(binary_data) < 42 do
    {:ok, acc, %{state | queue: binary_data, continue: :stream}}
  end

  defp do_parse(:stream, "fLaC" <> tail, acc, state) do
    buf = %Buffer{payload: "fLaC"}
    do_parse(:metadata_block, tail, [buf | acc], %{state | pos: 4})
  end

  defp do_parse(:stream, _data, _acc, %{streaming?: false} = state) do
    {:error, {:not_stream, pos: state.pos}}
  end

  defp do_parse(:stream, data, acc, %{streaming?: true} = state) do
    do_parse(:frame, data, acc, state)
  end

  # METADATA_BLOCK parsing
  defp do_parse(
         :metadata_block,
         <<is_last::1, type::7, size::24, block::binary-size(size), rest::binary>> = data,
         acc,
         %{pos: pos} = state
       ) do
    payload = binary_part(data, 0, 4 + size)
    buf = %Buffer{payload: payload}

    caps = decode_metadata_block(type, block)

    {acc, state} =
      case caps do
        nil -> {[buf | acc], state}
        caps -> {[buf | acc] ++ [caps], %{state | caps: caps}}
      end

    state = %{state | pos: pos + byte_size(payload)}

    if is_last == 1 do
      do_parse(:frame, rest, acc, state)
    else
      do_parse(:metadata_block, rest, acc, state)
    end
  end

  defp do_parse(:metadata_block, data, acc, state) do
    {:ok, acc, %{state | queue: data, continue: :metadata_block}}
  end

  # FRAME parsing
  defp do_parse(:frame, data, acc, state) when bit_size(data) < 15 + 1 + 4 + 4 + 4 + 3 + 1 do
    {:ok, acc, %{state | queue: data, continue: :frame}}
  end

  defp do_parse(:frame, data, acc, %{caps: %{min_frame_size: min_frame_size}} = state)
       when min_frame_size != nil and byte_size(data) < min_frame_size do
    {:ok, acc, %{state | queue: data, continue: :frame}}
  end

  # no frame parsed yet
  defp do_parse(
         :frame,
         <<@frame_start, blocking_strategy::1, _::binary>> = data,
         acc,
         %{blocking_strategy: nil} = state
       ) do
    state = %{state | blocking_strategy: blocking_strategy}

    do_parse(:frame, data, acc, state)
  end

  # no full header parsed yet
  defp do_parse(
         :frame,
         <<@frame_start, blocking_strategy::1, _::binary>> = data,
         acc,
         %{blocking_strategy: blocking_strategy, current_metadata: nil} = state
       ) do
    case parse_frame_header(data, state) do
      :nodata ->
        {:ok, acc, %{state | queue: data, continue: :frame}}

      {:error, _reason} = e ->
        e

      {:ok, metadata} ->
        {acc, state} =
          if state.streaming? and state.caps == nil do
            # header haven't beeen parsed, so we need to generate caps from metadata
            caps = caps_from_metadata(blocking_strategy, metadata)
            {acc ++ [caps], %{state | caps: caps}}
          else
            {acc, state}
          end

        do_parse(:frame, data, acc, %{state | current_metadata: metadata})
    end
  end

  defp do_parse(
         :frame,
         <<@frame_start, blocking_strategy::1, _::binary>> = data,
         acc,
         %{blocking_strategy: blocking_strategy, current_metadata: current_metadata, pos: pos} =
           state
       ) do
    # TODO: include position in queue to prevent scanning the same bytes
    # Skip at least frame_start
    search_start = max(@frame_start_size, state.caps.min_frame_size || 0)

    search_end =
      case state.caps.max_frame_size do
        nil -> byte_size(data)
        max_frame_size -> min(byte_size(data), max_frame_size + @frame_start_size)
      end

    search_scope = {search_start, search_end - search_start}

    case find_next_frame(data, search_scope, state) do
      :nomatch when search_end < byte_size(data) ->
        # At this point next frame start should've been found
        # because `search_end` was set to max_frame_size + 2
        {:error, {:invalid_frame, pos: state.pos}}

      res when res in [:nomatch, :nodata] ->
        # `search_end` was limited by the size of data or parsing needs more data
        {:ok, acc, %{state | queue: data, continue: :frame}}

      {frame, rest, next_metadata} ->
        buf = %Buffer{payload: frame, metadata: current_metadata}

        do_parse(:frame, rest, [buf | acc], %{
          state
          | pos: pos + byte_size(frame),
            queue: "",
            continue: :frame,
            current_metadata: next_metadata
        })
    end
  end

  defp do_parse(:frame, _data, _acc, state) do
    {:error, {:invalid_frame, pos: state.pos}}
  end

  defp caps_from_metadata(blocking_strategy, metadata) do
    keys = metadata |> Map.take([:sample_rate, :channels, :sample_size])
    caps = struct!(FLAC, keys)

    if blocking_strategy == @blocking_stg_fixed do
      %{caps | min_block_size: metadata.samples, max_block_size: metadata.samples}
    else
      caps
    end
  end

  defp find_next_frame(data, search_scope, %{blocking_strategy: blocking_strategy} = state) do
    matches =
      case blocking_strategy do
        @blocking_stg_fixed ->
          :binary.matches(data, @fixed_frame_start, scope: search_scope)

        @blocking_stg_variable ->
          :binary.matches(data, @variable_frame_start, scope: search_scope)
      end

    matches
    |> Enum.find_value(:nomatch, fn {pos, _len} ->
      <<frame::binary-size(pos), next_frame_candidate::binary>> = data

      case parse_frame_header(next_frame_candidate, state) do
        :nodata -> :nodata
        {:error, _reason} -> false
        {:ok, metadata} -> {frame, next_frame_candidate, metadata}
      end
    end)
  end

  defp decode_metadata_block(
         @metadata_block_streaminfo,
         <<min_block_size::16, max_block_size::16, min_frame_size::24, max_frame_size::24,
           sample_rate::20, channels::3, sample_size::5, total_samples::36, md5::binary-16>>
       ) do
    %FLAC{
      min_block_size: min_block_size |> nil_if_unknown(),
      max_block_size: max_block_size |> nil_if_unknown(),
      min_frame_size: min_frame_size |> nil_if_unknown(),
      max_frame_size: max_frame_size |> nil_if_unknown(),
      sample_rate: sample_rate,
      channels: channels + 1,
      sample_size: sample_size + 1,
      total_samples: total_samples |> nil_if_unknown(),
      md5_signature: md5 |> nil_if_unknown()
    }
  end

  defp decode_metadata_block(type, _block)
       when type in [
              @metadata_block_padding,
              @metadata_block_application,
              @metadata_block_seektable,
              @metadata_block_vorbis_comment,
              @metadata_block_cuesheet,
              @metadata_block_picture
            ] do
    # TODO: Parse other metadata blocks in future
    nil
  end

  defp nil_if_unknown(0), do: nil
  defp nil_if_unknown(<<0::16*8>>), do: nil
  defp nil_if_unknown(x), do: x

  @spec parse_frame_header(binary(), state()) ::
          :nodata
          | {:ok, FLAC.FrameMetadata.t()}
          | {:error, reason}
        when reason:
               :invalid_block_size
               | :invalid_header_crc
               | :invalid_sample_rate
               | :invalid_utf8_num
               | {:invalid_header, any()}
  defp parse_frame_header(data, _state) when byte_size(data) < 4 do
    :nodata
  end

  defp parse_frame_header(
         <<@frame_start, blocking_strategy::1, block_size::4, sample_rate::4, channels::4,
           sample_size::3, 0::1, rest::binary>> = data,
         %{blocking_strategy: blocking_strategy} = state
       )
       when block_size != 0 and sample_rate != 0b1111 and channels not in 0b1011..0b1111 and
              sample_size not in [0b011, 0b111] do
    with {:ok, number, rest} <- decode_utf8_num(rest),
         {:ok, block_size, rest} <- decode_block_size(block_size, rest),
         {:ok, sample_rate, rest} <- decode_sample_rate(sample_rate, rest, state),
         header_size = byte_size(data) - byte_size(rest),
         <<crc8::8, _rest::binary>> <- if(rest == <<>>, do: :nodata, else: rest),
         <<header::binary-size(header_size), _::binary>> = data,
         :ok <- verify_crc(header, crc8) do
      sample_number =
        case {blocking_strategy, state.caps} do
          {@blocking_stg_fixed, nil} -> number * block_size
          {@blocking_stg_fixed, caps} -> number * caps.min_block_size
          {@blocking_stg_variable, _} -> number
        end

      sample_size =
        case sample_size do
          0b000 -> state.caps.sample_size
          0b001 -> 8
          0b010 -> 12
          0b100 -> 16
          0b101 -> 20
          0b110 -> 24
        end

      {channels, channel_mode} =
        case channels do
          0b1000 -> {2, :left_side}
          0b1001 -> {2, :right_side}
          0b1010 -> {2, :mid_side}
          _other -> {channels + 1, :independent}
        end

      metadata = %FLAC.FrameMetadata{
        channels: channels,
        channel_mode: channel_mode,
        starting_sample_number: sample_number,
        samples: block_size,
        sample_rate: sample_rate,
        sample_size: sample_size
      }

      if metadata_valid?(metadata, state) do
        {:ok, metadata}
      else
        {:error, {:invalid_header, pos: state.pos}}
      end
    end
  end

  defp parse_frame_header(_data, state) do
    {:error, {:invalid_header, pos: state.pos}}
  end

  defp metadata_valid?(_metadata, %{caps: nil, current_metadata: nil, streaming?: true}) do
    # First parsed metadata from the middle of stream
    # there's no way to verify anything
    true
  end

  defp metadata_valid?(metadata, %{caps: caps, current_metadata: last_meta}) do
    expected_sample_number =
      case last_meta do
        nil ->
          0

        %{starting_sample_number: starting_sample_number, samples: samples} ->
          starting_sample_number + samples
      end

    metadata.starting_sample_number == expected_sample_number and
      metadata.channels == caps.channels and
      metadata.sample_rate == caps.sample_rate and
      metadata.sample_size == caps.sample_size and
      (caps.max_block_size == nil or metadata.samples <= caps.max_block_size)

    # cannot test for min_block_size because last frame in fixed blocking strategy
    # is smaller than rest
  end

  @spec decode_block_size(byte(), binary()) ::
          :nodata
          | {:ok, pos_integer(), binary()}
          | {:error, :invalid_block_size}
  defp decode_block_size(0b0000, _rest) do
    {:error, :invalid_block_size}
  end

  defp decode_block_size(0b0001, rest) do
    {:ok, 192, rest}
  end

  defp decode_block_size(0b0110, <<>>) do
    :nodata
  end

  defp decode_block_size(0b0110, <<block_size::8, rest::binary>>) do
    {:ok, block_size + 1, rest}
  end

  defp decode_block_size(0b0111, rest) when byte_size(rest) < 2 do
    :nodata
  end

  defp decode_block_size(0b0111, <<block_size::16, rest::binary>>) do
    {:ok, block_size + 1, rest}
  end

  defp decode_block_size(block_size, rest) when block_size in 0b0010..0b0101 do
    use Bitwise
    {:ok, 576 <<< (block_size - 2), rest}
  end

  defp decode_block_size(block_size, rest) when block_size in 0b1000..0b1111 do
    use Bitwise
    {:ok, 1 <<< block_size, rest}
  end

  @spec decode_sample_rate(byte, binary(), state()) ::
          {:ok, sample_rate :: non_neg_integer(), rest :: binary()}
          | {:error, :invalid_sample_rate}
          | :nodata
  defp decode_sample_rate(0b1100, <<>>, _state) do
    :nodata
  end

  defp decode_sample_rate(0b1100, <<sample_rate::8, rest::binary>>, _state) do
    {:ok, sample_rate * 1000, rest}
  end

  defp decode_sample_rate(raw_sample_rate, rest, _state)
       when raw_sample_rate in [0b1101, 0b1110] and byte_size(rest) < 2 do
    :nodata
  end

  defp decode_sample_rate(0b1101, <<sample_rate::16, rest::binary>>, _state) do
    {:ok, sample_rate, rest}
  end

  defp decode_sample_rate(0b1110, <<sample_rate::16, rest::binary>>, _state) do
    {:ok, sample_rate * 10, rest}
  end

  defp decode_sample_rate(0b1111, _rest, _state) do
    {:error, :invalid_sample_rate}
  end

  defp decode_sample_rate(raw_sample_rate, rest, state) do
    sample_rate =
      case raw_sample_rate do
        0b0000 -> state.caps.sample_rate
        0b0001 -> 88_200
        0b0010 -> 176_400
        0b0011 -> 192_000
        0b0100 -> 8000
        0b0101 -> 16_000
        0b0110 -> 22_050
        0b0111 -> 24_000
        0b1000 -> 32_000
        0b1001 -> 44_100
        0b1010 -> 48_000
        0b1011 -> 96_000
      end

    {:ok, sample_rate, rest}
  end

  @spec decode_utf8_num(binary()) ::
          {:ok, decoded_num :: non_neg_integer(), rest :: binary()}
          | {:error, :invalid_utf8_num}
          | :nodata
  defp decode_utf8_num(<<>>) do
    :nodata
  end

  defp decode_utf8_num(<<first_byte, rest::binary>>) do
    case <<first_byte>> do
      <<0::1, num::7>> -> {:ok, num, rest}
      <<0b110::3, num_part::bitstring>> -> decode_utf8_num_tail(rest, num_part, 1)
      <<0b1110::4, num_part::bitstring>> -> decode_utf8_num_tail(rest, num_part, 2)
      <<0b11110::5, num_part::bitstring>> -> decode_utf8_num_tail(rest, num_part, 3)
      <<0b111110::6, num_part::bitstring>> -> decode_utf8_num_tail(rest, num_part, 4)
      <<0b1111110::7, num_part::bitstring>> -> decode_utf8_num_tail(rest, num_part, 5)
      <<0b11111110::8>> -> decode_utf8_num_tail(rest, <<>>, 6)
      _other -> {:error, :invalid_utf8_num}
    end
  end

  defp decode_utf8_num_tail(rest, _acc, bytes_num) when byte_size(rest) < bytes_num do
    :nodata
  end

  defp decode_utf8_num_tail(rest, acc, 0) do
    size = bit_size(acc)
    <<num::size(size)>> = acc
    {:ok, num, rest}
  end

  defp decode_utf8_num_tail(<<0b10::2, num_part::6, rest::binary>>, acc, bytes_num) do
    decode_utf8_num_tail(rest, <<acc::bitstring, num_part::6>>, bytes_num - 1)
  end

  defp decode_utf8_num_tail(_rest, _acc, _bytes_num) do
    {:error, :invalid_utf8_num}
  end

  defp verify_crc(header, crc8) do
    if CRC.calculate(header, :crc_8) == crc8 do
      :ok
    else
      {:error, :invalid_header_crc}
    end
  end
end
