defmodule ParsingPipeline do
  @moduledoc false

  alias Membrane.Testing.Pipeline

  @spec make_pipeline(String.t(), String.t(), boolean(), pid()) :: GenServer.on_start()
  def make_pipeline(in_path, out_path, streaming?, pid \\ self()) do
    Pipeline.start_link(%Pipeline.Options{
      elements: [
        file_src: %Membrane.File.Source{location: in_path},
        parser: %Membrane.FLACParser{streaming?: streaming?},
        sink: %Membrane.File.Sink{location: out_path}
      ],
      test_process: pid
    })
  end
end

defmodule Membrane.FLACParser.IntegrationTest do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Pipeline

  defp prepare_files(filename) do
    in_path = "../fixtures/#{filename}.flac" |> Path.expand(__DIR__)
    out_path = "/tmp/parsed-#{filename}.flac"
    File.rm(out_path)
    on_exit(fn -> File.rm(out_path) end)
    {in_path, out_path}
  end

  defp assert_parsing_success(filename, streaming?) do
    {in_path, out_path} = prepare_files(filename)
    assert {:ok, pid} = ParsingPipeline.make_pipeline(in_path, out_path, streaming?)

    # Start the pipeline
    assert Pipeline.play(pid) == :ok
    # Wait for EndOfStream message
    assert_end_of_stream(pid, :sink, :input, 3000)
    src_data = File.read!(in_path)
    out_data = File.read!(out_path)
    assert src_data == out_data
    assert Pipeline.stop_and_terminate(pid, blocking?: true) == :ok
  end

  defp assert_parsing_failure(filename, streaming?) do
    {in_path, out_path} = prepare_files(filename)
    assert {:ok, pid} = ParsingPipeline.make_pipeline(in_path, out_path, streaming?)

    Process.flag(:trap_exit, true)
    assert Pipeline.play(pid) == :ok
    assert_receive {:EXIT, ^pid, reason}, 3000
    assert {:shutdown, :child_crash} = reason
  end

  @moduletag :capture_log

  test "parse whole 'noise.flac' file" do
    assert_parsing_success("noise", false)
  end

  test "parse whole 'noise.flac' file in streaming mode" do
    assert_parsing_success("noise", true)
  end

  test "parse streamed file (only frames, no headers) in streaming mode" do
    assert_parsing_success("only_frames", true)
  end

  test "fail when parsing streamed file (only frames, no headers) without streaming mode" do
    assert_parsing_failure("only_frames", false)
  end

  test "fail when parsing file with junk at the end without streaming mode" do
    assert_parsing_failure("noise_and_junk", false)
  end
end
