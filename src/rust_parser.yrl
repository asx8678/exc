%%-----------------------------------------------------------------------------
%% @doc Rust Parser for CodePuppyControl
%%-----------------------------------------------------------------------------

Nonterminals
  program items item newlines
  fn_decl struct_decl enum_decl impl_block trait_decl mod_decl
  use_stmt type_alias const_decl static_decl
  use_path
  parameters parameter
  field_decl struct_fields tuple_types type_expr
  enum_variants enum_variant
  block_start block_end
  trait_items trait_method_decl
  .

Terminals
  fn pub struct enum impl trait mod use type const static
  where for self self_capital super crate unsafe extern async
  mut
  identifier
  '(' ')' '{' '}' '[' ']' ',' ';' ':' '<' '>' '&'
  arrow fat_arrow path_sep
  assign
  integer
  newline
  .

Rootsymbol program.

%% Program structure
program -> '$empty' : [].
program -> items : '$1'.

%% Handle newlines between items
items -> item : ['$1'].
items -> item newlines : ['$1'].
items -> item newlines items : ['$1' | '$3'].
items -> newlines items : '$2'.
items -> newlines : [].

newlines -> newline : ok.
newlines -> newline newlines : ok.

%% Block helpers with optional newlines
block_start -> '{' : '$1'.
block_start -> '{' newlines : '$1'.

block_end -> '}' : '$1'.
block_end -> newlines '}' : '$2'.


%% Top-level items
item -> fn_decl : '$1'.
item -> struct_decl : '$1'.
item -> enum_decl : '$1'.
item -> impl_block : '$1'.
item -> trait_decl : '$1'.
item -> mod_decl : '$1'.
item -> use_stmt : '$1'.
item -> type_alias : '$1'.
item -> const_decl : '$1'.
item -> static_decl : '$1'.

%% Function declarations
fn_decl -> fn identifier '(' ')' '{' '}' :
    {function, line('$1'), unwrap('$2'), [], [], false}.
fn_decl -> fn identifier '(' parameters ')' '{' '}' :
    {function, line('$1'), unwrap('$2'), '$4', [], false}.
fn_decl -> fn identifier '(' ')' arrow type_expr '{' '}' :
    {function, line('$1'), unwrap('$2'), [], [], false}.
fn_decl -> fn identifier '(' parameters ')' arrow type_expr '{' '}' :
    {function, line('$1'), unwrap('$2'), '$4', [], false}.
fn_decl -> pub fn identifier '(' ')' '{' '}' :
    {function, line('$2'), unwrap('$3'), [], [pub], false}.
fn_decl -> pub fn identifier '(' parameters ')' '{' '}' :
    {function, line('$2'), unwrap('$3'), '$5', [], false}.
fn_decl -> pub fn identifier '(' ')' arrow type_expr '{' '}' :
    {function, line('$2'), unwrap('$3'), [], [pub], false}.
fn_decl -> pub fn identifier '(' parameters ')' arrow type_expr '{' '}' :
    {function, line('$2'), unwrap('$3'), '$5', [pub], false}.
fn_decl -> async fn identifier '(' ')' '{' '}' :
    {async_function, line('$2'), unwrap('$3'), [], [], false}.
fn_decl -> pub async fn identifier '(' ')' '{' '}' :
    {async_function, line('$3'), unwrap('$4'), [], [pub], false}.
fn_decl -> const fn identifier '(' ')' '{' '}' :
    {const_function, line('$2'), unwrap('$3'), [], [], false}.

%% Struct declarations with block handling
struct_decl -> struct identifier block_start block_end :
    {struct, line('$1'), unwrap('$2'), []}.
struct_decl -> struct identifier block_start struct_fields block_end :
    {struct, line('$1'), unwrap('$2'), []}.
struct_decl -> pub struct identifier block_start block_end :
    {struct, line('$2'), unwrap('$3'), [pub]}.
struct_decl -> pub struct identifier block_start struct_fields block_end :
    {struct, line('$2'), unwrap('$3'), [pub]}.
struct_decl -> struct identifier ';' :
    {struct, line('$1'), unwrap('$2'), []}.
struct_decl -> pub struct identifier ';' :
    {struct, line('$2'), unwrap('$3'), [pub]}.
