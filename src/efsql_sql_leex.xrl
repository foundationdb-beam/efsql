%% Tokenizer for efsql's SQL dialect, driven by Efsql.SQL.Leex.
%%
%% Every rule returns a token carrying the matched characters, and nothing
%% is skipped: the driver needs each match to track character-accurate
%% positions (leex's own columns count UTF-8 bytes), and it finishes the
%% work leex can't express: nested block comments, Unicode letter classes,
%% and the checks on numbers and words. Tokens are
%% {Kind, Chars} with Kind one of: ws, line_comment, block_comment,
%% string, quoted, unterminated, number, bad_exponent, number_junk, word,
%% op, colon.
%%
%% Invalid UTF-8 bytes reach this lexer as UTF-16 surrogates (16#D800 +
%% byte), which decoded UTF-8 never contains and leex's column counting
%% still accepts. No positive class includes them, so outside strings and
%% comments they are illegal characters.

Definitions.

D   = [0-9]
NUM = ({D}+\.?{D}*|\.{D}+)
%% Macros are pasted in as text, so a macro used with a postfix operator
%% needs its own parentheses.
EXP = ([eE][+-]?{D}+)
WS  = [\s\t\f\v\r\n\x{A0}\x{1680}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}\x{FEFF}]
ID  = [A-Za-z_\x{80}-\x{D7FF}\x{E000}-\x{10FFFF}][A-Za-z0-9_$\x{80}-\x{D7FF}\x{E000}-\x{10FFFF}]*

Rules.

{WS}+ : {token, {ws, TokenChars}}.

-- : {token, {line_comment, TokenChars}}.
/\* : {token, {block_comment, TokenChars}}.

'([^']|'')*' : {token, {string, TokenChars}}.
"([^"]|"")*" : {token, {quoted, TokenChars}}.
'([^']|'')* : {token, {unterminated, TokenChars}}.
"([^"]|"")* : {token, {unterminated, TokenChars}}.

%% Longest match picks the number, then an exponent with no digits, then
%% a number running into another character (which the driver checks).
{NUM}{EXP}? : {token, {number, TokenChars}}.
{NUM}[eE][+-]? : {token, {bad_exponent, TokenChars}}.
{NUM}{EXP}?[A-Za-z_.0-9\x{80}-\x{D7FF}\x{E000}-\x{10FFFF}] : {token, {number_junk, TokenChars}}.

{ID} : {token, {word, TokenChars}}.

<> : {token, {op, TokenChars}}.
!= : {token, {op, TokenChars}}.
<= : {token, {op, TokenChars}}.
>= : {token, {op, TokenChars}}.
:: : {token, {op, TokenChars}}.
[=<>(),.;*+\-/%] : {token, {op, TokenChars}}.

%% A lone colon, or one followed by anything: the driver explains it.
:[\x{0}-\x{D7FF}\x{E000}-\x{10FFFF}] : {token, {colon, TokenChars}}.
: : {token, {colon, TokenChars}}.

Erlang code.
