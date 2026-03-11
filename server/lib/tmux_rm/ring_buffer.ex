defmodule TmuxRm.RingBuffer do
  @moduledoc """
  Circular byte buffer for storing terminal output.

  Uses a list of binaries with a total byte count. On `read/1`, concatenates
  via `IO.iodata_to_binary/1`. On `append/2`, trims from the front if total
  exceeds capacity.
  """

  defstruct [:capacity, :size, :chunks]

  @type t :: %__MODULE__{
          capacity: pos_integer(),
          size: non_neg_integer(),
          chunks: :queue.queue(binary())
        }

  @doc "Create a new ring buffer with the given byte capacity."
  @spec new(pos_integer()) :: t()
  def new(capacity \\ nil) do
    min_size = Application.get_env(:tmux_rm, :ring_buffer_min_size, 524_288)
    max_size = Application.get_env(:tmux_rm, :ring_buffer_max_size, 8_388_608)
    default_size = Application.get_env(:tmux_rm, :ring_buffer_default_size, 2_097_152)

    capacity = capacity || default_size
    capacity = capacity |> max(min_size) |> min(max_size)

    %__MODULE__{
      capacity: capacity,
      size: 0,
      chunks: :queue.new()
    }
  end

  @doc "Append binary data to the buffer, dropping oldest data if over capacity."
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = buf, <<>>), do: buf

  def append(%__MODULE__{} = buf, data) when is_binary(data) do
    data_size = byte_size(data)

    # If the data itself exceeds capacity, take only the tail
    data =
      if data_size > buf.capacity do
        binary_part(data, data_size - buf.capacity, buf.capacity)
      else
        data
      end

    data_size = byte_size(data)

    new_chunks = :queue.in(data, buf.chunks)
    new_size = buf.size + data_size

    trim(%__MODULE__{buf | chunks: new_chunks, size: new_size})
  end

  @doc "Read all buffered data as a single contiguous binary."
  @spec read(t()) :: binary()
  def read(%__MODULE__{size: 0}), do: <<>>

  def read(%__MODULE__{chunks: chunks}) do
    chunks
    |> :queue.to_list()
    |> IO.iodata_to_binary()
  end

  @doc "Return the current byte count in the buffer."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "Clear the buffer contents."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = buf) do
    %__MODULE__{buf | size: 0, chunks: :queue.new()}
  end

  # Trim oldest chunks until size <= capacity
  defp trim(%__MODULE__{size: size, capacity: capacity} = buf) when size <= capacity, do: buf

  defp trim(%__MODULE__{chunks: chunks, size: size, capacity: capacity} = buf) do
    case :queue.out(chunks) do
      {{:value, chunk}, rest} ->
        chunk_size = byte_size(chunk)
        new_size = size - chunk_size

        if new_size <= capacity do
          # If removing the whole chunk drops below capacity,
          # we need to keep the tail of this chunk
          overshoot = size - capacity
          keep = chunk_size - overshoot

          if keep > 0 do
            kept = binary_part(chunk, overshoot, keep)
            new_chunks = :queue.in_r(kept, rest)
            %__MODULE__{buf | chunks: new_chunks, size: capacity}
          else
            trim(%__MODULE__{buf | chunks: rest, size: new_size})
          end
        else
          trim(%__MODULE__{buf | chunks: rest, size: new_size})
        end

      {:empty, _} ->
        %__MODULE__{buf | size: 0, chunks: :queue.new()}
    end
  end
end
