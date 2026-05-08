%%-----------------------------------------------------------------------------
%% @doc TypeScript Parser for CodePuppyControl
%%
%% This is a Yecc-generated parser for extracting TypeScript declarations.
%% It extends the JavaScript parser with TypeScript-specific syntax:
%%   - Interface declarations
%%   - Type aliases
%%   - Enum declarations
%%   - Abstract class declarations
%%   - Class with implements clause
%%   - Access modifiers on class members (basic support)
%%
%% Generated module: :typescript_parser
%%-----------------------------------------------------------------------------

Nonterminals
  program statements statement
  function_decl class_decl var_decl
  import_stmt export_stmt
  interface_decl type_alias enum_decl
  parameters parameter
  .

Terminals
  function class const 'let' var import export from default
  interface 'type' enum namespace declare abstract
  implements extends_token readonly private public protected
  identifier string integer float
  lparen rparen lbrace rbrace comma semicolon assign arrow
  async static_token
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
statement -> interface_decl : '$1'.
statement -> type_alias : '$1'.
statement -> enum_decl : '$1'.

%%-----------------------------------------------------------------------
%% Function Declarations (same as JavaScript)
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
%% Class Declarations (JavaScript + TypeScript extensions)
%%-----------------------------------------------------------------------

%% Simple class declaration
class_decl -> class identifier lbrace rbrace :
    {class, line('$1'), unwrap('$2')}.

%% Class with extends clause
class_decl -> class identifier extends_token identifier lbrace rbrace :
    {class_extends, line('$1'), unwrap('$2'), unwrap('$4')}.

%% Class with implements clause (TypeScript-specific)
class_decl -> class identifier implements identifier lbrace rbrace :
    {class_implements, line('$1'), unwrap('$2'), unwrap('$4')}.

%% Abstract class declaration (TypeScript-specific)
class_decl -> abstract class identifier lbrace rbrace :
    {abstract_class, line('$1'), unwrap('$3')}.

%%-----------------------------------------------------------------------
%% Interface Declarations (TypeScript-specific)
%%-----------------------------------------------------------------------

interface_decl -> interface identifier lbrace rbrace :
    {interface, line('$1'), unwrap('$2')}.

%%-----------------------------------------------------------------------
%% Type Alias Declarations (TypeScript-specific)
%%-----------------------------------------------------------------------

type_alias -> 'type' identifier assign identifier :
    {type_alias, line('$1'), unwrap('$2'), unwrap('$4')}.

type_alias -> 'type' identifier assign string :
    {type_alias, line('$1'), unwrap('$2'), unwrap_string('$4')}.

%%-----------------------------------------------------------------------
%% Enum Declarations (TypeScript-specific)
%%-----------------------------------------------------------------------

enum_decl -> enum identifier lbrace rbrace :
    {enum, line('$1'), unwrap('$2')}.

%%-----------------------------------------------------------------------
%% Variable Declarations (same as JavaScript)
%%-----------------------------------------------------------------------

%% Simple const/let/var declarations
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
%% Import Statements (same as JavaScript)
%%-----------------------------------------------------------------------

%% Named imports: import { a, b } from 'module'
import_stmt -> import lbrace parameters rbrace from string :
    {import, line('$1'), unwrap_string('$6'), '$3'}.

%% Default import: import React from 'react'
import_stmt -> import identifier from string :
    {import_default, line('$1'), unwrap_string('$4'), unwrap('$2')}.

%%-----------------------------------------------------------------------
%% Export Statements (same as JavaScript)
%%-----------------------------------------------------------------------

%% Export default
export_stmt -> export default :
    {export_default, line('$1')}.

%% Named exports
export_stmt -> export function_decl :
    {export, line('$1'), '$2'}.
export_stmt -> export class_decl :
    {export, line('$1'), '$2'}.

%% Export interface (TypeScript-specific)
export_stmt -> export interface_decl :
    {export, line('$1'), '$2'}.

%% Export type alias (TypeScript-specific)
export_stmt -> export type_alias :
    {export, line('$1'), '$2'}.

%% Export enum (TypeScript-specific)
export_stmt -> export enum_decl :
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