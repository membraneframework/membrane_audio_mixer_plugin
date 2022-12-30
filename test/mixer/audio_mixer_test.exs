defmodule Membrane.AudioMixerTest do
  @moduledoc false

  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  alias Membrane.RawAudio
  alias Membrane.Testing.Pipeline

  @input_path_1 Path.expand("../fixtures/mixer/input-1.raw", __DIR__)
  @input_path_2 Path.expand("../fixtures/mixer/input-2.raw", __DIR__)

  @input_path_mp3 Path.expand("../fixtures/mixer/input.mp3", __DIR__)

  defp expand_path(file_name) do
    Path.expand("../fixtures/mixer/#{file_name}", __DIR__)
  end

  defp prepare_output() do
    output_path = expand_path("output.raw")

    File.rm(output_path)
    on_exit(fn -> File.rm(output_path) end)

    output_path
  end

  describe "Audio Mixer should mix" do
    defp create_elements(input_paths, output_path, audio_format \\ :s16le) do
      base_elements =
        input_paths
        |> Enum.with_index(1)
        |> Enum.map(fn {path, index} ->
          child({:file_src, index}, %Membrane.File.Source{location: path})
        end)
        |> Enum.concat([child(:file_sink, %Membrane.File.Sink{location: output_path})])

      mixer = %Membrane.AudioMixer{
        stream_format: %RawAudio{
          channels: 1,
          sample_rate: 16_000,
          sample_format: audio_format
        },
        prevent_clipping: false
      }

      preventer_mixer = %Membrane.AudioMixer{mixer | prevent_clipping: true}
      native_mixer = %Membrane.AudioMixer{preventer_mixer | native_mixer: true}

      {
        base_elements ++ [child(:mixer, mixer)],
        base_elements ++ [child(:mixer, preventer_mixer)],
        base_elements ++ [child(:mixer, native_mixer)]
      }
    end

    defp perform_test(
           {clipper_elements, preventer_elements, native_elements},
           links,
           clipper_reference,
           preventer_reference,
           output_path
         ) do
      do_perform_test(clipper_elements ++ links, clipper_reference, output_path)
      do_perform_test(preventer_elements ++ links, preventer_reference, output_path)
      do_perform_test(native_elements ++ links, preventer_reference, output_path)
    end

    defp do_perform_test(structure, reference_path, output_path) do
      assert pipeline = Pipeline.start_link_supervised!(structure: structure)

      assert_end_of_stream(pipeline, :file_sink, :input, 5_000)

      assert {:ok, reference_file} = File.read(reference_path)
      assert {:ok, output_file} = File.read(output_path)
      assert output_file == reference_file
    end

    test "two tracks with the same size" do
      output_path = prepare_output()
      reference_path = expand_path("reference-same-size.raw")
      preventer_reference_path = expand_path("reference-same-size-preventer.raw")

      elements = create_elements([@input_path_1, @input_path_1], output_path)

      links = [
        get_child({:file_src, 1})
        |> get_child(:mixer)
        |> get_child(:file_sink),
        get_child({:file_src, 2})
        |> get_child(:mixer)
      ]

      perform_test(elements, links, reference_path, preventer_reference_path, output_path)
    end

    test "two tracks with different sizes" do
      output_path = prepare_output()
      reference_path = expand_path("reference-different-size.raw")

      elements = create_elements([@input_path_1, @input_path_2], output_path)

      links = [
        get_child({:file_src, 1})
        |> get_child(:mixer)
        |> get_child(:file_sink),
        get_child({:file_src, 2})
        |> get_child(:mixer)
      ]

      perform_test(elements, links, reference_path, reference_path, output_path)
    end

    test "tracks when the shorter one has an offset" do
      output_path = prepare_output()
      reference_path = expand_path("reference-offset-first.raw")

      elements = create_elements([@input_path_1, @input_path_2], output_path)

      links = [
        get_child({:file_src, 1})
        |> via_in(:input, options: [offset: Membrane.Time.microseconds(125)])
        |> get_child(:mixer)
        |> get_child(:file_sink),
        get_child({:file_src, 2})
        |> get_child(:mixer)
      ]

      perform_test(elements, links, reference_path, reference_path, output_path)
    end

    test "tracks when the longer one has an offset" do
      output_path = prepare_output()
      reference_path = expand_path("reference-offset-second.raw")

      elements = create_elements([@input_path_1, @input_path_2], output_path)

      links = [
        get_child({:file_src, 1})
        |> get_child(:mixer)
        |> get_child(:file_sink),
        get_child({:file_src, 2})
        |> via_in(:input, options: [offset: Membrane.Time.microseconds(250)])
        |> get_child(:mixer)
      ]

      perform_test(elements, links, reference_path, reference_path, output_path)
    end

    test "tracks when both have offsets" do
      output_path = prepare_output()
      reference_path = expand_path("reference-offsets-both.raw")

      elements = create_elements([@input_path_1, @input_path_2], output_path)

      links = [
        get_child({:file_src, 1})
        |> via_in(:input, options: [offset: Membrane.Time.microseconds(500)])
        |> get_child(:mixer)
        |> get_child(:file_sink),
        get_child({:file_src, 2})
        |> via_in(:input, options: [offset: Membrane.Time.microseconds(125)])
        |> get_child(:mixer)
      ]

      perform_test(elements, links, reference_path, reference_path, output_path)
    end

    test "three tracks" do
      output_path = prepare_output()
      reference_path = expand_path("reference-three.raw")

      elements = create_elements([@input_path_1, @input_path_1, @input_path_2], output_path)

      links = [
        get_child({:file_src, 1})
        |> get_child(:mixer)
        |> get_child(:file_sink),
        get_child({:file_src, 2})
        |> via_in(:input, options: [offset: Membrane.Time.microseconds(250)])
        |> get_child(:mixer),
        get_child({:file_src, 3})
        |> via_in(:input, options: [offset: Membrane.Time.microseconds(125)])
        |> get_child(:mixer)
      ]

      perform_test(elements, links, reference_path, reference_path, output_path)
    end
  end

  describe "Audio Mixer should handle received stream format" do
    defp create_elements_with_decoders(output_path, stream_format \\ nil) do
      mixer =
        case stream_format do
          nil ->
            Membrane.AudioMixer

          _stream_format ->
            %Membrane.AudioMixer{stream_format: stream_format}
        end

      [
        child(:mixer, mixer),
        child({:file_src, 1}, %Membrane.File.Source{location: @input_path_mp3}),
        child({:file_src, 2}, %Membrane.File.Source{location: @input_path_mp3}),
        child({:decoder, 1}, Membrane.MP3.MAD.Decoder),
        child({:decoder, 2}, Membrane.MP3.MAD.Decoder),
        child(:file_sink, %Membrane.File.Sink{location: output_path})
      ]
    end

    defp create_links() do
      [
        get_child({:file_src, 1})
        |> get_child({:decoder, 1})
        |> get_child(:mixer)
        |> get_child(:file_sink),
        get_child({:file_src, 2})
        |> get_child({:decoder, 2})
        |> get_child(:mixer)
      ]
    end

    defp perform_test(structure) do
      assert pipeline = Pipeline.start_link_supervised!(structure: structure)
      assert_end_of_stream(pipeline, :file_sink, :input, 5_000)
    end

    test "when they match and Mixer has its own stream format" do
      output_path = prepare_output()

      stream_format = %RawAudio{
        channels: 2,
        sample_rate: 44_100,
        sample_format: :s24le
      }

      elements = create_elements_with_decoders(output_path, stream_format)
      links = create_links()

      perform_test(elements ++ links)
    end

    test "when they match and Mixer does not have its own stream format" do
      output_path = prepare_output()

      elements = create_elements_with_decoders(output_path)
      links = create_links()

      perform_test(elements ++ links)
    end
  end
end
