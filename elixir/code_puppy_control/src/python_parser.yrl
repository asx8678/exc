Nonterminals
  program statements statement simple_stmt compound_stmt
  function_def async_function_def class_def import_stmt
  parameters parameter
  decorator decorators
  return_type
  type_expr type_contents type_arg
  import_names
  .

Terminals
  def class import from as pass return identifier
  async await self true false none
  if else elif while for in try except finally
  with yield break continue
  global nonlocal and or not is
  '(' ')' '[' ']' '{' '}' ':' ',' '@' newline
  '->' '**' '*' '+' '-' '/' '//' '%' '=' '==' '!=' '<' '>' '<=' '>=' '.'
  '|' '&' '~' '^' '<<' '>>'
  string integer float
  .

Rootsymbol program.

% Handle empty input (returns empty AST)
program -> '$empty' : [].
program -> statements : '$1'.
program -> statements newline : '$1'.

% Statements can be on a single line or span multiple lines
statements -> statement : ['$1'].
statements -> statement statements : ['$1' | '$2'].

% A statement can be various things we care about or things we skip
statement -> compound_stmt : '$1'.
statement -> compound_stmt newline : '$1'.
statement -> import_stmt : '$1'.
statement -> import_stmt newline : '$1'.
statement -> simple_stmt : skip.
statement -> simple_stmt newline : skip.
statement -> newline : skip.
statement -> decorators compound_stmt : add_decorators('$1', '$2').
statement -> decorators compound_stmt newline : add_decorators('$1', '$2').

% Simple statements we skip (control flow, etc.)
simple_stmt -> pass : skip.
simple_stmt -> return : skip.
simple_stmt -> break : skip.
simple_stmt -> continue : skip.
simple_stmt -> yield : skip.
simple_stmt -> if : skip.
simple_stmt -> else : skip.
simple_stmt -> elif : skip.
simple_stmt -> while : skip.
simple_stmt -> for : skip.
simple_stmt -> in : skip.
simple_stmt -> try : skip.
simple_stmt -> except : skip.
simple_stmt -> finally : skip.
simple_stmt -> with : skip.
simple_stmt -> async : skip.
simple_stmt -> await : skip.
simple_stmt -> as : skip.
simple_stmt -> true : skip.
simple_stmt -> false : skip.
simple_stmt -> none : skip.
simple_stmt -> and : skip.
simple_stmt -> or : skip.
simple_stmt -> not : skip.
simple_stmt -> is : skip.
simple_stmt -> global identifier : skip.
simple_stmt -> nonlocal identifier : skip.
simple_stmt -> self : skip.
simple_stmt -> identifier : skip.
simple_stmt -> string : skip.
simple_stmt -> integer : skip.
simple_stmt -> float : skip.
simple_stmt -> '(' : skip.
simple_stmt -> ')' : skip.
simple_stmt -> '[' : skip.
simple_stmt -> ']' : skip.
simple_stmt -> '{' : skip.
simple_stmt -> '}' : skip.
simple_stmt -> ':' : skip.
simple_stmt -> ',' : skip.
simple_stmt -> '@' : skip.
simple_stmt -> '->' : skip.
simple_stmt -> '**' : skip.
simple_stmt -> '*' : skip.
simple_stmt -> '+' : skip.
simple_stmt -> '-' : skip.
simple_stmt -> '/' : skip.
simple_stmt -> '//' : skip.
simple_stmt -> '%' : skip.
simple_stmt -> '=' : skip.
simple_stmt -> '==' : skip.
simple_stmt -> '!=' : skip.
simple_stmt -> '<' : skip.
simple_stmt -> '>' : skip.
simple_stmt -> '<=' : skip.
simple_stmt -> '>=' : skip.
simple_stmt -> '.' : skip.
simple_stmt -> '|' : skip.
simple_stmt -> '&' : skip.
simple_stmt -> '~' : skip.
simple_stmt -> '^' : skip.
simple_stmt -> '<<' : skip.
simple_stmt -> '>>' : skip.

% Compound statements - these are what we extract
compound_stmt -> function_def : '$1'.
compound_stmt -> async_function_def : '$1'.
compound_stmt -> class_def : '$1'.

