%%-----------------------------------------------------------------------------
%% @doc JavaScript Parser for CodePuppyControl
%%
%% This is a Yecc-generated parser for extracting JavaScript declarations.
%% It supports ES6+ features including:
%%   - Function declarations (async and regular)
%%   - Class declarations
%%   - Variable declarations (const, let, var)
%%   - Arrow functions
%%   - Import/export statements
%%
%% Generated module: :javascript_parser
%%-----------------------------------------------------------------------------

Nonterminals
  program statements statement
  function_decl class_decl var_decl
  import_stmt export_stmt
  parameters parameter
  .

Terminals
  function class const 'let' var import export from default
  identifier string
  lparen rparen lbrace rbrace comma semicolon assign arrow integer float
  async
  .

Rootsymbol program.

%%-----------------------------------------------------------------------
%% Grammar Rules
%%-----------------------------------------------------------------------

program -> statements : '$1'.
program -> '$empty' : [].

statements -> statement : ['$1'].
statements -> statement statements : ['$1' | '$2'].

statement -> function_decl : '$1'.
statement -> class_decl : '$1'.
statement -> var_decl : '$1'.
statement -> import_stmt : '$1'.
statement -> export_stmt : '$1'.

%%-----------------------------------------------------------------------
%% Function Declarations
%%-----------------------------------------------------------------------

%% Regular function with parameters
function_decl -> function identifier lparen parameters rparen lbrace rbrace :
    {function, line('$1'), unwrap('$2'), '$4'}.

%% Regular function without parameters
function_decl -> function identifier lparen rparen lbrace rbrace :
    {function, line('$1'), unwrap('$2'), []}.

%% Async function without parameters
function_decl -> async function identifier lparen rparen lbrace rbrace :
    {async_function, line('$1'), unwrap('$3'), []}.

%% Async function with parameters
function_decl -> async function identifier lparen parameters rparen lbrace rbrace :
    {async_function, line('$1'), unwrap('$3'), '$5'}.

%%-----------------------------------------------------------------------
%% Class Declarations
%%-----------------------------------------------------------------------

class_decl -> class identifier lbrace rbrace :
    {class, line('$1'), unwrap('$2')}.

%%-----------------------------------------------------------------------
%% Variable Declarations (including arrow functions)
%%-----------------------------------------------------------------------

%% Simple const/let/var declarations (minimal viable) - accept any identifier as RHS
var_decl -> const identifier assign identifier :
    {const, line('$1'), unwrap('$2')}.
var_decl -> const identifier assign string :
    {const, line('$1'), unwrap('$2')}.
var_decl -> const identifier assign integer :
    {const, line('$1'), unwrap('$2')}.
var_decl -> const identifier assign float :
    {const, line('$1'), unwrap('$2')}.

var_decl -> 'let' identifier assign identifier :
    {let_decl, line('$1'), unwrap('$2')}.
var_decl -> 'let' identifier assign integer :
    {let_decl, line('$1'), unwrap('$2')}.

var_decl -> var identifier assign identifier :
    {var, line('$1'), unwrap('$2')}.
var_decl -> var identifier assign string :
    {var, line('$1'), unwrap('$2')}.

%% Arrow functions assigned to const
var_decl -> const identifier assign lparen rparen arrow lbrace rbrace :
    {arrow_fn, line('$1'), unwrap('$2'), []}.

%% Arrow function with parameters
var_decl -> const identifier assign lparen parameters rparen arrow lbrace rbrace :
    {arrow_fn, line('$1'), unwrap('$2'), '$5'}.

%%-----------------------------------------------------------------------
%% Import Statements
%%-----------------------------------------------------------------------

%% Named imports: import { a, b } from 'module'
import_stmt -> import lbrace parameters rbrace from string :
    {import, line('$1'), unwrap_string('$6'), '$3'}.

%% Default import: import React from 'react'
import_stmt -> import identifier from string :
    {import_default, line('$1'), unwrap_string('$4'), unwrap('$2')}.

%%-----------------------------------------------------------------------
%% Export Statements
%%-----------------------------------------------------------------------

%% Export default
export_stmt -> export default :
    {export_default, line('$1'), 'none'}.

%% Export default with value (identifier or string)
export_stmt -> export default identifier :
    {export_default, line('$1'), unwrap('$3')}.
export_stmt -> export default string :
    {export_default, line('$1'), unwrap_string('$3')}.

%% Named exports
export_stmt -> export function_decl :
    {export, line('$1'), '$2'}.
export_stmt -> export class_decl :
    {export, line('$1'), '$2'}.

%%-----------------------------------------------------------------------
%% Parameters (shared between functions and imports)
%%-----------------------------------------------------------------------

parameters -> parameter : ['$1'].
parameters -> parameter comma parameters : ['$1' | '$3'].

parameter -> identifier : unwrap('$1').

%%-----------------------------------------------------------------------
%% Erlang Code Section
%%-----------------------------------------------------------------------

Erlang code.

%% @doc Extract line number from token
line({_, Line}) -> Line;
line({_, Line, _}) -> Line.

%% @doc Unwrap value from token
unwrap({_, _, V}) -> V;
unwrap({_, V}) -> V;
unwrap(V) when is_atom(V) -> V.

%% @doc Unwrap string value and strip quotes
unwrap_string({_, _, V}) -> strip_quotes(V);
unwrap_string({_, V}) -> strip_quotes(V).

%% @doc Strip quotes from string literals
strip_quotes([$' | Rest]) ->
    case lists:last(Rest) of
        $' -> lists:droplast(Rest);
        _ -> Rest
    end;
strip_quotes([$" | Rest]) ->
    case lists:last(Rest) of
        $" -> lists:droplast(Rest);
        _ -> Rest
    end;
strip_quotes(V) -> V.
