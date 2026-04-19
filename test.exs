Mix.install([
  {:local_cluster, "~> 2.0"}
])

LocalCluster.start()

defmodule Foo do
end

IO.puts("foo")