struct_decl -> struct identifier '(' ')' ';' :
    {struct, line('$1'), unwrap('$2'), []}.
struct_decl -> pub struct identifier '(' ')' ';' :
    {struct, line('$2'), unwrap('$3'), [pub]}.
struct_decl -> struct identifier '(' tuple_types ')' ';' :
    {struct, line('$1'), unwrap('$2'), []}.
struct_decl -> pub struct identifier '(' tuple_types ')' ';' :
    {struct, line('$2'), unwrap('$3'), [pub]}.

%% Tuple types
tuple_types -> identifier : skip.
tuple_types -> identifier ',' tuple_types : skip.
tuple_types -> identifier '<' identifier '>' : skip.
tuple_types -> identifier '<' identifier '>' ',' tuple_types : skip.

%% Field declaration helper
field_decl -> identifier ':' type_expr : skip.

%% Struct fields with newlines
struct_fields -> field_decl : skip.
struct_fields -> field_decl ',' : skip.
struct_fields -> field_decl ',' struct_fields : skip.
struct_fields -> field_decl ',' newlines struct_fields : skip.
struct_fields -> field_decl ',' newlines : skip.

%% Type expression for generics and references
type_expr -> identifier : unwrap('$1').
type_expr -> identifier '<' type_expr '>' : {generic, unwrap('$1'), '$3'}.
type_expr -> identifier '<' type_expr ',' type_expr '>' : {generic, unwrap('$1'), ['$3', '$5']}.
type_expr -> '&' identifier : {ref, unwrap('$2')}.
type_expr -> '&' mut identifier : {ref_mut, unwrap('$3')}.
type_expr -> '&' identifier '<' type_expr '>' : {ref, {generic, unwrap('$2'), '$4'}}.
type_expr -> self_capital : self.
type_expr -> '&' self_capital : {ref, self}.
type_expr -> '&' mut self_capital : {ref_mut, self}.

%% Enum declarations
enum_decl -> enum identifier block_start block_end :
    {enum, line('$1'), unwrap('$2'), []}.
enum_decl -> pub enum identifier block_start block_end :
    {enum, line('$2'), unwrap('$3'), [pub]}.
enum_decl -> enum identifier block_start enum_variants block_end :
    {enum, line('$1'), unwrap('$2'), []}.
enum_decl -> pub enum identifier block_start enum_variants block_end :
    {enum, line('$2'), unwrap('$3'), [pub]}.

%% Enum variants with newlines
enum_variants -> enum_variant : skip.
enum_variants -> enum_variant ',' : skip.
enum_variants -> enum_variant ',' enum_variants : skip.
enum_variants -> enum_variant ',' newlines enum_variants : skip.
enum_variants -> enum_variant ',' newlines : skip.

enum_variant -> identifier : skip.
enum_variant -> identifier '(' ')' : skip.
enum_variant -> identifier '(' parameters ')' : skip.
enum_variant -> identifier block_start block_end : skip.

%% Impl blocks
impl_block -> impl identifier '{' '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '{' newlines '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '{' items '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '{' items newlines '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '{' newlines items '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '{' newlines items newlines '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier for identifier '{' '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$4')}.
impl_block -> impl identifier for identifier '{' newlines '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$4')}.
impl_block -> impl identifier for identifier '{' items '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$4')}.
impl_block -> impl identifier for identifier '{' items newlines '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$4')}.
impl_block -> impl identifier for identifier '{' newlines items '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$4')}.
impl_block -> impl identifier for identifier '{' newlines items newlines '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$4')}.
impl_block -> impl identifier '<' '>' '{' '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '<' '>' '{' newlines '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '<' '>' '{' items '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '<' '>' '{' items newlines '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '<' '>' '{' newlines items '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '<' '>' '{' newlines items newlines '}' :
    {impl, line('$1'), unwrap('$2'), nil}.
impl_block -> impl identifier '<' '>' for identifier '{' '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$5')}.
impl_block -> impl identifier '<' '>' for identifier '{' newlines '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$5')}.
impl_block -> impl identifier '<' '>' for identifier '{' items '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$5')}.
impl_block -> impl identifier '<' '>' for identifier '{' items newlines '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$5')}.
impl_block -> impl identifier '<' '>' for identifier '{' newlines items '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$5')}.
impl_block -> impl identifier '<' '>' for identifier '{' newlines items newlines '}' :
    {impl, line('$1'), unwrap('$2'), unwrap('$5')}.

