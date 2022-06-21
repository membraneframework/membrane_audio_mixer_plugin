# Membrane Audio Mix Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_audio_mix_plugin.svg)](https://hex.pm/packages/membrane_audio_mix_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_audio_mix_plugin/)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_audio_mix_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_audio_mix_plugin)

Plugin providing elements for mixing and interleaving raw audio frames.

It is a part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

Add the following line to your `deps` in `mix.exs`. Run `mix deps.get`.

```elixir
	{:membrane_audio_mix_plugin, "~> 0.9.0"}
```

## Description

Both elements operate only on raw audio (PCM), so some parser may be needed to precede them in a pipeline.

Audio format can be set as an element option or received through caps from input pads. All
caps received from input pads have to be identical and match ones in element option (if that
option is different from `nil`).

Input pads can have offset - it tells how much silence should be added before first sample
from that pad. Offset has to be positive.

All inputs have to be added before starting the pipeline and should not be changed
during mixer's or interleaver's work.

Mixing and interleaving is tested only for integer audio formats.

### Mixer

The Mixer adds samples from all pads. It has two strategies to deal with the overflow:
scaling down waves and clipping. There's also the faster, semi-native version of the Mixer.
Only the scaling-down strategy is available in the native Mixer.

### Interleaver

This element joins several mono audio streams (with one channel) into one stream with interleaved channels.

If audio streams have different durations, all shorter streams are appended with silence to match the longest stream.

Each channel must be named by providing an input pad name and the channel layout using those names must be provided (see [usage example](#audiointerleaver)).

## Usage Example

### AudioMixer

The following pipeline takes two raw audio files as input, mixes them using `AudioMixer`, and then plays the result.
Five seconds offset is applied to the second file.

```elixir
defmodule Mixing.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_) do
    mixer = %Membrane.AudioMixer{
      caps: %Membrane.RawAudio{
        channels: 1,
        sample_rate: 16_000,
        sample_format: :s16le
      },
      prevent_clipping: false
    }

    children = [
      file_src_1: %Membrane.File.Source{location: "/tmp/input_1.raw"},
      file_src_2: %Membrane.File.Source{location: "/tmp/input_2.raw"},
      mixer: mixer,
      converter: %Membrane.FFmpeg.SWResample.Converter{
        input_caps: %Membrane.RawAudio{channels: 1, sample_rate: 16_000, sample_format: :s16le},
        output_caps: %Membrane.RawAudio{channels: 2, sample_rate: 48_000, sample_format: :s16le}
      },
      player: Membrane.PortAudio.Sink
    ]

    links = [
      link(:file_src_1)
      |> to(:mixer)
      |> to(:converter)
      |> to(:player),
      link(:file_src_2)
      |> via_in(:input, options: [offset: Membrane.Time.milliseconds(5000)])
      |> to(:mixer)
    ]

    {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
  end
end
```

### Native AudioMixer

The pipeline for this example is the same as for [`AudioMixer`](#audiomixer),
the only difference being the `mixer`.

```elixir
...
    mixer = %Membrane.AudioMixer{
      caps: %Membrane.RawAudio{
        channels: 1,
        sample_rate: 16_000,
        sample_format: :s16le
      },
      native_mixer: true,
      prevent_clipping: true
    }
...
```

### AudioInterleaver

The following pipeline takes two `wav` audio files as input, interleaves them,
and then saves them as a single raw audio file.

```elixir
defmodule Interleave.Pipeline do
  use Membrane.Pipeline

  alias Membrane.File.{Sink, Source}

  @impl true
  def handle_init({path_to_wav_1, path_to_wav_2}) do
    children = %{
      file_1: %Source{location: path_to_wav_1},
      file_2: %Source{location: path_to_wav_2},
      parser_1: Membrane.WAV.Parser,
      parser_2: Membrane.WAV.Parser,
      interleaver: %Membrane.AudioInterleaver{
        input_caps: %Membrane.RawAudio{
          channels: 1,
          sample_rate: 16_000,
          sample_format: :s16le
        },
        order: [:left, :right]
      },
      file_sink: %Sink{location: "output.raw"}
    }

    links = [
      link(:file_1)
      |> to(:parser_1)
      |> via_in(Pad.ref(:input, :left))
      |> to(:interleaver),
      link(:file_2)
      |> to(:parser_2)
      |> via_in(Pad.ref(:input, :right))
      |> to(:interleaver),
      link(:interleaver)
      |> to(:file_sink)
    ]

    {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
  end
end
```

### AudioMixerBin

The following pipeline takes four raw audio files as input, mixes them using `AudioMixerBin`, and plays the result.
Because `max_inputs_per_node` equals 2, the `AudioMixerBin` should create a 3-node tree of depth 1.

```
src_1 src_2 src_3 src_4
  |     |     |     |
   \   /       \   /
    \ /         \ /
 mixer_1_0   mixer_1_1
     |           |
      \         /
       \       /
       mixer_0_0
           |
```

```elixir
defmodule MixingBin.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_) do
    mixer_options = %Membrane.AudioMixer{
      caps: %Membrane.RawAudio{
        channels: 1,
        sample_rate: 16_000,
        sample_format: :s16le
      },
      prevent_clipping: false
    }

    children = [
      file_src_1: %Membrane.File.Source{location: "/tmp/input-1.raw"},
      file_src_2: %Membrane.File.Source{location: "/tmp/input-2.raw"},
      file_src_3: %Membrane.File.Source{location: "/tmp/input-3.raw"},
      file_src_4: %Membrane.File.Source{location: "/tmp/input-4.raw"},
      mixer_bin: %Membrane.AudioMixerBin{
        max_inputs_per_node: 2,
        mixer_options: mixer_options
      },
      converter: %Membrane.FFmpeg.SWResample.Converter{
        input_caps: %Membrane.RawAudio{channels: 1, sample_rate: 16_000, sample_format: :s16le},
        output_caps: %Membrane.RawAudio{channels: 2, sample_rate: 48_000, sample_format: :s16le}
      },
      player: Membrane.PortAudio.Sink
    ]

    links = [
      link(:file_src_1)
      |> to(:mixer_bin)
      |> to(:converter)
      |> to(:player),
      link(:file_src_2)
      |> to(:mixer_bin),
      link(:file_src_3)
      |> to(:mixer_bin),
      link(:file_src_4)
      |> to(:mixer_bin)
    ]

    send(self(), {:linking_finished, :mixer_bin})

    {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
  end

  @impl true
  def handle_other({:linking_finished, name}, _ctx, state) do
    {{:ok, forward: {name, :linking_finished}}, state}
  end
end
```

### AudioMixerBin with native AudioMixer

The pipeline for this example is the same as for [`AudioMixerBin`](#audiomixerbin),
the only difference being `mixer_options`.

```elixir
...
    mixer_options = %Membrane.AudioMixer{
      caps: %Membrane.RawAudio{
        channels: 1,
        sample_rate: 16_000,
        sample_format: :s16le
      },
      native_mixer: true,
      prevent_clipping: true
    }
...
```

## Copyright and License

Copyright 2021, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

Licensed under the [Apache License, Version 2.0](LICENSE)
