Definitions.

WHITESPACE = [\s\t]+
NEWLINE = \n
COMMENT = #[^\n]*
TRIPLE_QUOTE = """([^"]|"[^"]|""[^"])*"""
TRIPLE_SINGLE = '''([^']|'[^']|''[^'])*'''
STRING = "([^"\\]|\\.)*"
SSTRING = '([^'\\]|\\.)*'
INTEGER = [0-9]+
FLOAT = [0-9]+\.[0-9]+([eE][+-]?[0-9]+)?
IDENTIFIER = [a-zA-Z_][a-zA-Z0-9_]*

Rules.

{WHITESPACE} : skip_token.
{NEWLINE} : {token, {newline, TokenLine}}.
{COMMENT} : skip_token.
\r\n : {token, {newline, TokenLine}}.
\r : {token, {newline, TokenLine}}.
{TRIPLE_QUOTE} : {token, {string, TokenLine, TokenChars}}.
{TRIPLE_SINGLE} : {token, {string, TokenLine, TokenChars}}.
{STRING} : {token, {string, TokenLine, TokenChars}}.
{SSTRING} : {token, {string, TokenLine, TokenChars}}.

% Keywords (must be listed before IDENTIFIER)
def : {token, {'def', TokenLine}}.
class : {token, {'class', TokenLine}}.
import : {token, {'import', TokenLine}}.
from : {token, {'from', TokenLine}}.
as : {token, {'as', TokenLine}}.
return : {token, {'return', TokenLine}}.
if : {token, {'if', TokenLine}}.
else : {token, {'else', TokenLine}}.
elif : {token, {'elif', TokenLine}}.
while : {token, {'while', TokenLine}}.
for : {token, {'for', TokenLine}}.
in : {token, {'in', TokenLine}}.
async : {token, {'async', TokenLine}}.
await : {token, {'await', TokenLine}}.
with : {token, {'with', TokenLine}}.
try : {token, {'try', TokenLine}}.
except : {token, {'except', TokenLine}}.
finally : {token, {'finally', TokenLine}}.
raise : {token, {'raise', TokenLine}}.
assert : {token, {'assert', TokenLine}}.
lambda : {token, {'lambda', TokenLine}}.
yield : {token, {'yield', TokenLine}}.
pass : {token, {'pass', TokenLine}}.
break : {token, {'break', TokenLine}}.
continue : {token, {'continue', TokenLine}}.
global : {token, {'global', TokenLine}}.
nonlocal : {token, {'nonlocal', TokenLine}}.
True : {token, {'true', TokenLine}}.
False : {token, {'false', TokenLine}}.
None : {token, {'none', TokenLine}}.
and : {token, {'and', TokenLine}}.
or : {token, {'or', TokenLine}}.
not : {token, {'not', TokenLine}}.
is : {token, {'is', TokenLine}}.
self : {token, {'self', TokenLine}}.

{IDENTIFIER} : {token, {identifier, TokenLine, TokenChars}}.
{INTEGER} : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.
{FLOAT} : {token, {float, TokenLine, list_to_float(TokenChars)}}.

% Operators and delimiters (longer patterns first for compound operators)
\*\*\= : {token, {'**=', TokenLine}}.
\*\* : {token, {'**', TokenLine}}.
\*\= : {token, {'*=', TokenLine}}.
\+\= : {token, {'+=', TokenLine}}.
\-\= : {token, {'-=', TokenLine}}.
\/\= : {token, {'/=', TokenLine}}.
\/\/\= : {token, {'//=', TokenLine}}.
%\= : {token, {'%=', TokenLine}}.
\=\= : {token, {'==', TokenLine}}.
!\= : {token, {'!=', TokenLine}}.
<\= : {token, {'<=', TokenLine}}.
>\= : {token, {'>=', TokenLine}}.
<< : {token, {'<<', TokenLine}}.
>> : {token, {'>>', TokenLine}}.
\/\/ : {token, {'//', TokenLine}}.
\-\> : {token, {'->', TokenLine}}.
\( : {token, {'(', TokenLine}}.
\) : {token, {')', TokenLine}}.
\[ : {token, {'[', TokenLine}}.
\] : {token, {']', TokenLine}}.
\{ : {token, {'{', TokenLine}}.
\} : {token, {'}', TokenLine}}.
: : {token, {':', TokenLine}}.
; : {token, {';', TokenLine}}.
, : {token, {',', TokenLine}}.
\. : {token, {'.', TokenLine}}.
\+ : {token, {'+', TokenLine}}.
\- : {token, {'-', TokenLine}}.
\* : {token, {'*', TokenLine}}.
/ : {token, {'/', TokenLine}}.
% : {token, {'%', TokenLine}}.
\= : {token, {'=', TokenLine}}.
< : {token, {'<', TokenLine}}.
> : {token, {'>', TokenLine}}.
@ : {token, {'@', TokenLine}}.
\| : {token, {'|', TokenLine}}.
& : {token, {'&', TokenLine}}.
~ : {token, {'~', TokenLine}}.
\^ : {token, {'^', TokenLine}}.

Erlang code.