%% Trait declarations
trait_decl -> trait identifier '{' '}' :
    {trait, line('$1'), unwrap('$2'), []}.
trait_decl -> trait identifier '{' newlines '}' :
    {trait, line('$1'), unwrap('$2'), []}.
trait_decl -> trait identifier '{' trait_items '}' :
    {trait, line('$1'), unwrap('$2'), []}.
trait_decl -> trait identifier '{' trait_items newlines '}' :
    {trait, line('$1'), unwrap('$2'), []}.
trait_decl -> trait identifier '{' newlines trait_items '}' :
    {trait, line('$1'), unwrap('$2'), []}.
trait_decl -> trait identifier '{' newlines trait_items newlines '}' :
    {trait, line('$1'), unwrap('$2'), []}.
trait_decl -> pub trait identifier '{' '}' :
    {trait, line('$2'), unwrap('$3'), [pub]}.
trait_decl -> pub trait identifier '{' newlines '}' :
    {trait, line('$2'), unwrap('$3'), [pub]}.
trait_decl -> pub trait identifier '{' trait_items '}' :
    {trait, line('$2'), unwrap('$3'), [pub]}.
trait_decl -> pub trait identifier '{' trait_items newlines '}' :
    {trait, line('$2'), unwrap('$3'), [pub]}.
trait_decl -> pub trait identifier '{' newlines trait_items '}' :
    {trait, line('$2'), unwrap('$3'), [pub]}.
trait_decl -> pub trait identifier '{' newlines trait_items newlines '}' :
    {trait, line('$2'), unwrap('$3'), [pub]}.
trait_decl -> unsafe trait identifier '{' '}' :
    {trait, line('$2'), unwrap('$3'), [unsafe]}.
trait_decl -> unsafe trait identifier '{' newlines '}' :
    {trait, line('$2'), unwrap('$3'), [unsafe]}.
trait_decl -> unsafe trait identifier '{' trait_items '}' :
    {trait, line('$2'), unwrap('$3'), [unsafe]}.
trait_decl -> unsafe trait identifier '{' trait_items newlines '}' :
    {trait, line('$2'), unwrap('$3'), [unsafe]}.
trait_decl -> unsafe trait identifier '{' newlines trait_items '}' :
    {trait, line('$2'), unwrap('$3'), [unsafe]}.
trait_decl -> unsafe trait identifier '{' newlines trait_items newlines '}' :
    {trait, line('$2'), unwrap('$3'), [unsafe]}.
trait_decl -> pub unsafe trait identifier '{' '}' :
    {trait, line('$3'), unwrap('$4'), [pub, unsafe]}.
trait_decl -> pub unsafe trait identifier '{' newlines '}' :
    {trait, line('$3'), unwrap('$4'), [pub, unsafe]}.
trait_decl -> pub unsafe trait identifier '{' trait_items '}' :
    {trait, line('$3'), unwrap('$4'), [pub, unsafe]}.
trait_decl -> pub unsafe trait identifier '{' trait_items newlines '}' :
    {trait, line('$3'), unwrap('$4'), [pub, unsafe]}.
trait_decl -> pub unsafe trait identifier '{' newlines trait_items '}' :
    {trait, line('$3'), unwrap('$4'), [pub, unsafe]}.
trait_decl -> pub unsafe trait identifier '{' newlines trait_items newlines '}' :
    {trait, line('$3'), unwrap('$4'), [pub, unsafe]}.

%% Trait items (trait methods end with semicolon, not body)
trait_items -> trait_method_decl : ['$1'].
trait_items -> trait_method_decl newlines : ['$1'].
trait_items -> trait_method_decl newlines trait_items : ['$1' | '$3'].
trait_items -> newlines trait_items : '$2'.
trait_items -> newlines : [].

%% Trait method declarations (without body, ends with semicolon)
trait_method_decl -> fn identifier '(' ')' ';' :
    {function, line('$1'), unwrap('$2'), [], [], false}.
