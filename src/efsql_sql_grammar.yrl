%% Grammar for efsql's SQL dialect. Efsql.SQL.Parser drives it with
%% tokens from Efsql.SQL.Lexer:
%%
%%   SELECT items FROM name [WHERE expr] [GROUP BY names] [ORDER BY items]
%%     [LIMIT n] [;]
%%
%% A select item is a name or an aggregate call, `count(*)` or `sum(price)`,
%% optionally `AS alias`; which functions exist is Efsql.Parser's business.
%%
%% A token is {Category, Index, Value}, where Index is its place in the
%% token list, so an error names its token exactly. Words in the reserved
%% list (Efsql.SQL.Parser.reserved_words/0) come as their own category and
%% must match the keyword Terminals below; `time`, `timestamp`, `without`
%% and `zone` do too, but stay usable as names. Every other word is
%% `ident`. `/` and `%` have no terminal, so they are errors anywhere.
%%
%% The grammar accepts exactly the valid statements. Error messages are
%% worked out from it by the driver, which asks which tokens could have
%% come next, so a new rule needs nothing else to be explained. Actions
%% build Efsql.SQL.AST, with the statement as a tuple the driver makes a
%% struct.

Nonterminals
statement select_stmt fields field_list field table where_clause group_clause names
order_clause order_items order_item order_key aggregate limit_clause
expr or_expr and_expr not_expr predicate operand primary name
type_name type_word keyword element elements expr_list comparison.

Terminals
ident quoted string integer float
'all' 'and' 'as' 'asc' 'between' 'by' 'case' 'cast' 'cross' 'desc' 'distinct'
'else' 'end' 'except' 'false' 'from' 'full' 'group' 'having' 'ilike' 'in'
'inner' 'intersect' 'is' 'isnull' 'join' 'left' 'like' 'limit' 'not' 'notnull'
'null' 'offset' 'on' 'or' 'order' 'right' 'select' 'then' 'true' 'union'
'when' 'where' 'with'
'time' 'timestamp' 'without' 'zone'
'=' '<>' '<' '>' '<=' '>=' '::' '(' ')' ',' '.' ';' '*' '+' '-'.

Rootsymbol statement.
Endsymbol '$end'.

statement -> select_stmt : '$1'.
statement -> select_stmt ';' : '$1'.

select_stmt -> 'select' fields 'from' table where_clause group_clause order_clause limit_clause :
  {select, '$2', '$4', '$5', '$6', '$7', '$8'}.

fields -> '*' : star.
fields -> field_list : '$1'.

field_list -> field : ['$1'].
field_list -> field ',' field_list : ['$1' | '$3'].

field -> name : '$1'.
field -> aggregate : '$1'.
field -> aggregate 'as' name : setelement(4, '$1', '$3').

aggregate -> ident '(' '*' ')' : {aggregate, value('$1'), star, nil}.
aggregate -> ident '(' name ')' : {aggregate, value('$1'), '$3', nil}.

table -> name : ['$1'].
table -> name '.' name : ['$1', '$3'].
table -> name '.' name '.' name : ['$1', '$3', '$5'].

where_clause -> '$empty' : nil.
where_clause -> 'where' expr : '$2'.

group_clause -> '$empty' : [].
group_clause -> 'group' 'by' names : '$3'.

names -> name : ['$1'].
names -> name ',' names : ['$1' | '$3'].

order_clause -> '$empty' : [].
order_clause -> 'order' 'by' order_items : '$3'.

order_items -> order_item : ['$1'].
order_items -> order_item ',' order_items : ['$1' | '$3'].

order_item -> order_key : {'$1', asc}.
order_item -> order_key 'asc' : {'$1', asc}.
order_item -> order_key 'desc' : {'$1', desc}.

order_key -> name : '$1'.
order_key -> aggregate : '$1'.

limit_clause -> '$empty' : nil.
limit_clause -> 'limit' integer : value('$2').

%% Loosest first: OR, AND, NOT, then a predicate.
expr -> or_expr : '$1'.

or_expr -> or_expr 'or' and_expr : {'or', '$1', '$3'}.
or_expr -> and_expr : '$1'.

and_expr -> and_expr 'and' not_expr : {'and', '$1', '$3'}.
and_expr -> not_expr : '$1'.

not_expr -> 'not' not_expr : {'not', '$2'}.
not_expr -> predicate : '$1'.

predicate -> operand comparison operand : {compare, '$2', '$1', '$3'}.
predicate -> operand 'between' operand 'and' operand : {between, '$1', '$3', '$5', false}.
predicate -> operand 'not' 'between' operand 'and' operand : {between, '$1', '$4', '$6', true}.
predicate -> operand 'in' '(' expr_list ')' : {in, '$1', '$4', false}.
predicate -> operand 'not' 'in' '(' expr_list ')' : {in, '$1', '$5', true}.
predicate -> operand 'like' operand : {like, '$1', '$3', false}.
predicate -> operand 'not' 'like' operand : {like, '$1', '$4', true}.
predicate -> operand 'ilike' operand : {ilike, '$1', '$3', false}.
predicate -> operand 'not' 'ilike' operand : {ilike, '$1', '$4', true}.
predicate -> operand 'is' 'null' : {is_null, '$1', false}.
predicate -> operand 'is' 'not' 'null' : {is_null, '$1', true}.
predicate -> operand 'isnull' : {is_null, '$1', false}.
predicate -> operand 'notnull' : {is_null, '$1', true}.
predicate -> operand : '$1'.

