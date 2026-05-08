%%-----------------------------------------------------------------------------
%%% @doc TypeScript Lexer for CodePuppyControl
%%%
%%% This is a Leex-generated lexer for tokenizing TypeScript source code.
%%% It extends the JavaScript lexer with TypeScript-specific keywords:
%%%
%%%   - Interface declarations
%%%   - Type aliases
%%%   - Enums
%%%   - Namespaces/modules
%%%   - Access modifiers (public, private, protected, readonly)
%%%   - Abstract classes
%%%   - Implements clause
%%%   - Declare keyword for ambient declarations
%%%
%%% Generated module: :typescript_lexer
%%%-----------------------------------------------------------------------------]

Definitions.

% Whitespace and line breaks
WHITESPACE = [\s\t]+
NEWLINE = \n|\r\n

% Comments
SINGLE_COMMENT = //[^\n]*
MULTI_COMMENT = /\*([^*]|\*[^/])*\*/

% String literals
STRING_DOUBLE = "([^\\"]|\\.)*"
STRING_SINGLE = '([^\\']|\\.)*'
STRING = {STRING_DOUBLE}|{STRING_SINGLE}

% Template literals (backtick strings)
TEMPLATE = `([^`\\]|\\.)*`

% Numbers
INTEGER = [0-9]+
FLOAT = [0-9]+\.[0-9]+([eE][+-]?[0-9]+)?
HEX = 0[xX][0-9a-fA-F]+
BINARY = 0[bB][01]+
OCTAL = 0[oO][0-7]+

% Identifiers
IDENTIFIER = [a-zA-Z_$][a-zA-Z0-9_$]*

% Regular expressions (simplified - context-sensitive in real JS)
REGEX_BODY = ([^\\/\n]|\\.)+
REGEX_FLAGS = [gimsuy]*
REGEX = /{REGEX_BODY}/{REGEX_FLAGS}

Rules.

% Skip whitespace and comments
{WHITESPACE} : skip_token.
{NEWLINE} : {token, {newline, TokenLine}}.
{SINGLE_COMMENT} : skip_token.
{MULTI_COMMENT} : skip_token.

% String literals
{STRING} : {token, {string, TokenLine, TokenChars}}.
{TEMPLATE} : {token, {template_string, TokenLine, TokenChars}}.

% Keywords - declarations (JavaScript + TypeScript)
function : {token, {function, TokenLine}}.
class : {token, {class, TokenLine}}.
const : {token, {const, TokenLine}}.
let : {token, {'let', TokenLine}}.
var : {token, {'var', TokenLine}}.

% TypeScript-specific keywords - type declarations
interface : {token, {interface, TokenLine}}.
type : {token, {'type', TokenLine}}.
enum : {token, {enum, TokenLine}}.
namespace : {token, {namespace, TokenLine}}.
module : {token, {module_token, TokenLine}}.
declare : {token, {declare, TokenLine}}.
abstract : {token, {abstract, TokenLine}}.
implements : {token, {implements, TokenLine}}.
extends : {token, {extends_token, TokenLine}}.

% TypeScript-specific keywords - access modifiers
readonly : {token, {readonly, TokenLine}}.
private : {token, {private, TokenLine}}.
public : {token, {public, TokenLine}}.
protected : {token, {protected, TokenLine}}.
static : {token, {static_token, TokenLine}}.

% Keywords - modules
import : {token, {import, TokenLine}}.
export : {token, {export, TokenLine}}.
default : {token, {default, TokenLine}}.
from : {token, {from, TokenLine}}.
as : {token, {as, TokenLine}}.

% Keywords - control flow
if : {token, {'if', TokenLine}}.
else : {token, {'else', TokenLine}}.
for : {token, {'for', TokenLine}}.
while : {token, {'while', TokenLine}}.
do : {token, {do_token, TokenLine}}.
switch : {token, {switch, TokenLine}}.
case : {token, {case_token, TokenLine}}.
break : {token, {break_token, TokenLine}}.
continue : {token, {continue_token, TokenLine}}.
return : {token, {return, TokenLine}}.
try : {token, {try_token, TokenLine}}.
catch : {token, {catch_token, TokenLine}}.
finally : {token, {finally_token, TokenLine}}.
throw : {token, {throw_token, TokenLine}}.
with : {token, {with_token, TokenLine}}.

% Keywords - async
async : {token, {async, TokenLine}}.
await : {token, {await, TokenLine}}.

% Keywords - values
true : {token, {true_token, TokenLine}}.
false : {token, {false_token, TokenLine}}.
null : {token, {null_token, TokenLine}}.
undefined : {token, {undefined_token, TokenLine}}.
this : {token, {this_token, TokenLine}}.
super : {token, {super_token, TokenLine}}.
new : {token, {new_token, TokenLine}}.
delete : {token, {delete_token, TokenLine}}.
typeof : {token, {typeof_token, TokenLine}}.
instanceof : {token, {instanceof_token, TokenLine}}.
in : {token, {in_token, TokenLine}}.
of : {token, {of_token, TokenLine}}.

% Keywords - other
void : {token, {void_token, TokenLine}}.
debugger : {token, {debugger_token, TokenLine}}.
get : {token, {get_token, TokenLine}}.
set : {token, {set_token, TokenLine}}.
yield : {token, {yield_token, TokenLine}}.

% Identifiers (must come after keywords)
{IDENTIFIER} : {token, {identifier, TokenLine, TokenChars}}.

% Numbers (check order: hex/binary/octal first, then float, then integer)
{HEX} : {token, {integer, TokenLine, hex_to_int(TokenChars)}}.
{BINARY} : {token, {integer, TokenLine, binary_to_int(TokenChars)}}.
{OCTAL} : {token, {integer, TokenLine, octal_to_int(TokenChars)}}.
{FLOAT} : {token, {float, TokenLine, list_to_float(TokenChars)}}.
{INTEGER} : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.

% Operators - assignment and compound
= : {token, {assign, TokenLine}}.
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
>>>= : {token, {urshift_assign, TokenLine}}.
\*\*= : {token, {exp_assign, TokenLine}}.
&&= : {token, {and_assign, TokenLine}}.
\|\|= : {token, {or_assign, TokenLine}}.
\?\?= : {token, {nullish_assign, TokenLine}}.

% Operators - arithmetic
\+ : {token, {plus, TokenLine}}.
- : {token, {minus, TokenLine}}.
\* : {token, {star, TokenLine}}.
/ : {token, {slash, TokenLine}}.
% : {token, {percent, TokenLine}}.
\*\* : {token, {exp, TokenLine}}.
\+\+ : {token, {increment, TokenLine}}.
-- : {token, {decrement, TokenLine}}.

% Operators - comparison
== : {token, {eq, TokenLine}}.
!= : {token, {ne, TokenLine}}.
=== : {token, {seq, TokenLine}}.
!== : {token, {sne, TokenLine}}.
< : {token, {lt, TokenLine}}.
> : {token, {gt, TokenLine}}.
<= : {token, {le, TokenLine}}.
>= : {token, {ge, TokenLine}}.

% Operators - logical
&& : {token, {and_op, TokenLine}}.
\|\| : {token, {or_op, TokenLine}}.
! : {token, {bang, TokenLine}}.
\?\? : {token, {nullish, TokenLine}}.

% Operators - bitwise
& : {token, {bitand, TokenLine}}.
\| : {token, {bitor, TokenLine}}.
\^ : {token, {bitxor, TokenLine}}.
~ : {token, {bitnot, TokenLine}}.
<< : {token, {lshift, TokenLine}}.
>> : {token, {rshift, TokenLine}}.
>>> : {token, {urshift, TokenLine}}.

% Operators - other
=> : {token, {arrow, TokenLine}}.
\.\.\. : {token, {ellipsis, TokenLine}}.
\? : {token, {question, TokenLine}}.
: : {token, {colon, TokenLine}}.
\. : {token, {dot, TokenLine}}.
\# : {token, {hash, TokenLine}}.

% Delimiters
\( : {token, {lparen, TokenLine}}.
\) : {token, {rparen, TokenLine}}.
\{ : {token, {lbrace, TokenLine}}.
\} : {token, {rbrace, TokenLine}}.
\[ : {token, {lbracket, TokenLine}}.
\] : {token, {rbracket, TokenLine}}.
; : {token, {semicolon, TokenLine}}.
, : {token, {comma, TokenLine}}.

% Regular expressions (context-sensitive - simplified)
{REGEX} : {token, {regex, TokenLine, TokenChars}}.

Erlang code.

%%% Helper functions for number parsing

%% @doc Convert hex string to integer
hex_to_int([$0, $x | Hex]) -> list_to_integer(Hex, 16);
hex_to_int([$0, $X | Hex]) -> list_to_integer(Hex, 16).

%% @doc Convert binary string to integer
binary_to_int([$0, $b | Bin]) -> list_to_integer(Bin, 2);
binary_to_int([$0, $B | Bin]) -> list_to_integer(Bin, 2).

%% @doc Convert octal string to integer
octal_to_int([$0, $o | Oct]) -> list_to_integer(Oct, 8);
octal_to_int([$0, $O | Oct]) -> list_to_integer(Oct, 8).