%%-----------------------------------------------------------------------------
%% @doc Rust Lexer for CodePuppyControl
%%
%% This is a Leex-generated lexer for tokenizing Rust source code.
%% It supports Rust 2021 edition features including:
%%   - Keywords (fn, struct, enum, impl, trait, mod, use, etc.)
%%   - Lifetimes ('a, 'static)
%%   - Raw string literals (r#"..."#)
%%   - Numeric literals with underscores (1_000_000)
%%   - Hexadecimal, octal, and binary literals
%%   - Arrow operators (->, =>)
%%   - Path separator (::)
%%
%% Generated module: :rust_lexer
%%-----------------------------------------------------------------------------

Definitions.

% Whitespace and line breaks
WS = [\s\t]+
NL = \n|\r\n

% Comments
COMMENT = //[^\n]*
BLOCK_COMMENT = /\*([^*]|\*[^/])*\*/

% String literals
STRING_DOUBLE = "([^\\"]|\\.)*"
STRING_SINGLE = '([^\\']|\\.)*'
STRING = {STRING_DOUBLE}|{STRING_SINGLE}

% Raw string literals (simplified - r#"..."# and variants)
RAW_STRING = r#*"[^"]*"#*

% Character literals
CHAR = '([^\\']|\\.)*'

% Numbers with underscore separators
INT = [0-9][0-9_]*
FLOAT = [0-9][0-9_]*\.[0-9][0-9_]*
HEX = 0x[0-9a-fA-F_]+
OCTAL = 0o[0-7_]+
BINARY = 0b[01_]+

% Identifiers and lifetimes
ID = [a-zA-Z_][a-zA-Z0-9_]*
LIFETIME = '[a-zA-Z_][a-zA-Z0-9_]*

Rules.

% Skip whitespace and comments
{WS} : skip_token.
{NL} : {token, {newline, TokenLine}}.
{COMMENT} : skip_token.
{BLOCK_COMMENT} : skip_token.

% String literals
{STRING} : {token, {string, TokenLine, TokenChars}}.
{RAW_STRING} : {token, {raw_string, TokenLine, TokenChars}}.

% Character literals
{CHAR} : {token, {char, TokenLine, TokenChars}}.