% Function definitions with optional return type annotation
% We handle simple return types (just identifier) and complex ones (nested brackets)
function_def -> def identifier '(' parameters ')' return_type ':' :
    {function, line('$1'), unwrap('$2'), '$4', '$6'}.
function_def -> def identifier '(' ')' return_type ':' :
    {function, line('$1'), unwrap('$2'), [], '$5'}.

% Async function definitions with optional return type
async_function_def -> async def identifier '(' parameters ')' return_type ':' :
    {function, line('$1'), unwrap('$3'), '$5', {async, '$7'}}.
async_function_def -> async def identifier '(' ')' return_type ':' :
    {function, line('$1'), unwrap('$3'), [], {async, '$6'}}.

% Return type annotation - simplified, only extract base type name
return_type -> '->' type_expr : '$2'.
return_type -> '$empty' : nil.

% Type expression - handles nested generic types
% Simple case: just identifier
type_expr -> identifier : unwrap('$1').
% Type can also be a literal like None, True, False
type_expr -> none : "None".
type_expr -> true : "True".
type_expr -> false : "False".
% Generic type with possible nested generics: Foo[Bar] or Foo[Bar[Baz]]
type_expr -> identifier '[' type_contents ']' : unwrap('$1').
% Empty brackets (edge case)
type_expr -> identifier '[' ']' : unwrap('$1').

% Type contents - handles comma-separated type arguments and nested brackets
% We just extract the outer type name and skip the rest
type_contents -> type_arg : nil.
type_contents -> type_arg ',' type_contents : nil.

% A single type argument - can be simple or generic
type_arg -> identifier : nil.
type_arg -> identifier '[' type_contents ']' : nil.
type_arg -> ']' : nil.  % Error recovery

% Class definitions
class_def -> class identifier ':' :
    {class, line('$1'), unwrap('$2'), [], nil}.
class_def -> class identifier '(' ')' ':' :
    {class, line('$1'), unwrap('$2'), [], nil}.
class_def -> class identifier '(' parameters ')' ':' :
    {class, line('$1'), unwrap('$2'), extract_param_names('$4'), nil}.

% Import statements
import_stmt -> import identifier :
    {import, line('$1'), unwrap('$2'), nil}.
import_stmt -> import identifier as identifier :
    {import, line('$1'), unwrap('$2'), unwrap('$4')}.
import_stmt -> from identifier import import_names :
    {from_import, line('$1'), unwrap('$2'), '$4'}.

% Handle comma-separated import names - extract the first, skip the rest
import_names -> identifier : unwrap('$1').
import_names -> identifier ',' import_names : unwrap('$1').

% Decorators
decorators -> decorator : ['$1'].
decorators -> decorator decorators : ['$1' | '$2'].

decorator -> '@' identifier newline :
    {decorator, line('$1'), unwrap('$2'), []}.
decorator -> '@' identifier '(' ')' newline :
    {decorator, line('$1'), unwrap('$2'), []}.

% Parameters in function/class definitions
parameters -> parameter : ['$1'].
parameters -> parameter ',' parameters : ['$1' | '$3'].

% Parameter can have type annotation: name or name: type
parameter -> identifier : {unwrap('$1'), nil}.
parameter -> identifier ':' identifier : {unwrap('$1'), unwrap('$3')}.
parameter -> self : {"self", nil}.
parameter -> self ':' identifier : {"self", unwrap('$3')}.

Erlang code.

line({_, Line}) -> Line;
line({_, Line, _}) -> Line.

unwrap({_, _, V}) -> V;
unwrap({_, V}) -> V.

% Extract just the names from {Name, Type} tuples
extract_param_names([]) -> [];
extract_param_names([{Name, _} | Rest]) -> [Name | extract_param_names(Rest)].

% Add decorators to class/function AST nodes
add_decorators(Decorators, {function, Line, Name, Params, Anno}) ->
    {function, Line, Name, Params, Anno, Decorators};
add_decorators(Decorators, {class, Line, Name, Params, nil}) ->
    {class, Line, Name, Params, nil, Decorators};
add_decorators(_Decorators, Node) ->
    % Fallback: if node doesn't match expected format, return as-is
    Node.
