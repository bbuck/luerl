%% Copyright (c) 2012 Robert Virding. All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.

%% File    : luerl_comp_env.erl
%% Author  : Robert Virding
%% Purpose : A basic LUA 5.2 compiler for Luerl.

%% Does variable and stack analysis in the compiler

-module(luerl_comp_env).

-include("luerl.hrl").

-include("luerl_comp.hrl").

-export([chunk/2]).

-import(ordsets, [is_element/2,intersection/2]).

%% Local state.
-record(st, {lfs=[],				%Variable frames
	     efs=[],				%Environment frames
	     vars=none,
	     fs=[],
	     locv=false,			%Local variables
	     locf				%Local frame
	    }).

%% chunk(St0) -> {ok,St0};
chunk(#code{code=C0}=Code, Opts) ->
    St0 = #st{},				%Local state
    {C1,_} = exp(C0, St0),
    luerl_comp:debug_print(Opts, "ce: ~p\n", [C1]),
    {ok,Code#code{code=C1}}.

%% push_env_frame(State) -> State.
%% push_env_frame(Frame, State) -> State.
%% pop_env_frame(State) -> State.
%% get_env_frame(State) -> Frame.

push_env_frame(St) -> push_env_frame(new_frame(), St).

push_env_frame(F, #st{efs=Fs}=St) ->
    St#st{efs=[F|Fs]}.

pop_env_frame(#st{efs=[_|Fs]}=St) ->
    St#st{efs=Fs}.

get_env_frame(#st{efs=[F|_]}) -> F.

%% push_env_frame(State) -> State.
%% push_env_frame(Frame, State) -> State.
%% pop_env_frame(State) -> State.
%% get_env_frame(State) -> Frame.

push_local_frame(St) -> push_local_frame(new_frame(), St).

push_local_frame(F, #st{lfs=Fs}=St) ->
    St#st{lfs=[F|Fs]}.

pop_local_frame(#st{lfs=[_|Fs]}=St) ->
    St#st{lfs=Fs}.

get_local_frame(#st{lfs=[F|_]}) -> F.

%% new_frame() -> Frame.
%% add_frame_var(Name, Frame) -> Frame.
%% find_frame_var(Name, Frame) -> {yes,Index} | no.
%% fetch_frame_var(Name, Frame) -> Index.
%%  We know frame will be tuples which we index from 1. Also Lua has
%%  the feature that every time you add a local variable you get a new
%%  version of it which shadows the old one. We handle this by keeping
%%  them in reverse order and always pushing variable to front of
%%  list.

new_frame() -> [].

add_frame_var(N, [{_,I}|_]=F) -> [{N,I+1}|F];
add_frame_var(N, []) -> [{N,1}].

find_frame_var(N, [{N,I}|_]) -> {yes,I};
find_frame_var(N, [_|F]) -> find_frame_var(N, F);
find_frame_var(_, []) -> no.

%% add_fs_var(Name, FrameStack) -> FrameStack.
%% find_fs_var(Name, FrameStack) -> {yes,Depth,Index} | no.

add_fs_var(N, [F|Fs]) -> [add_frame_var(N, F)|Fs].

find_fs_var(N, Fs) -> find_fs_var(N, Fs, 1).

find_fs_var(N, [F|Fs], D) ->
    case find_frame_var(N, F) of
	{yes,I} -> {yes,D,I};
	no -> find_fs_var(N, Fs, D+1)
    end;
find_fs_var(_, [], _) -> no.

add_var(N, St) ->
    case var_type(N, St) of
	env -> add_env_var(N, St);
	local -> add_local_var(N, St)
    end.
	    
add_env_var(N, #st{efs=Fs0}=St) ->
    Fs1 = add_fs_var(N, Fs0),
    St#st{efs=Fs1}.
	    
add_local_var(N, #st{lfs=Fs0}=St) ->
    Fs1 = add_fs_var(N, Fs0),
    St#st{lfs=Fs1}.

get_var(N, St) ->
    %% io:fwrite("gv: ~p\n", [{N,St}]),
    case var_type(N, St) of
	env -> get_env_var(N, St);
	local -> get_local_var(N, St)
    end.

get_env_var(N, #st{efs=Fs}) ->
    case find_fs_var(N, Fs) of
	{yes,D,I} -> #evar{n=N,d=D,i=I};
	no -> #gvar{n=N}
    end.

get_local_var(N, #st{lfs=Fs}) ->
    case find_fs_var(N, Fs) of
	{yes,D,I} -> #lvar{n=N,d=D,i=I};
	no -> #gvar{n=N}
    end.

var_type(N, #st{vars=#vars{fused=Fused}}) ->
    case is_element(N, Fused) of
	true -> env;
	false -> local
    end.

is_env_var(N, St) ->
    var_type(N, St) == env.

is_local_var(N, St) ->
    var_type(N, St) == local.

%% stmt(Stmts, State) -> {Stmts,State}.

stmts([S0|Ss0], St0) ->
    {S1,St1} = stmt(S0, nul, St0),
    %% io:format("ss1: ~p\n", [{Loc0,Free0,Used0}]),
    {Ss1,St2} = stmts(Ss0, St1),
    {[S1|Ss1],St2};
stmts([], St) -> {[],St}.

%% stmt(Stmt, State) -> {Stmt,State}.

stmt(#assign_stmt{}=A, _, St) -> assign_stmt(A, St);
stmt(#call_stmt{}=C, _, St) -> call_stmt(C, St);
stmt(#return_stmt{}=R, _, St) -> return_stmt(R, St);
stmt(#break_stmt{}=B, _, St) -> {B,St};
stmt(#block_stmt{}=B, _, St) -> block_stmt(B, St);
stmt(#while_stmt{}=W, _, St) -> while_stmt(W, St);
stmt(#repeat_stmt{}=R, _, St) -> repeat_stmt(R, St);
stmt(#if_stmt{}=I, _, St) -> if_stmt(I, St);
stmt(#nfor_stmt{}=F, _, St) -> numfor_stmt(F, St);
stmt(#gfor_stmt{}=F, _, St) -> genfor_stmt(F, St);
stmt(#local_assign_stmt{}=L, _, St) ->
    local_assign_stmt(L, St);
stmt(#local_fdef_stmt{}=L, _, St) ->
    local_fdef_stmt(L, St).

%% assign_stmt(Assign, State) -> {Assign,State}.

assign_stmt(#assign_stmt{vs=Vs0,es=Es0}=A, St0) ->
    {Vs1,St1} = assign_loop(Vs0, St0),
    {Es1,St2} = explist(Es0, St1),
    {A#assign_stmt{vs=Vs1,es=Es1},St2}.

assign_loop([V0|Vs0], St0) ->
    {V1,St1} = var(V0, St0),
    {Vs1,St2} = assign_loop(Vs0, St1),
    {[V1|Vs1],St2};
assign_loop([], St) -> {[],St}.

var(#dot{e=Exp0,r=Rest0}=D, St0) ->
    {Exp1,St1} = prefixexp_first(Exp0, St0),
    {Rest1,St2} = var_rest(Rest0, St1),
    {D#dot{e=Exp1,r=Rest1},St2};
var(#var{n=N}, St) ->
    V = get_var(N, St),
    {V,St}.

var_rest(#dot{e=Exp0,r=Rest0}=D, St0) ->
    {Exp1,St1} = prefixexp_element(Exp0, St0),
    {Rest1,St2} = var_rest(Rest0, St1),
    {D#dot{e=Exp1,r=Rest1},St2};
var_rest(Exp, St) -> var_last(Exp, St).

var_last(#key{k=Exp0}=K, St0) ->
    {Exp1,St1} = exp(Exp0, St0),
    {K#key{k=Exp1},St1}.

%% call_stmt(Call, State) -> {Call,State}.

call_stmt(#call_stmt{call=Exp0}=C, St0) ->
    {Exp1,St1} = exp(Exp0, St0),
    {C#call_stmt{call=Exp1},St1}.

%% return_stmt(Return, State) -> {Return,State}.

return_stmt(#return_stmt{es=Es0}=R, St0) ->
    {Es1,St1} = explist(Es0, St0),
    {R#return_stmt{es=Es1},St1}.

%% block_stmt(Block, State) -> {Block,State}.

block_stmt(#block_stmt{ss=Ss0,vars=Vars}=B, St0) ->
    Do = fun(S) -> stmts(Ss0, S) end,
    {Ss1,Lf,Ef,St1} = with_block(Do, Vars, St0),
    {B#block_stmt{ss=Ss1,lf=Lf,ef=Ef},St1}.

%% do_block(Block, State) -> {Block,State}.
%%  Do_block never returns external new variables. Fits into stmt().

do_block(#block{ss=Ss0,vars=Vars}=B, St0) ->
    Do = fun(S) -> stmts(Ss0, S) end,
    {Ss1,Lf,Ef,St1} = with_block(Do, Vars, St0),
    {B#block{ss=Ss1,lf=Lf,ef=Ef},St1}.

%% with_block(Do, Vars, State) -> {Ret,State}.
%% with_block(Do, Env, Vars, State) -> {Ret,State}.
%%  Do a block initialising/clearing frames. We always push a local
%%  frame even if it not used.

with_block(Do, #vars{local=Lo,fused=Fu}=Vars, St) ->
    EnvFrame = intersection(Lo, Fu) /= [],	%Local fused variables?
    with_block(Do, EnvFrame, Vars, St).

with_block(Do, false, Vars, #st{vars=OldVars}=St0) ->
    St1 = push_local_frame(St0),
    {Ret,St2} = Do(St1#st{vars=Vars}),
    Lf = get_local_frame(St2),
    St3 = pop_local_frame(St2),
    {Ret,Lf,[],St3#st{vars=OldVars}};
with_block(Do, true, Vars, #st{vars=OldVars}=St0) ->
    St1 = push_local_frame(St0),
    St2 = push_env_frame(St1),
    {Ret,St3} = Do(St2#st{vars=Vars}),
    Lf = get_local_frame(St3),
    Ef = get_env_frame(St3),
    St4 = pop_env_frame(St3),
    St5 = pop_local_frame(St4),
    {Ret,Lf,Ef,St5#st{vars=OldVars}}.

%% while_stmt(While, State) -> {While,State}.

while_stmt(#while_stmt{e=E0,b=B0}=W, St0) ->
    {E1,St1} = exp(E0, St0),
    {B1,St2} = do_block(B0, St1),
    {W#while_stmt{e=E1,b=B1},St2}.

%% repeat_stmt(Repeat, State) -> {Repeat,State}.

repeat_stmt(#repeat_stmt{b=B0,e=E0}=R, St0) ->
    {B1,St1} = do_block(B0, St0),
    {E1,St2} = exp(E0, St1),
    {R#repeat_stmt{b=B1,e=E1},St2}.

%% if_stmt(If, State) -> {If,State}.

if_stmt(#if_stmt{tests=Ts0,else=E0}=I, St0) ->
    {Ts1,St1} = if_tests(Ts0, St0),
    {E1,St2} = do_block(E0, St1),
    {I#if_stmt{tests=Ts1,else=E1},St2}.

if_tests([{E0,B0}|Ts0], St0) ->
    {E1,St1} = exp(E0, St0),
    {B1,St2} = do_block(B0, St1),
    {Ts1,St3} = if_tests(Ts0, St2),
    {[{E1,B1}|Ts1],St3};
if_tests([], St) -> {[],St}.

%% numfor_stmt(For, State) -> {For,State}.

numfor_stmt(#nfor_stmt{v=V0,init=I0,limit=L0,step=S0,b=B0}=F, St0) ->
    {[I1,L1,S1],St1} = explist([I0,L0,S0], St0),
    {[V1],B1,St2} = for_block([V0], B0, St1),
    {F#nfor_stmt{v=V1,init=I1,limit=L1,step=S1,b=B1},St2}.

%% genfor_stmt(For, State) -> {For,State}.

genfor_stmt(#gfor_stmt{vs=Vs0,gens=Gs0,b=B0}=F, St0) ->
    {Gs1,St1} = explist(Gs0, St0),
    {Vs1,B1,St2} = for_block(Vs0, B0, St1),
    {F#gfor_stmt{vs=Vs1,gens=Gs1,b=B1},St2}.

for_block(Vs0, #block{ss=Ss0,vars=Vars}=B, St0) ->
    Do = fun (S0) ->
		 Fun = fun (#var{n=N}, Sa) ->
			       Sb = add_var(N, Sa),
			       {get_var(N, Sb),Sb}
		       end,
		 {Vs1,S1} = lists:mapfoldl(Fun, S0, Vs0),
		 {Ss1,S2} = stmts(Ss0, S1),
		 {{Vs1,Ss1},S2}
	 end,
    {{Vs1,Ss1},Lf,Ef,St1} = with_block(Do, Vars, St0),
    {Vs1,B#block{ss=Ss1,lf=Lf,ef=Ef},St1}.

%% local_assign_stmt(Local, State) -> {Local,State}.

local_assign_stmt(#local_assign_stmt{vs=Vs0,es=Es0}=L, St0) ->
    {Es1,St1} = explist(Es0, St0),
    Fun = fun (#var{n=N}, S0) ->
		  S1 = add_var(N, S0),
		  {get_var(N, S1),S1}
	  end,
    {Vs1,St2} = lists:mapfoldl(Fun, St1, Vs0),
    {L#local_assign_stmt{vs=Vs1,es=Es1},St2}.

%% local_fdef_stmt(Local, State) -> {Local,State}.

local_fdef_stmt(#local_fdef_stmt{v=#var{n=N},f=F0}=L, St0) ->
    St1 = add_var(N, St0),
    {F1,St2} = functiondef(F0, St1),
    V1 = get_var(N, St2),
    %% io:fwrite("lf: ~p\n", [St0]),
    %% io:fwrite("lf: ~p\n", [St1]),
    %% io:fwrite("lf: ~p\n", [St2]),
    {L#local_fdef_stmt{v=V1,f=F1},St2}.

%% explist(Exprs, LocalVars, State) -> {Exprs,FreeVars,State}.
%% exp(Expr, LocalVars, State) -> {Expr,FreeVars,State}.
%%  An expression can never create new local variables.

explist([E0|Es0], St0) ->
    {E1,St1} = exp(E0, St0),
    {Es1,St2} = explist(Es0, St1),
    {[E1|Es1],St2};
explist([], St) -> {[],St}.			%No expressions at all

exp(#lit{}=L, St) -> {L,St};			%Nothing to do
exp(#fdef{}=F, St) -> functiondef(F, St);
exp(#op{as=Es0}=Op, St0) ->
    {Es1,St1} = explist(Es0, St0),
    {Op#op{as=Es1},St1};
exp(#tc{fs=Fs0}=T, St0) ->
    {Fs1,St1} = tableconstructor(Fs0, St0),
    {T#tc{fs=Fs1},St1};
exp(E, St) ->
    prefixexp(E, St).

prefixexp(#dot{e=Exp0,r=Rest0}=D, St0) ->
    {Exp1,St1} = prefixexp_first(Exp0, St0),
    {Rest1,St2} = prefixexp_rest(Rest0, St1),
    {D#dot{e=Exp1,r=Rest1},St2};
prefixexp(Exp, St) -> prefixexp_first(Exp, St).

prefixexp_first(#single{e=E0}=S, St0) ->
    {E1,St1} = exp(E0, St0),
    {S#single{e=E1},St1};
prefixexp_first(#var{n=N}, St) ->
    V = get_var(N, St),
    {V,St}.

prefixexp_rest(#dot{e=Exp0,r=Rest0}=D, St0) ->
    {Exp1,St1} = prefixexp_element(Exp0, St0),
    {Rest1,St2} = prefixexp_rest(Rest0, St1),
    {D#dot{e=Exp1,r=Rest1},St2};
prefixexp_rest(Exp, St) -> prefixexp_element(Exp, St).

prefixexp_element(#key{k=E0}=K, St0) ->
    {E1,St1} = exp(E0, St0),
    {K#key{k=E1},St1};
prefixexp_element(#fcall{as=As0}=F, St0) ->
    {As1,St1} = explist(As0, St0),
    {F#fcall{as=As1},St1};
prefixexp_element(#mcall{as=As0}=M, St0) ->
    {As1,St1} = explist(As0, St0),
    {M#mcall{as=As1},St1}.

%% functiondef(Func, State) -> {Func,State}.

functiondef(#fdef{ps=Ps0,ss=Ss0,vars=Vars}=F, St0) ->
    Do = fun (S0) ->
		 Fun = fun (#var{n=N}, Sa) ->
			       Sb = add_var(N, Sa),
			       {get_var(N, Sb),Sb}
		       end,
		 {Ps1,S1} = lists:mapfoldl(Fun, S0, Ps0),
		 {Ss1,S2} = stmts(Ss0, S1),
		 {{Ps1,Ss1},S2}
	 end,
    {{Ps1,Ss1},Lf,Ef,St1} = with_block(Do, Vars, St0),
    {F#fdef{ps=Ps1,ss=Ss1,lf=Lf,ef=Ef},St1}.

%% tableconstructor(Fields, State) -> {Fields,State}.

tableconstructor(Fs0, St0) ->
    Fun = fun (#efield{v=V0}=F, S0) ->
		  {V1,S1} = exp(V0, S0),
		  {F#efield{v=V1},S1};
	      (#kfield{k=K0,v=V0}=F, S0) ->
		  {K1,S1} = exp(K0, S0),
		  {V1,S2} = exp(V0, S1),
		  {F#kfield{k=K1,v=V1},S2}
	  end,
    {Fs1,St1} = lists:mapfoldl(Fun, St0, Fs0),
    {Fs1,St1}.