% Lifetimes (must come before CHAR which shares the ' prefix)
{LIFETIME} : {token, {lifetime, TokenLine, tl(TokenChars)}}.

% Keywords - declarations
fn : {token, {fn, TokenLine}}.
pub : {token, {pub, TokenLine}}.
struct : {token, {struct, TokenLine}}.
enum : {token, {enum, TokenLine}}.
impl : {token, {impl, TokenLine}}.
trait : {token, {trait, TokenLine}}.
mod : {token, {mod, TokenLine}}.
use : {token, {use, TokenLine}}.
const : {token, {const, TokenLine}}.
static : {token, {static, TokenLine}}.
let : {token, {'let', TokenLine}}.
mut : {token, {'mut', TokenLine}}.
type : {token, {type, TokenLine}}.
where : {token, {where, TokenLine}}.

% Keywords - control flow
for : {token, {'for', TokenLine}}.
if : {token, {'if', TokenLine}}.
else : {token, {'else', TokenLine}}.
match : {token, {match, TokenLine}}.
while : {token, {while, TokenLine}}.
loop : {token, {loop, TokenLine}}.
break : {token, {break_token, TokenLine}}.
continue : {token, {continue_token, TokenLine}}.
return : {token, {return, TokenLine}}.

% Keywords - async
async : {token, {async, TokenLine}}.
await : {token, {await, TokenLine}}.

% Keywords - special
unsafe : {token, {unsafe, TokenLine}}.
extern : {token, {extern, TokenLine}}.
crate : {token, {crate, TokenLine}}.
self : {token, {self, TokenLine}}.
Self : {token, {self_capital, TokenLine}}.
super : {token, {super, TokenLine}}.
move : {token, {move, TokenLine}}.
ref : {token, {ref, TokenLine}}.
as : {token, {as, TokenLine}}.

% Keywords - boolean and special values
true : {token, {true_token, TokenLine}}.
false : {token, {false_token, TokenLine}}.

% Identifiers (must come after keywords)
{ID} : {token, {identifier, TokenLine, list_to_atom(TokenChars)}}.

% Numbers (check specific formats first, then generic)
{HEX} : {token, {integer, TokenLine, parse_hex(TokenChars)}}.
{OCTAL} : {token, {integer, TokenLine, parse_octal(TokenChars)}}.
{BINARY} : {token, {integer, TokenLine, parse_binary(TokenChars)}}.
{FLOAT} : {token, {float, TokenLine, parse_float(TokenChars)}}.
{INT} : {token, {integer, TokenLine, parse_int(TokenChars)}}.

% Operators - arrows and path
-> : {token, {arrow, TokenLine}}.
=> : {token, {fat_arrow, TokenLine}}.
:: : {token, {path_sep, TokenLine}}.

% Operators - compound assignment
\+= : {token, {plus_assign, TokenLine}}.
-= : {token, {minus_assign, TokenLine}}.
\*= : {token, {mult_assign, TokenLine}}.
/= : {token, {div_assign, TokenLine}}.
%= : {token, {mod_assign, TokenLine}}.
&= : {token, {bitand_assign, TokenLine}}.
\|= : {token, {bitor_assign, TokenLine}}.
\^= : {token, {bitxor_assign, TokenLine}}.
<<= : {token, {lshift_assign, TokenLine}}.
>>= : {token, {rshift_assign, TokenLine}}.

% Operators - comparison
== : {token, {eq, TokenLine}}.
!= : {token, {ne, TokenLine}}.
<= : {token, {le, TokenLine}}.
>= : {token, {ge, TokenLine}}.

% Operators - logical
&& : {token, {and_op, TokenLine}}.
\|\| : {token, {or_op, TokenLine}}.

% Operators - bitwise
<< : {token, {lshift, TokenLine}}.
>> : {token, {rshift, TokenLine}}.
& : {token, {'&', TokenLine}}.
\| : {token, {bitor, TokenLine}}.
\^ : {token, {bitxor, TokenLine}}.

% Operators - basic
\+ : {token, {plus, TokenLine}}.
- : {token, {minus, TokenLine}}.
\* : {token, {star, TokenLine}}.
/ : {token, {slash, TokenLine}}.
% : {token, {percent, TokenLine}}.
! : {token, {bang, TokenLine}}.

% Assignment
= : {token, {assign, TokenLine}}.

% Delimiters
\( : {token, {'(', TokenLine}}.
\) : {token, {')', TokenLine}}.
\{ : {token, {'{', TokenLine}}.
\} : {token, {'}', TokenLine}}.
\[ : {token, {'[', TokenLine}}.
\] : {token, {']', TokenLine}}.

% Punctuation
; : {token, {';', TokenLine}}.
, : {token, {',', TokenLine}}.
: : {token, {':', TokenLine}}.
\. : {token, {dot, TokenLine}}.
\# : {token, {'#', TokenLine}}.
\$ : {token, {'$', TokenLine}}.
\? : {token, {'?', TokenLine}}.

% Angle brackets (can be comparison or generic delimiters)
< : {token, {'<', TokenLine}}.
> : {token, {'>', TokenLine}}.

Erlang code.

%% @doc Parse integer with underscore separators
parse_int(Chars) ->
    Filtered = [C || C <- Chars, C =/= $_],
    list_to_integer(Filtered).

%% @doc Parse float with underscore separators
parse_float(Chars) ->
    Filtered = [C || C <- Chars, C =/= $_],
    list_to_float(Filtered).

%% @doc Parse hexadecimal number
parse_hex([$0, $x | Rest]) ->
    Filtered = [C || C <- Rest, C =/= $_],
    list_to_integer(Filtered, 16).

%% @doc Parse octal number
parse_octal([$0, $o | Rest]) ->
    Filtered = [C || C <- Rest, C =/= $_],
    list_to_integer(Filtered, 8).

%% @doc Parse binary number
parse_binary([$0, $b | Rest]) ->
    Filtered = [C || C <- Rest, C =/= $_],
    list_to_integer(Filtered, 2).
