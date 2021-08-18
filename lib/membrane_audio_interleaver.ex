defmodule Membrane.AudioInterleaver do
  @moduledoc """
  Element responsible for interleaving several mono audio streams into single interleaved stream.
  All input streams should be in the same raw audio format, defined by `input_caps` option.

  Channels are interleaved in order given in `order` option - currently required, no default available.

  Each input pad should be identified with your custom id (using `via_in(Pad.ref(:input, your_example_id)` )
  """

  use Membrane.Filter
  use Bunch

  alias Membrane.AudioMixer.DoInterleave
  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw, as: Caps

  require Membrane.Logger

  def_options input_caps: [
                type: :struct,
                spec: Caps.t(),
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
              order: [
                type: :list,
                spec: [any()],
                description: """
                Order in which channels should be interleaved
                """
              ]

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    caps: Caps

  def_input_pad :input,
    mode: :pull,
    availability: :on_request,
    demand_unit: :bytes,
    caps: Caps

  @impl true
  def handle_init(%__MODULE__{} = options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        pads: %{},
        finished: false,
        channels: length(options.order)
      })

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
  def handle_prepared_to_playing(
        _context,
        %{input_caps: %Caps{} = input_caps, channels: channels} = state
      ) do
    {{:ok, caps: {:output, %Caps{input_caps | channels: channels}}}, state}
  end

  @impl true
  def handle_prepared_to_playing(_context, %{input_caps: nil} = state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(:output, size, :bytes, _context, %{channels: channels} = state) do
    do_handle_demand(div(size, channels), state)
  end

  @impl true
  def handle_demand(
        :output,
        buffers_count,
        :buffers,
        _context,
        %{frames_per_buffer: frames, input_caps: input_caps} = state
      ) do
    case input_caps do
      nil ->
        {:ok, state}

      _caps ->
        size = buffers_count * Caps.frames_to_bytes(frames, input_caps)

        do_handle_demand(size, state)
    end
  end

  @impl true
  def handle_end_of_stream(pad, _context, %{input_caps: input_caps} = state) do
    if state.finished do
      # end of stream already sent
      {:ok, state}
    else
      sample_size = Caps.sample_size(input_caps)

      state =
        case Bunch.Access.get_in(state, [:pads, pad]) do
          %{queue: queue} when byte_size(queue) < sample_size ->
            %{state | finished: true}

          _state ->
            Bunch.Access.update_in(
              state,
              [:pads, pad],
              &%{&1 | stream_ended: true}
            )
        end

      if state.finished do
        {{:ok, end_of_stream: :output}, state}
      else
        interleave_and_return(state)
      end
    end
  end

  @impl true
  def handle_event(pad, event, _context, state) do
    Membrane.Logger.debug("Received event #{inspect(event)} on pad #{inspect(pad)}")

    {:ok, state}
  end

  @impl true
  def handle_process(
        pad,
        %Buffer{payload: payload} = _buffer,
        _context,
        %{input_caps: input_caps} = state
      ) do
    if state.finished do
      {:ok, state}
    else
      {new_queue_size, state} = add_payload(payload, pad, state)

      if new_queue_size >= Caps.sample_size(input_caps) do
        interleave_and_return(state)
      else
        {{:ok, redemand: :output}, state}
      end
    end
  end

  @impl true
  def handle_caps(pad, input_caps, _context, state) do
    case state.input_caps do
      nil ->
        state = %{state | input_caps: input_caps}

        {{:ok, caps: {:output, %{input_caps | channels: state.channels}}, redemand: :output},
         state}

      ^input_caps ->
        {:ok, state}

      _invalid_caps ->
        raise(
          RuntimeError,
          "received invalid caps on pad #{inspect(pad)}, expected: #{inspect(state.input_caps)}, got: #{inspect(input_caps)}"
        )
    end
  end

  # send demand to input pads where current queue is not long enough
  defp do_handle_demand(size, %{pads: pads} = state) do
    if state.finished do
      {:ok, state}
    else
      demands =
        Enum.map(
          pads,
          fn {pad, %{queue: queue}} ->
            demand_size =
              queue
              |> byte_size()
              |> then(&max(0, size - &1))

            {:demand, {pad, demand_size}}
          end
        )

      {{:ok, demands}, state}
    end
  end

  # try to interleave channels and formulate proper element callback return message
  defp interleave_and_return(state) do
    case try_interleave(state) do
      :none -> {:ok, state}
      {:finished, {buffer, state}} -> {{:ok, buffer: buffer, end_of_stream: :output}, state}
      {:ok, {buffer, state}} -> {{:ok, buffer: buffer}, state}
    end
  end

  # interleave channels only if all queues are long enough (have at least `sample_size` size)
  defp try_interleave(%{input_caps: input_caps, pads: pads, order: order} = state) do
    sample_size = Caps.sample_size(input_caps)

    min_length =
      pads
      |> min_queue_length
      |> trunc_to_whole_samples(sample_size)

    if min_length >= sample_size do
      {payload, pads} = DoInterleave.interleave(min_length, sample_size, pads, order)
      state = %{state | pads: pads}
      buffer = {:output, %Buffer{payload: payload}}

      if any_finished?(pads, sample_size) do
        {:finished, {buffer, %{state | finished: true}}}
      else
        {:ok, {buffer, state}}
      end
    else
      :none
    end
  end

  # Returns minimum number of bytes present in all queues
  defp min_queue_length(pads) do
    pads
    |> Enum.map(fn {_pad, %{queue: queue}} -> byte_size(queue) end)
    |> Enum.min(fn -> 0 end)
  end

  # Returns the biggest multiple of `sample_size` that is not bigger than `size`
  defp trunc_to_whole_samples(size, sample_size)
       when is_integer(size) and is_integer(sample_size) do
    rest = rem(size, sample_size)
    size - rest
  end

  defp any_finished?(pads, sample_size) do
    Enum.any?(pads, fn
      {_pad, %{queue: queue, stream_ended: true}} when byte_size(queue) < sample_size -> true
      _entry -> false
    end)
  end

  # add payload to proper pad's queue
  defp add_payload(payload, pad, %{pads: pads} = state) do
    {new_queue_size, pads} =
      Bunch.Access.get_and_update_in(
        pads,
        [pad, :queue],
        &{byte_size(&1 <> payload), &1 <> payload}
      )

    {new_queue_size, %{state | pads: pads}}
  end
end
