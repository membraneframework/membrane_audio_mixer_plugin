defmodule Membrane.LiveAudioMixer do
  @moduledoc """
  This element performs audio mixing.

  Audio format can be set as an element option or received through stream_format from input pads. All
  received stream_format have to be identical and match ones in element option (if that option is
  different from `nil`).

  Input pads can have offset - it tells how much silence should be added before first sample
  from that pad. Offset has to be positive.

  Mixer mixes only raw audio (PCM), so some parser may be needed to precede it in pipeline.
  """

  use Membrane.Filter
  use Bunch

  require Membrane.Logger

  alias Membrane.AudioMixer.{Adder, ClipPreventingAdder, LiveQueue, NativeAdder}
  alias Membrane.Buffer
  alias Membrane.RawAudio
  alias Membrane.Time

  def_options stream_format: [
                type: :struct,
                spec: RawAudio.t(),
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
              prevent_clipping: [
                type: :boolean,
                spec: boolean(),
                description: """
                Defines how the mixer should act in the case when an overflow happens.
                - If true, the wave will be scaled down, so a peak will become the maximal
                value of the sample in the format. See `Membrane.AudioMixer.ClipPreventingAdder`.
                - If false, overflow will be clipped to the maximal value of the sample in
                the format. See `Membrane.AudioMixer.Adder`.
                """,
                default: true
              ],
              native_mixer: [
                type: :boolean,
                spec: boolean(),
                description: """
                The value determines if mixer should use NIFs for mixing audio. Only
                clip preventing version of native mixer is available.
                See `Membrane.AudioMixer.NativeAdder`.
                """,
                default: false
              ],
              synchronize_buffers?: [
                type: :boolean,
                spec: boolean(),
                description: """
                The value determines if mixer should synchronize buffers based on pts values.
                - If true, mixer will synchronize buffers based on its pts values. If buffer pts value is lower then the current
                mixing time (last_ts_sent) it will be dropped.
                - If false, mixer will take all incoming buffers no matter what pts they have and put it in the queue.
                """,
                default: false
              ]

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    accepted_format: RawAudio

  def_input_pad :input,
    mode: :pull,
    availability: :on_request,
    demand_unit: :bytes,
    accepted_format:
      any_of(
        %RawAudio{sample_format: sample_format}
        when sample_format in [:s8, :s16le, :s16be, :s24le, :s24be, :s32le, :s32be],
        Membrane.RemoteStream
      ),
    #
    options: [
      offset: [
        spec: Time.non_neg_t(),
        default: 0,
        description: "Offset of the input audio at the pad."
      ]
    ]

  @impl true
  def handle_init(_ctx, %__MODULE__{stream_format: stream_format} = options) do
    if options.native_mixer && !options.prevent_clipping do
      raise("Invalid element options, for native mixer only clipping preventing one is available")
    else
      {:ok, live_queue_state} = LiveQueue.init(stream_format)

      state =
        options
        |> Map.from_struct()
        |> Map.put(:mixer_state, initialize_mixer_state(stream_format, options))
        |> Map.put(:last_ts_sent, 0)
        |> Map.put(:live_queue, live_queue_state)

      {[], state}
    end
  end

  @impl true
  def handle_playing(_context, %{stream_format: %RawAudio{} = stream_format} = state) do
    {[
       stream_format: {:output, stream_format},
       start_timer: {:timer, Membrane.Time.milliseconds(100)}
     ], state}
  end

  def handle_playing(_context, %{stream_format: nil} = state) do
    {[start_timer: {:timer, Membrane.Time.milliseconds(100)}], state}
  end

  @impl true
  def handle_start_of_stream(
        Pad.ref(:input, pad_id) = pad,
        context,
        %{live_queue: live_queue} = state
      ) do
    offset = context.pads[pad].options.offset

    {:ok, new_live_queue} = LiveQueue.add_queue(pad_id, offset, live_queue)

    {[], %{state | live_queue: new_live_queue}}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, pad_id), context, %{live_queue: live_queue} = state) do
    {:ok, new_live_queue} = LiveQueue.remove_queue(pad_id, live_queue)

    actions =
      if all_streams_ended?(context) do
        [{:end_of_stream, :output}]
      else
        []
      end

    {actions, %{state | live_queue: new_live_queue}}
  end

  @impl true
  def handle_process(
        Pad.ref(:input, pad_id),
        buffer,
        _context,
        %{live_queue: live_queue} = state
      ) do
    {:ok, new_live_queue} = LiveQueue.add_buffer(pad_id, buffer, live_queue)

    {[], %{state | live_queue: new_live_queue}}
  end

  @impl true
  def handle_tick(_timer_id, _context, state) do
    {payload, state} = mix(Membrane.Time.milliseconds(100), state)
    {[buffer: {:output, %Buffer{payload: payload}}], state}
  end

  @impl true
  def handle_stream_format(_pad, stream_format, _context, %{stream_format: nil} = state) do
    state = %{state | stream_format: stream_format}
    mixer_state = initialize_mixer_state(stream_format, state)

    {[stream_format: {:output, stream_format}, redemand: :output],
     %{state | mixer_state: mixer_state}}
  end

  defp initialize_mixer_state(nil, _state), do: nil

  defp initialize_mixer_state(stream_format, state) do
    mixer_module =
      if state.prevent_clipping do
        if state.native_mixer, do: NativeAdder, else: ClipPreventingAdder
      else
        Adder
      end

    mixer_module.init(stream_format)
  end

  defp mix(duration, %{live_queue: live_queue} = state) do
    {payloads, new_live_queue} = LiveQueue.get_audio(duration, live_queue)
    payloads = Enum.map(payloads, fn {_audio_id, payload} -> payload end)
    {payload, state} = mix_payloads(payloads, state)
    {payload, %{state | live_queue: new_live_queue}}
  end

  defp all_streams_ended?(%{pads: pads}) do
    pads
    |> Enum.filter(fn {pad_name, _info} -> pad_name != :output end)
    |> Enum.map(fn {_pad, %{end_of_stream?: end_of_stream?}} -> end_of_stream? end)
    |> Enum.all?()
  end

  defp mix_payloads(payloads, %{mixer_state: %module{} = mixer_state} = state) do
    {payload, mixer_state} = module.mix(payloads, mixer_state)
    state = %{state | mixer_state: mixer_state}
    {payload, state}
  end
end
