defmodule Membrane.AudioMixer.ClipPreventingAdder do
  @moduledoc """
  Module responsible for mixing audio tracks (all in the same format, with the same number of
  channels and sample rate). The result is a single path in the format mixed paths are encoded in.
  If overflow happens during mixing, a wave will be scaled down to the max sample value.

  Description of the algorithm:
    - Start with an empty queue
    - Put merged values while the sign of the values remains the same
    - If you have a whole wave (from sign change to sign change) or adder is flushed:
      - If none of the values overflows limits of the format, convert the whole wave
        to binary samples and return them
      - Otherwise, scale down the whole wave, so the peak of the wave will become
        maximal (minimal) allowed value, convert wave to binary samples and return
        them.
  """

  @behaviour Membrane.AudioMixer.Mixer

  alias Membrane.AudioMixer.Helpers
  alias Membrane.Caps.Audio.Raw

  defstruct is_wave_positive: true, queue: []

  @type t :: %__MODULE__{
          is_wave_positive: boolean(),
          queue: [integer()]
        }

  @impl true
  def init(), do: %__MODULE__{}

  @impl true
  def mix(buffers, caps, state) do
    sample_size = Raw.sample_size(caps)

    buffers
    |> Helpers.zip_longest_binary_by(sample_size, fn buf -> do_mix(buf, caps) end)
    |> add_values(false, caps, state)
  end

  @impl true
  def flush(caps, state), do: add_values([], true, caps, state)

  defp do_mix(samples, caps) do
    samples
    |> Enum.map(&Raw.sample_to_value(&1, caps))
    |> Enum.sum()
  end

  defp add_values(values, is_last_wave, caps, state, buffer \\ <<>>) do
    split_fun = if state.is_wave_positive, do: &(&1 >= 0), else: &(&1 <= 0)
    {values, rest} = Enum.split_while(values, split_fun)

    if !is_last_wave && rest == [] do
      state = %__MODULE__{state | queue: state.queue ++ values}
      {buffer, state}
    else
      buffer = [buffer | get_iodata(values, caps, state)] |> IO.iodata_to_binary()

      state =
        state
        |> Map.put(:is_wave_positive, !state.is_wave_positive)
        |> Map.put(:queue, [])

      if is_last_wave && rest == [] do
        {buffer, state}
      else
        add_values(rest, is_last_wave, caps, state, buffer)
      end
    end
  end

  defp get_iodata([], _caps, %__MODULE__{queue: []}), do: <<>>

  defp get_iodata(values, caps, %__MODULE__{queue: queue}) do
    (queue ++ values)
    |> scale(caps)
    |> Enum.map(&Raw.value_to_sample(&1, caps))
  end

  defp scale(values, caps) do
    {min, max} = Enum.min_max(values)
    max_sample_value = Raw.sample_max(caps)
    min_sample_value = Raw.sample_min(caps)

    cond do
      min < min_sample_value -> do_scale(values, min_sample_value / min)
      max > max_sample_value -> do_scale(values, max_sample_value / max)
      true -> values
    end
  end

  defp do_scale(values, coefficient), do: Enum.map(values, &trunc(&1 * coefficient))
end
