defmodule Membrane.AudioMixer do
  @moduledoc """
  This element performs audio mixing.

  Audio format can be set as an element option or received through caps from input pads. All
  received caps have to be identical and match ones in element option (if that option is
  different from `nil`).

  Input pads can have offset - it tells how much silence should be added before first sample
  from that pad. Offset has to be positive.

  Mixer mixes only raw audio (PCM), so some parser may be needed to precede it in pipeline.
  """

  use Membrane.Filter
  use Bunch

  require Membrane.Logger

  alias Membrane.AudioMixer.Declipper
  alias Membrane.AudioMixer.DoMix
  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw
  alias Membrane.Caps.Matcher
  alias Membrane.Time

  @supported_caps {Raw,
                   format: Matcher.one_of([:s8, :s16le, :s16be, :s24le, :s24be, :s32le, :s32be])}

  def_options caps: [
                type: :struct,
                spec: Raw.t(),
                description: """
                The value defines a raw audio format of pads connected to the
                element. It should be the same for all the pads.
                """,
                default: nil
              ],
              frames_per_buffer: [
                type: :integer,
                spec: pos_integer(),
                description: """
                Assumed number of raw audio frames in each buffer.
                Used when converting demand from buffers into bytes.
                """,
                default: 2048
              ],
              declipper: [
                type: :boolean,
                spec: boolean(),
                description: """
                If false, overflowed waves will be clipped to the max value.
                If true, overflowed waves will be scaled down to the max value.
                """,
                default: true
              ]

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    caps: Raw

  def_input_pad :input,
    mode: :pull,
    availability: :on_request,
    demand_unit: :bytes,
    caps: @supported_caps,
    options: [
      offset: [
        spec: Time.t(),
        default: 0,
        description: "Offset of the input audio at the pad."
      ]
    ]

  @impl true
  def handle_init(%__MODULE__{} = options) do
    state =
      options
      |> Map.from_struct()
      |> Map.put(:pads, %{})

    state =
      if state.declipper do
        Map.put(state, :declipper, %Declipper.State{})
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_pad_added(pad, _context, state) do
    state =
      Bunch.Access.put_in(
        state,
        [:pads, pad],
        %{queue: <<>>, stream_ended: false}
      )

    {:ok, state}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    state = Bunch.Access.delete_in(state, [:pads, pad])

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_context, %{caps: %Raw{} = caps} = state) do
    {{:ok, caps: {:output, caps}}, state}
  end

  def handle_prepared_to_playing(_context, %{caps: nil} = state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(:output, size, :bytes, _context, state) do
    do_handle_demand(size, state)
  end

  @impl true
  def handle_demand(:output, _buffers_count, :buffers, _context, %{caps: nil} = state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(
        :output,
        buffers_count,
        :buffers,
        _context,
        %{frames_per_buffer: frames, caps: caps} = state
      ) do
    size = buffers_count * Raw.frames_to_bytes(frames, caps)
    do_handle_demand(size, state)
  end

  @impl true
  def handle_start_of_stream(pad, context, state) do
    offset = context.pads[pad].options.offset
    silence = Raw.sound_of_silence(state.caps, offset)

    state =
      Bunch.Access.update_in(
        state,
        [:pads, pad],
        &%{&1 | queue: silence}
      )

    demand_fun = &max(0, &1 - byte_size(silence))
    {buffer, state} = mix_and_get_buffer(state)

    {{:ok, demand: {pad, demand_fun}, buffer: buffer}, state}
  end

  @impl true
  def handle_end_of_stream(pad, _context, state) do
    state =
      case Bunch.Access.get_in(state, [:pads, pad]) do
        %{queue: <<>>} ->
          Bunch.Access.delete_in(state, [:pads, pad])

        _state ->
          Bunch.Access.update_in(
            state,
            [:pads, pad],
            &%{&1 | stream_ended: true}
          )
      end

    {buffer, state} = mix_and_get_buffer(state)

    if all_streams_ended?(state) do
      {{:ok, buffer: buffer, end_of_stream: :output}, state}
    else
      {{:ok, buffer: buffer}, state}
    end
  end

  @impl true
  def handle_event(pad, event, _context, state) do
    Membrane.Logger.debug("Received event #{inspect(event)} on pad #{inspect(pad)}")

    {:ok, state}
  end

  @impl true
  def handle_process(
        pad_ref,
        %Buffer{payload: payload},
        _context,
        %{caps: caps, pads: pads} = state
      ) do
    time_frame = Raw.frame_size(caps)

    {size, pads} =
      Map.get_and_update(
        pads,
        pad_ref,
        fn %{queue: queue} = pad ->
          {byte_size(queue) + byte_size(payload), %{pad | queue: queue <> payload}}
        end
      )

    if size >= time_frame do
      {{_pad, %Buffer{payload: payload}} = buffer, state} =
        mix_and_get_buffer(%{state | pads: pads})

      redemand = if payload == <<>>, do: [redemand: :output], else: []
      actions = [{:buffer, buffer} | redemand]
      {{:ok, actions}, state}
    else
      {{:ok, redemand: :output}, %{state | pads: pads}}
    end
  end

  @impl true
  def handle_caps(_pad, caps, _context, %{caps: nil} = state) do
    state = %{state | caps: caps}

    {{:ok, caps: {:output, caps}, redemand: :output}, state}
  end

  @impl true
  def handle_caps(_pad, caps, _context, %{caps: caps} = state) do
    {:ok, state}
  end

  @impl true
  def handle_caps(pad, caps, _context, state) do
    raise(
      RuntimeError,
      "received invalid caps on pad #{inspect(pad)}, expected: #{inspect(state.caps)}, got: #{inspect(caps)}"
    )
  end

  defp do_handle_demand(size, %{pads: pads} = state) do
    pads
    |> Enum.map(fn {pad, %{queue: queue}} ->
      queue
      |> byte_size()
      |> then(&{:demand, {pad, max(0, size - &1)}})
    end)
    |> then(fn demands -> {{:ok, demands}, state} end)
  end

  defp mix_and_get_buffer(%{caps: caps, pads: pads} = state) do
    time_frame = Raw.frame_size(caps)
    mix_size = get_mix_size(pads, time_frame)

    {payload, state} =
      cond do
        mix_size >= time_frame ->
          {payload, pads, state} = mix(pads, mix_size, state)
          pads = remove_finished_pads(pads, time_frame)

          state = %{state | pads: pads}

          {payload, state}

        last_declipper_wave?(state) ->
          mix_payloads([], state)

        true ->
          {<<>>, state}
      end

    buffer = {:output, %Buffer{payload: payload}}
    {buffer, state}
  end

  defp get_mix_size(pads, time_frame) do
    pads
    |> Enum.map(fn {_pad, %{queue: queue}} -> byte_size(queue) end)
    |> Enum.min(fn -> 0 end)
    |> int_part(time_frame)
  end

  # Returns the biggest multiple of `divisor` that is not bigger than `number`
  defp int_part(number, divisor) when is_integer(number) and is_integer(divisor) do
    rest = rem(number, divisor)
    number - rest
  end

  defp mix(pads, mix_size, %{declipper: false} = state) when map_size(pads) == 1 do
    [{pad, data}] = Map.to_list(pads)

    <<payload::binary-size(mix_size)>> <> queue = data.queue

    {payload, %{pad => %{data | queue: queue}}, state}
  end

  defp mix(pads, mix_size, state) do
    {payloads, pads_list} =
      pads
      |> Enum.map(fn
        {pad, %{queue: <<payload::binary-size(mix_size)>> <> queue} = data} ->
          {payload, {pad, %{data | queue: queue}}}
      end)
      |> Enum.unzip()

    {payload, state} = mix_payloads(payloads, state)
    pads = Map.new(pads_list)

    {payload, pads, state}
  end

  defp all_streams_ended?(%{pads: pads}) do
    pads
    |> Enum.map(fn {_pad, %{stream_ended: stream_ended}} -> stream_ended end)
    |> Enum.all?()
  end

  defp last_declipper_wave?(%{declipper: declipper} = state) do
    declipper != false && all_streams_ended?(state)
  end

  defp remove_finished_pads(pads, time_frame) do
    pads
    |> Enum.flat_map(fn
      {_pad, %{queue: queue, stream_ended: true}} when byte_size(queue) < time_frame -> []
      pad_data -> [pad_data]
    end)
    |> Map.new()
  end

  defp mix_payloads(payloads, %{declipper: %Declipper.State{} = declipper, caps: caps} = state) do
    all_ended = all_streams_ended?(state)
    {payload, declipper} = Declipper.mix(payloads, all_ended, caps, declipper)
    state = Map.put(state, :declipper, declipper)

    {payload, state}
  end

  defp mix_payloads(payloads, state) do
    payload = DoMix.mix(payloads, state.caps)
    {payload, state}
  end
end
