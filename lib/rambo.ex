defmodule Rambo do
  @moduledoc File.read!("#{__DIR__}/../README.md")
             |> String.split("\n")
             |> Enum.drop(2)
             |> Enum.join("\n")

  defstruct status: 0, out: "", err: ""

  @type t :: %__MODULE__{
          status: integer(),
          out: String.t(),
          err: String.t()
        }
  @type args :: String.t() | [String.t()]
  @type result :: {:ok, t()} | {:error, t() | String.t()}

  require Mix.Tasks.Compile.Rambo

  import Mix.Tasks.Compile.Rambo, only: [platform_specific: 1]

  alias __MODULE__

  # stop compilation unless suitable binary is found
  platform_specific do
    [mac: :ok, linux: :ok, windows: :ok]
  else
    raise """
    Rambo did not ship pre-compiled binaries for your environment.
    Install the Rust compiler and add the :rambo compiler to your mix.exs
    so a binary can be prepared for you.

        def project do
          [
            compilers: [:rambo] ++ Mix.compilers()
          ]
        end

    """
  end

  @doc ~S"""
  Runs `command`.

  Executes the `command` and returns `{:ok, %Rambo{}}` or `{:error, reason}`.
  `reason` is a string if the child process failed to start, or a `%Rambo{}`
  struct if the child process started successfully but exited with a non-zero
  status.

  Multiple calls can be chained together with the `|>` pipe operator to
  simulate Unix pipes.

      Rambo.run("ls") |> Rambo.run("sort") |> Rambo.run("head")

  If any command did not exit with `0`, the rest will not be executed and the
  last executed result is returned in an `:error` tuple.

  See `run/2` or `run/3` to pass arguments or options.

  ## Examples

      iex> Rambo.run("echo")
      {:ok, %Rambo{status: 0, out: "\n", err: ""}}

  """
  @spec run(command :: String.t() | result()) :: result()
  def run(command) do
    run(command, nil, [])
  end

  @doc ~S"""
  Runs `command` with arguments or options.

  Arguments can be a string or list of strings. See `run/3` for options.

  ## Examples

      iex> Rambo.run("echo", "john")
      {:ok, %Rambo{out: "john\n"}}

      iex> Rambo.run("echo", ["-n", "john"])
      {:ok, %Rambo{out: "john"}}

      iex> Rambo.run("cat", in: "john")
      {:ok, %Rambo{out: "john"}}

  """
  @spec run(command :: String.t() | result, args_or_opts :: args() | Keyword.t()) :: result()
  def run(command, args_or_opts) do
    case command do
      {:ok, %{status: 0, out: out}} ->
        command = args_or_opts
        run(command, in: out)

      {:error, reason} ->
        {:error, reason}

      command ->
        if Keyword.keyword?(args_or_opts) do
          run(command, nil, args_or_opts)
        else
          run(command, args_or_opts, [])
        end
    end
  end

  @doc ~S"""
  Runs `command` with arguments and options.

  ## Options

    * `:in` - pipe as standard input
    * `:cd` - the directory to run the command in
    * `:env` - map or list of tuples containing environment key-value as strings

  ## Examples

      iex> Rambo.run("/bin/sh", ["-c", "echo $JOHN"], env: %{"JOHN" => "rambo"})
      {:ok, %Rambo{out: "rambo\n"}}

  """
  @spec run(command :: String.t(), args :: args(), opts :: Keyword.t()) :: result()
  def run(command, args, opts) do
    case command do
      {:ok, %{out: out}} ->
        command = args
        args_or_opts = opts

        if Keyword.keyword?(args_or_opts) do
          run(command, nil, [in: out] ++ args_or_opts)
        else
          run(command, args_or_opts, in: out)
        end

      {:error, reason} ->
        {:error, reason}

      command ->
        {stdin, opts} = Keyword.pop(opts, :in)
        {envs, opts} = Keyword.pop(opts, :env)
        {current_dir, _opts} = Keyword.pop(opts, :cd)
        executable = Mix.Tasks.Compile.Rambo.executable()

        rambo = Path.join(:code.priv_dir(:rambo), executable)
        port = Port.open({:spawn, rambo}, [:binary, :exit_status, {:packet, 4}])
        send_command(port, command)

        if args, do: send_arguments(port, args)
        if stdin, do: send_stdin(port, stdin)
        if envs, do: send_envs(port, envs)
        if current_dir, do: send_current_dir(port, current_dir)

        run_command(port)
        receive_result(port, %Rambo{})
    end
  end

  @doc false
  @spec run(result :: result(), command :: String.t(), args :: args(), opts :: Keyword.t()) ::
          result()
  def run(result, command, args, opts) do
    case result do
      {:ok, %{out: out}} -> run(command, args, [in: out] ++ opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @messages [
    :command,
    :arg,
    :stdin,
    :env,
    :current_dir,
    :error,
    :exit_status,
    :stdout,
    :stderr,
    :eot
  ]

  for {message, index} <- Enum.with_index(@messages) do
    Module.put_attribute(__MODULE__, message, <<index>>)
  end

  defp send_command(port, command) do
    Port.command(port, @command <> command)
  end

  defp send_arguments(port, args) when is_list(args) do
    for arg <- args do
      send_arguments(port, arg)
    end
  end

  defp send_arguments(port, arg) when is_binary(arg) do
    Port.command(port, @arg <> arg)
  end

  defp send_stdin(port, stdin) do
    Port.command(port, @stdin <> stdin)
  end

  defp send_envs(port, envs) do
    for {name, value} <- envs do
      Port.command(port, @env <> <<byte_size(name)::32>> <> name <> value)
    end
  end

  defp send_current_dir(port, current_dir) do
    Port.command(port, @current_dir <> current_dir)
  end

  defp run_command(port) do
    Port.command(port, @eot)
  end

  defp receive_result(port, result) do
    receive do
      {^port, {:data, @error <> message}} ->
        Port.close(port)
        {:error, message}

      {^port, {:data, @exit_status <> <<exit_status::32>>}} ->
        receive_result(port, %{result | status: exit_status})

      {^port, {:data, @stdout <> stdout}} ->
        receive_result(port, %{result | out: stdout})

      {^port, {:data, @stderr <> stderr}} ->
        receive_result(port, %{result | err: stderr})

      {^port, {:data, @eot}} ->
        Port.close(port)

        if result.status == 0 do
          {:ok, result}
        else
          {:error, result}
        end

      {^port, {:exit_status, exit_status}} ->
        {:error, "rambo exited with #{exit_status}"}
    end
  end
end