trait_method_decl -> fn identifier '(' parameters ')' ';' :
    {function, line('$1'), unwrap('$2'), '$4', [], false}.
trait_method_decl -> fn identifier '(' ')' arrow type_expr ';' :
    {function, line('$1'), unwrap('$2'), [], [], false}.
trait_method_decl -> fn identifier '(' parameters ')' arrow type_expr ';' :
    {function, line('$1'), unwrap('$2'), '$4', [], false}.
trait_method_decl -> async fn identifier '(' ')' ';' :
    {async_function, line('$2'), unwrap('$3'), [], [], false}.
trait_method_decl -> async fn identifier '(' parameters ')' ';' :
    {async_function, line('$2'), unwrap('$3'), '$5', [], false}.

%% Module declarations
mod_decl -> mod identifier block_start block_end :
    {mod, line('$1'), unwrap('$2'), []}.
mod_decl -> pub mod identifier block_start block_end :
    {mod, line('$2'), unwrap('$3'), [pub]}.
mod_decl -> mod identifier ';' :
    {mod_file, line('$1'), unwrap('$2'), []}.
mod_decl -> pub mod identifier ';' :
    {mod_file, line('$2'), unwrap('$3'), [pub]}.

%% Use statements
use_stmt -> use use_path ';' :
    {use, line('$1'), '$2'}.

use_path -> identifier : unwrap('$1').
use_path -> self : self.
use_path -> crate : crate.
use_path -> super : super.
use_path -> identifier path_sep use_path : cons_path(unwrap('$1'), '$3').

%% Type aliases
type_alias -> type identifier assign type_expr ';' :
    {type_alias, line('$1'), unwrap('$2'), '$4'}.
type_alias -> type identifier '<' identifier '>' assign type_expr ';' :
    {type_alias, line('$1'), {generic, unwrap('$2'), unwrap('$4')}, '$7'}.
type_alias -> pub type identifier assign type_expr ';' :
    {type_alias, line('$2'), unwrap('$3'), '$5', [pub]}.
type_alias -> pub type identifier '<' identifier '>' assign type_expr ';' :
    {type_alias, line('$2'), {generic, unwrap('$3'), unwrap('$5')}, '$8', [pub]}.

%% Constant declarations
const_decl -> const identifier ':' identifier assign integer ';' :
    {const, line('$1'), unwrap('$2'), unwrap('$4'), []}.
const_decl -> const identifier ':' identifier assign identifier ';' :
    {const, line('$1'), unwrap('$2'), unwrap('$4'), []}.
const_decl -> pub const identifier ':' identifier assign integer ';' :
    {const, line('$2'), unwrap('$3'), unwrap('$5'), [pub]}.
const_decl -> pub const identifier ':' identifier assign identifier ';' :
    {const, line('$2'), unwrap('$3'), unwrap('$5'), [pub]}.

%% Static declarations
static_decl -> static identifier ':' identifier assign integer ';' :
    {static, line('$1'), unwrap('$2'), unwrap('$4'), []}.
static_decl -> static identifier ':' identifier assign identifier ';' :
    {static, line('$1'), unwrap('$2'), unwrap('$4'), []}.
static_decl -> static mut identifier ':' identifier assign integer ';' :
    {static, line('$1'), unwrap('$3'), unwrap('$5'), [mut]}.
static_decl -> static mut identifier ':' identifier assign identifier ';' :
    {static, line('$1'), unwrap('$3'), unwrap('$5'), [mut]}.

%% Parameters
parameters -> parameter : ['$1'].
parameters -> parameter ',' parameters : ['$1' | '$3'].

parameter -> identifier ':' type_expr : unwrap('$1').
parameter -> identifier : unwrap('$1').
parameter -> '&' identifier : unwrap('$2').
parameter -> '&' mut identifier : unwrap('$3').
parameter -> '&' self : self.
parameter -> '&' mut self : self.

Erlang code.

line({_, Line}) -> Line;
line({_, Line, _}) -> Line.

unwrap({_, _, V}) -> V;
unwrap({_, V}) -> V.

cons_path(First, Rest) when is_list(Rest) -> [First | Rest];
cons_path(First, Rest) -> [First, Rest].
