defmodule Efsql.Tui.Help do
  @moduledoc """
  The help page content. efsql speaks a small dialect of SQL with a few
  constructions that have no standard equivalent — the primary key
  placeholder `_`, versionstamp partitions — so the help page doubles as
  the reference for them.

  `lines/0` returns `{style, text}` segments, the same shape the rest of
  the views produce.
  """

  @doc "Help content as renderable lines."
  def lines() do
    Enum.flat_map(sections(), fn {title, body} ->
      [[{:head, " " <> title}]] ++ Enum.map(body, &render/1) ++ [[]]
    end)
  end

  defp render({:sql, text}), do: [{:accent, "   " <> text}]
  defp render({:note, text}), do: [{:dim, "     " <> text}]
  defp render(text), do: [{:none, "   " <> text}]

  defp sections() do
    [
      {"Shape of a query",
       [
         {:sql, "select id, name from users where name = 'Alice' limit 10;"},
         "efsql is read-only: select only, no insert, update or delete.",
         "Unqualified tables use the tenant you activated in the navigator.",
         {:sql, "select * from tenant.users;"},
         {:sql, "select * from storage_id.tenant.users;"},
         {:note, "the trailing semicolon is optional"}
       ]},
      {"The primary key is _",
       [
         "There is no schema, so the primary key has no name in SQL.",
         "Write it as _ and efsql reads it as a key lookup or key range.",
         {:sql, "select * from users where _ = 'u0001';"},
         {:sql, "select * from users where _ > 'u0010' and _ < 'u0020';"},
         {:sql, "select * from users where _ in ('u0001', 'u0002');"},
         {:note, "one _ constraint per query; order by _ is not supported"},
         {:note, "to sort by the key, use its field name: order by id"}
       ]},
      {"Versionstamp keys and partitions",
       [
         "Versionstamp keys are tuples, so their literals are tuples too.",
         "Scan every row in one partition with * as the versionstamp:",
         {:sql, "select * from sessions where _ = ('u0006', *);"},
         "Or name a single versionstamp by its integer:",
         {:sql, "select * from sessions where _ = ('u0006', 42);"},
         {:note, "a versionstamp renders as #Versionstamp<...> in results"}
       ]},
      {"Filtering",
       [
         {:sql, "where name = 'Alice'          = > >= < <="},
         {:sql, "where age between 30 and 40   inclusive both ends"},
         {:sql, "where name like 'Al%'         % and _ wildcards"},
         {:sql, "where name not like 'A%'"},
         {:sql, "where status in ('paid', 'shipped')"},
         {:sql, "where city = 'Osaka' and age > 40"},
         "Literals: 'text', 42, 1.5, true, false, null.",
         {:note, "or is not supported; conditions combine with and only"},
         {:note, "a null field matches no comparison, like in SQL"}
       ]},
      {"Ordering and limits",
       [
         {:sql, "select id, name from users order by name desc limit 20;"},
         {:sql, "select id from users order by city asc, name desc;"},
         {:note, "efsql sorts after reading unless an index can serve the order"}
       ]},
      {"How a query runs",
       [
         "Constraints an index or the key can answer are pushed to",
         "FoundationDB; anything left over is applied to the rows here.",
         "So any query works, but some read more of the table than others.",
         {:sql, "\\plan"},
         {:note, "toggles the plan: the FDB call, then the local steps"}
       ]},
      {"Commands and keys",
       [
         {:sql, "\\?          this help          \\plan   toggle plan"},
         {:sql, "\\set limit N  default row limit"},
         "?  help          t  tenants        q  query editor",
         "r  resample      Enter  open/run   Esc  back",
         "Tab  complete, or with empty input jump to results",
         "↑↓ move or history   ^D quit   Esc cancels a running query",
         "",
         "Scrolling here and in the inspector:",
         {:sql, "Space / b   page down / up      g / G   top / bottom"},
         {:sql, "PgDn / PgUp page down / up      ↑ ↓     line by line"},
         {:note, "in the inspector, Tab moves focus between fields and value"}
       ]}
    ]
  end
end
