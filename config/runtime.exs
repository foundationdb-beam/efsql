import Config

if v = System.get_env("FDB_CLUSTER_FILE") do
  config :efsql, Efsql.Repo, cluster_file: v
end

if v = System.get_env("EFSQL_STORAGE_ID") do
  config :efsql, Efsql.Repo, storage_id: v
end
