#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#                    Version 2, December 2004
#
#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
#
#  0. You just DO WHAT THE FUCK YOU WANT TO.

defmodule Socket.Port do
  @moduledoc """
  This module wraps local running program using `Port`.

  ## Options

  When creating a socket you can pass a series of options to use for it.

  * `:as` sets the kind of value returned by recv, either `:binary` or `:list`,
    the default is `:binary`
  * `:packet` see `inet:setopts`
  * `:size` sets the max length of the packet body, see `inet:setopts`
  * `:env` provides a map of environment variables for the subprocess

  ## Examples

      client = Socket.Port.open!("cat", packet: :line)

      client |> Socket.Stream.send!("hi!\n")
      client |> Socket.Stream.recv!()
      client |> Socket.Stream.close()

  """
  require Logger

  use Socket.Helpers
  require Record

  defstruct [:port, :owner]
  @opaque t :: %Socket.Port{port: port(), owner: pid()}

  @doc """
  Return a proper error string for the given code or nil if it can't be
  converted.
  """
  @spec error(term) :: String.t()
  def error(code) do
    case :inet.format_error(code) do
      ~c"unknown POSIX error" ->
        nil

      message ->
        message |> to_string
    end
  end

  @doc """
  Create a Port based on the given command.
  """
  @spec open(binary() | list()) ::
          {:ok, t} | {:error, Socket.Error.t()}
  def open(cmd) do
    open(cmd, [])
  end

  @spec open(binary() | list(), Keyword.t()) ::
          {:ok, t} | {:error, Socket.Error.t()}
  def open(cmd, options) when is_binary(cmd) do
    port = Port.open({:spawn, cmd}, arguments(options) ++ [:exit_status, :use_stdio])
    {:ok, %Socket.Port{port: port, owner: self()}}
  end

  def open([cmd | args], options) do
    port =
      Port.open(
        {:spawn_executable, cmd},
        arguments(options) ++ [{:args, args}, :exit_status, :use_stdio]
      )

    {:ok, %Socket.Port{port: port, owner: self()}}
  end

  @doc """
  Create a Port based on the given command, raising if
  an error occurs.
  """
  @spec open!(binary() | list()) :: t | no_return
  defbang(open(cmd))

  @doc """
  Create a Port based on the given command and options, raising if
  an error occurs.
  """
  @spec open!(binary() | list(), Keyword.t()) :: t | no_return
  defbang(open(cmd, options))

  @doc """
  Convert Port options to `:erlang.open_port` compatible arguments.
  """
  @spec arguments(Keyword.t()) :: list
  def arguments(options) do
    options =
      options
      |> Keyword.put_new(:as, :binary)
      |> Keyword.put_new(:size, 1024)
      |> Keyword.put_new(:packet, :raw)

    {local, _global} =
      Enum.split_with(options, fn
        {:as, _} -> true
        {:packet, _} -> true
        {:size, _} -> true
        {:env, _} -> true
        _ -> false
      end)

    Enum.flat_map(local, fn
      {:env, env} when is_map(env) ->
        [
          {:env,
           Enum.map(env, fn {k, v} ->
             k = if is_binary(k), do: String.to_charlist(k), else: k
             v = if is_binary(v), do: String.to_charlist(v), else: v
             {k, v}
           end)}
        ]

      {:as, :binary} ->
        [:binary]

      {:as, :list} ->
        [:list]

      {:size, _size} ->
        []

      {:packet, :line} ->
        [{:line, Keyword.fetch!(options, :size)}]

      {:packet, :raw} ->
        [:stream]

      {:packet, size} when size in [1, 2, 4] ->
        [{:packet, size}]
    end)
  end
end