comparison -> '=' : '='.
comparison -> '<>' : '<>'.
comparison -> '<' : '<'.
comparison -> '>' : '>'.
comparison -> '<=' : '<='.
comparison -> '>=' : '>='.

operand -> primary : '$1'.
operand -> operand '::' type_name : {cast, '$1', '$3'}.

primary -> string : {literal, value('$1')}.
primary -> integer : {literal, value('$1')}.
primary -> float : {literal, value('$1')}.
primary -> '-' integer : {literal, -value('$2')}.
primary -> '-' float : {literal, -value('$2')}.
primary -> '+' integer : {literal, value('$2')}.
primary -> '+' float : {literal, value('$2')}.
primary -> 'true' : {literal, true}.
primary -> 'false' : {literal, false}.
primary -> 'null' : {literal, nil}.
primary -> name : {column, '$1'}.
primary -> 'cast' '(' expr 'as' type_name ')' : {cast, '$3', '$5'}.
primary -> '(' expr ')' : '$2'.
primary -> '(' element ',' elements ')' : {tuple, ['$2' | '$4']}.

%% A tuple element may be `*`: ('partition', *).
element -> expr : '$1'.
element -> '*' : star.

elements -> element : ['$1'].
elements -> element ',' elements : ['$1' | '$3'].

expr_list -> expr : ['$1'].
expr_list -> expr ',' expr_list : ['$1' | '$3'].

%% Names: identifiers, quoted names, and the keywords that aren't reserved.
name -> ident : value('$1').
name -> quoted : value('$1').
name -> 'time' : <<"time">>.
name -> 'timestamp' : <<"timestamp">>.
name -> 'without' : <<"without">>.
name -> 'zone' : <<"zone">>.

%% A type is any word, reserved ones included, with PostgreSQL's
%% `timestamp with[out] time zone` spelled out.
type_name -> type_word : '$1'.
type_name -> 'timestamp' 'with' 'time' 'zone' : <<"timestamptz">>.
type_name -> 'timestamp' 'without' 'time' 'zone' : <<"timestamp">>.
type_name -> 'time' 'with' 'time' 'zone' : <<"timetz">>.
type_name -> 'time' 'without' 'time' 'zone' : <<"time">>.

type_word -> ident : value('$1').
type_word -> keyword : atom_to_binary(category('$1')).

keyword -> 'all' : '$1'.
keyword -> 'and' : '$1'.
keyword -> 'as' : '$1'.
keyword -> 'asc' : '$1'.
keyword -> 'between' : '$1'.
keyword -> 'by' : '$1'.
keyword -> 'case' : '$1'.
keyword -> 'cast' : '$1'.
keyword -> 'cross' : '$1'.
keyword -> 'desc' : '$1'.
keyword -> 'distinct' : '$1'.
keyword -> 'else' : '$1'.
keyword -> 'end' : '$1'.
keyword -> 'except' : '$1'.
keyword -> 'false' : '$1'.
keyword -> 'from' : '$1'.
keyword -> 'full' : '$1'.
keyword -> 'group' : '$1'.
keyword -> 'having' : '$1'.
keyword -> 'ilike' : '$1'.
keyword -> 'in' : '$1'.
keyword -> 'inner' : '$1'.
keyword -> 'intersect' : '$1'.
keyword -> 'is' : '$1'.
keyword -> 'isnull' : '$1'.
keyword -> 'join' : '$1'.
keyword -> 'left' : '$1'.
keyword -> 'like' : '$1'.
keyword -> 'limit' : '$1'.
keyword -> 'not' : '$1'.
keyword -> 'notnull' : '$1'.
keyword -> 'null' : '$1'.
keyword -> 'offset' : '$1'.
keyword -> 'on' : '$1'.
keyword -> 'or' : '$1'.
keyword -> 'order' : '$1'.
keyword -> 'right' : '$1'.
keyword -> 'select' : '$1'.
keyword -> 'then' : '$1'.
keyword -> 'true' : '$1'.
keyword -> 'union' : '$1'.
keyword -> 'when' : '$1'.
keyword -> 'where' : '$1'.
keyword -> 'with' : '$1'.
keyword -> 'time' : '$1'.
keyword -> 'timestamp' : '$1'.
keyword -> 'without' : '$1'.
keyword -> 'zone' : '$1'.

Erlang code.

value({_Category, _Location, Value}) -> Value.

category({Category, _Location, _Value}) -> Category.
