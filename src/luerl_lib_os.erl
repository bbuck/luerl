%% Copyright (c) 2013 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : luerl_lib_os.erl
%% Author  : Robert Virding
%% Purpose : The os library for Luerl.

-module(luerl_lib_os).

-include("luerl.hrl").

-export([install/1]).

-export([process_format_str/2, process_format_str/5, format_date_part/2]).

-import(luerl_lib, [lua_error/2,badarg_error/3]).	%Shorten this

%% For `remove/2'.
-include_lib("kernel/include/file.hrl").

%% For `tmpname/2' in `luerl_lib_os'.
-define(TMPNAM_MAXTRIES, 100).
-define(TMPNAM_TEMPLATE(S), "/tmp/lua_" ++ S).

install(St) ->
    luerl_emul:alloc_table(table(), St).

table() ->
    [{<<"clock">>,#erl_func{code=fun clock/2}},
     {<<"date">>,#erl_func{code=fun date/2}},
     {<<"difftime">>,#erl_func{code=fun difftime/2}},
     {<<"execute">>,#erl_func{code=fun execute/2}},
     {<<"exit">>,#erl_func{code=fun lua_exit/2}},
     {<<"getenv">>,#erl_func{code=fun getenv/2}},
     {<<"remove">>,#erl_func{code=fun remove/2}},
     {<<"rename">>,#erl_func{code=fun rename/2}},
     {<<"time">>,#erl_func{code=fun time/2}},
     {<<"tmpname">>,#erl_func{code=fun tmpname/2}}].

getenv([<<>>|_], St) -> {[nil],St};
getenv([A|_], St) when is_binary(A) ; is_number(A) ->
    case os:getenv(luerl_lib:arg_to_list(A)) of
	Env when is_list(Env) ->
	    {[list_to_binary(Env)],St};
	false -> {[nil],St}
    end;
getenv(As, St) -> badarg_error(getenv, As, St).

%% execute([Command|_], State) -> {[Ret,Type,Stat],State}.
%%  Execute a command and get the return code. We cannot yet properly
%%  handle if our command terminated with a signal.

execute([], St) -> {true,St};                   %We have a shell
execute([A|_], St) ->
    case luerl_lib:arg_to_string(A) of
        S when is_binary(S) ->
            Opts = [{arg0,"sh"},{args,["-c", S]},
                    hide,in,eof,exit_status,use_stdio,stderr_to_stdout],
            P = open_port({spawn_executable,"/bin/sh"}, Opts),
            N = execute_handle(P),
            Ret = if N =:= 0 -> true;           %Success
                     true -> nil                %Error
                  end,
            {[Ret,<<"exit">>,N],St};
        error -> badarg_error(execute, [A], St)
    end;
execute(As, St) -> badarg_error(execute, As, St).


execute_handle(P) ->
    receive
        {P,{data,D}} ->
            %% Print stdout/stderr like Lua does.
            io:put_chars(D),
            execute_handle(P);
        {P, {exit_status,N}} ->
            %% Wait for the eof then close the port.
            receive
                {P, eof} ->
                    port_close(P),
                    N
            end
    end.

%% exit([ExitCode,CloseState|_], State) -> nil.
%%  Exit the host program. If ExitCode is true, the return code is 0;
%%  if ExitCode is false, the return code is 1; if ExitCode is a number, the
%%  return code is this number. The default value for ExitCode is true.
%% NOT IMPLEMENTED:
%%  If the optional second argument CloseState is true, it will close the Lua
%%  state before exiting.
lua_exit([], St) ->
    lua_exit([true,false], St);
lua_exit([C], St) ->
    lua_exit([C,false], St);
lua_exit([Co0|_], St) -> %% lua_exit([Co0,Cl0], St) ->
    Co1 = case luerl_lib:arg_to_number(Co0) of
              X when is_integer(X) -> X;
              error ->
                  case Co0 of
                      false -> 1;
                      true -> 0;
                      error -> badarg_error(exit, [Co0], St)
                  end
          end,

    %% Uncomment this if you need the second argument to determine whether to
    %% destroy the Lua state or not.
    %% Cl1 = case Cl0 of
    %%           true -> true;
    %%           false -> false;
    %%           _ -> badarg_error(exit, [Cl0], St)
    %%       end,

    erlang:halt(Co1).

%% tmpname([], State)
%% Faithfully recreates `tmpnam'(3) in lack of a NIF.
tmpname([_|_], St) ->
    %% Discard extra arguments.
    tmpname([], St);
tmpname([], St) ->
    Out = tmpname_try(randchar(6, []), 0),
    %% We make an empty file the programmer will have to close themselves.
    %% This is done for security reasons.
    file:write_file(Out, ""),
    {[list_to_binary(Out)],St}.

%% Support function for `tmpname/2' - generates a random filename following a
%% template.
tmpname_try(_, ?TMPNAM_MAXTRIES) ->
    %% Exhausted...
    false;
tmpname_try(A, N) ->
    case file:read_file_info(?TMPNAM_TEMPLATE(A)) of
        {error,enoent} -> ?TMPNAM_TEMPLATE(A); %% Success, at last!
        _ -> tmpname_try(randchar(6, []), N+1)
    end.

%% Support function for `tmpname_try/2'.
randchar(0, A) -> A;
randchar(N, A) -> randchar(N-1, [rand:uniform(26)+96|A]).

%% rename([Source,Destination|_], State)
%%  Renames the file or directory `Source' to `Destination'. If this function
%%  fails, it returns `nil', plus a string describing the error code and the
%%  error code. Otherwise, it returns `true'.
rename([S,D|_], St) ->
    case {luerl_lib:arg_to_string(S),
          luerl_lib:arg_to_string(D)} of
        {S1,D1} when is_binary(S1) ,
                     is_binary(D1) ->
            case file:rename(S1,D1) of
                ok -> {[true],St};
                {error,R} ->
                    #{errno := En,
                      errstr := Er} = luerl_util:errname_info(R),
                    {[nil,Er,En],St}
            end;

        %% These are for throwing a `badmatch' error on the correct argument.
        {S1,D1} when not is_binary(S1) ,
                     not is_binary(D1) ->
            badarg_error(rename, [S1,D1], St);
        {S1,D1} when not is_binary(S1) ,
                     is_binary(D1) ->
            badarg_error(rename, [S1], St);
        {S1,D1} when is_binary(S1) ,
                     not is_binary(D1) ->
            badarg_error(rename, [D1], St)
    end.

%% remove([Path|_], State)
%%  Deletes the file (or empty directory) with the given `Path'. If this
%%  function fails, it returns `nil' plus a string describing the error, and the
%%  error code. Otherwise, it returns `true'.
remove([A|_], St) ->
    case luerl_lib:arg_to_string(A) of
        A1 when is_binary(A1) ->
            %% Emulate the underlying call to `remove(3)'.
            case file:read_file_info(A1) of
                {ok,#file_info{type=T}} when T == directory ;
                                             T == regular ->
                    %% Select the corresponding function.
                    Op = if T == directory -> del_dir;
                            true -> delete
                         end,

                    case file:Op(A) of
                        ok -> {[true],St};
                        {error,R} -> {remove_geterr(R, A), St}
                    end;
                {error,R} ->
                    %% Something went wrong.
                    {remove_geterr(R, A), St}
            end;
        error -> badarg_error(remove, [A], St)
    end.

%% Utility function to get a preformatted list to return from `remove/2'.
remove_geterr(R, F) ->
    F1 = binary_to_list(F),
    #{errno := En,
      errstr := Er} = luerl_util:errname_info(R),
    [nil, list_to_binary(F1 ++ ": " ++ Er), En].

%% Time functions.

clock(As, St) ->
    Type = case As of				%Choose which we want
               [<<"runtime">>|_] -> runtime;
               _ -> wall_clock
           end,
    {Tot,_} = erlang:statistics(Type),		%Milliseconds
    {[Tot*1.0e-3],St}.

%% date([FmtStr], State)
%%  This will process the format string and return a new string with date values
%%  substitued, for example "%H:%M" will become "19:08". Refer to
%%  format_date_part/2 for details on what format characters relate to what
%%  date values.
%%  There is a special format string, "*t", which returns a table containing
%%  date information. The keys returned are sec, min, hour, day, month, year,
%%  wday (day in week), yday (day in year) and isdst.
%%  NOTE: For *t, isdst is not yet implemented.
date([<<"*t">>|_], StateIn) ->
    {{Ye, Mo, Da}, {Ho, Mi, Sec}} = calendar:local_time(),
    WeekDay = calendar:day_of_the_week({Ye, Mo, Da}),
    YearDaysStart = calendar:date_to_gregorian_days({Ye, 1, 1}),
    YearDaysEnd = calendar:date_to_gregorian_days({Ye, Mo, Da}),
    {T, StateOut} = luerl_emul:alloc_table([
                {<<"sec">>, Sec},
                {<<"min">>, Mi},
                {<<"hour">>, Ho},
                {<<"day">>, Da},
                {<<"month">>, Mo},
                {<<"year">>, Ye},
                {<<"wday">>, WeekDay rem 7},
                {<<"yday">>, YearDaysEnd-YearDaysStart+1},
                {<<"isdst">>, <<"N/I">>}
            ], StateIn),
    {[T], StateOut};
date([FmtStr | _], St) ->
    {{Ye, Mo, Da}, {Ho, Mi, Sec}} = calendar:local_time(),
    Str = process_format_str({Ye, Mo, Da, Ho, Mi, Sec}, FmtStr),
    % io_lib:fwrite("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w",
    %   [Ye, Mo, Da, Ho, Mi, Sec]),
    {[Str], St}.

process_format_str(DateParts, FmtStr) ->
    case re:run(FmtStr, "%.", [global]) of
        {match, Results} ->
            process_format_str(DateParts, FmtStr, Results, 0, []);
        _ ->
            FmtStr
    end.

process_format_str(_, FmtStr, [], LastEnd, Result) ->
    End = string:slice(FmtStr, LastEnd),
    iolist_to_binary(lists:reverse([End|Result]));
process_format_str(DateParts, FmtStr, [[{MStart, MLen}]|Rest], LastEnd, Result) ->
    Start = if
        MStart == 0 ->
            "";
        true ->
            string:slice(FmtStr, LastEnd, MStart-LastEnd)
    end,
    Char = string:slice(FmtStr, MStart+1, 1),
    FmtDatePart = format_date_part(DateParts, Char),
    process_format_str(DateParts, FmtStr, Rest, MStart+MLen, [FmtDatePart|[Start|Result]]).

%% format_date_part(DateParts, FormatDirective)
%%  Convert format directing like I into it's respective date component.
%%  a is the day of the week, abbreviated; e.g. Wed
%%  A is the day of the week, full; e.g. Wednesday
%%  H is 24-hour hour value, zero-padded.
%%  I is 12-hour hour value, zero-padded
%%  M is zero-padded minute
%%  S is zero-padded seconds
%%  j is the day of the year, 1-366
%%  w is weekday as number, 0 - 6, Sunday is 0
%%  y is the year without century, last two digits (00 - 99) e.g. 20
%%  Y is the year with century, e.g. 2020
%%  c is a locale specific date/time string (NOTE: not locale aware right now)
%%  x is a locale specific date format (NOTE: not locale aware right now)
%%  X is a locale specific time format (NOTE: not locale aware right now)
%%  Z is the time zone in abbreviated format, e.g. CST or nothing if the time
%%    zone is unknown. (NOTE: Not yet implemented)
%%  U is the week of the year assuming Sunday is the first day of the week (00 - 53)
%%  W is the week of the year assuming Monday is the first day of the week (00 - 53)
%%  % means the previous char was %, and %% -> %
format_date_part({_, _, Da, _, _, _}, <<"d">>) ->
    io_lib:fwrite("~.2.0w", [Da]);
format_date_part({_, _, _, Ho, _, _}, <<"H">>) ->
    io_lib:fwrite("~.2.0w", [Ho]);
format_date_part({_, _, _, Ho, _, _}, <<"I">>) ->
    TwHo = Ho rem 12,
    TwHo1 = if
        TwHo == 0 -> 12;
        true -> TwHo
    end,
    io_lib:fwrite("~.2.0w", [TwHo1]);
format_date_part({_, Mo, _, _, _, _}, <<"m">>) ->
    io_lib:fwrite("~.2.0w", [Mo]);
format_date_part({_, _, _, _, Mi, _}, <<"M">>) ->
    io_lib:fwrite("~.2.0w", [Mi]);
format_date_part({_, _, _, _, _, Sec}, <<"S">>) ->
    io_lib:fwrite("~.2.0w", [Sec]);
format_date_part({Ye, Mo, Da, _, _, _}, <<"a">>) ->
    Day = calendar:day_of_the_week({Ye, Mo, Da}),
    day_name(Day, true);
format_date_part({Ye, Mo, Da, _, _, _}, <<"A">>) ->
    Day = calendar:day_of_the_week({Ye, Mo, Da}),
    day_name(Day, false);
format_date_part({Ye, Mo, Da, _, _, _}, <<"w">>) ->
    Day = calendar:day_of_the_week({Ye, Mo, Da}),
    io_lib:fwrite("~w", [Day rem 7]);
format_date_part({_, Mo, _, _, _, _}, <<"b">>) ->
    month_name(Mo, true);
format_date_part({_, Mo, _, _, _, _}, <<"B">>) ->
    month_name(Mo, false);
format_date_part({Ye, Mo, Da, _, _, _}, <<"j">>) ->
    YearStart = calendar:date_to_gregorian_days({Ye, 1, 1}),
    Today = calendar:date_to_gregorian_days({Ye, Mo, Da}),
    io_lib:fwrite("~.3.0w", [Today-YearStart+1]);
format_date_part({Ye, _, _, _, _, _}, <<"y">>) ->
    io_lib:fwrite("~.2.0w", [Ye rem 100]);
format_date_part({Ye, _, _, _, _, _}, <<"Y">>) ->
    io_lib:fwrite("~w", [Ye]);
format_date_part({Ye, Mo, Da, Ho, Mi, Sec}, <<"c">>) ->
    DayNum = calendar:day_of_the_week({Ye, Mo, Da}),
    Day = day_name(DayNum, true),
    Month = month_name(Mo, true),
    io_lib:fwrite("~s ~s ~.2. w ~.2.0w:~.2.0w:~.2.0w ~w", [Day, Month, Da, Ho, Mi, Sec, Ye]);
format_date_part({Ye, Mo, Da, _, _, _}, <<"x">>) ->
    io_lib:fwrite("~.2.0w/~.2.0w/~.2.0w", [Mo, Da, Ye rem 100]);
format_date_part({_, _, _, Ho, Mi, Sec}, <<"X">>) ->
    io_lib:fwrite("~.2.0w:~.2.0w:~.2.0w", [Ho, Mi, Sec]);
format_date_part({Ye, Mo, Da, _, _, _}, <<"U">>) ->
    {_, WeekNum} = calendar:iso_week_number({Ye, Mo, Da}),
    io_lib:fwrite("~.2.0w", [WeekNum]);
format_date_part({Ye, Mo, Da, _, _, _}, <<"W">>) ->
    {_, WeekNum} = calendar:iso_week_number({Ye, Mo, Da}),
    DayNum = calendar:day_of_the_week({Ye, Mo, Da}),
    ActualWeekNum0 = case DayNum of
        % it's not Monday yet, so we don't count this new week
        7 -> WeekNum-1;
        _ -> WeekNum
    end,
    ActualWeekNum1 = if
        ActualWeekNum0 < 0 -> 0;
        true -> ActualWeekNum0
    end,
    io_lib:fwrite("~.2.0w", [ActualWeekNum1]);
format_date_part({_, _, _, Ho, _, _}, <<"p">>) when Ho < 12 ->
    "AM";
format_date_part(_, <<"p">>) ->
    "PM";
format_date_part(_, <<"%">>) ->
    "%";
format_date_part(_, Char) ->
    "%" ++ Char.

%% day_name(DayNum, Abbreviated)
%%  Convert a day number into an abbreviated/full representation.
%%  NOTE: as of now, this is not locale aware
day_name(1, true) -> "Mon";
day_name(1, false) -> "Monday";
day_name(2, true) -> "Tue";
day_name(2, false) -> "Tuesday";
day_name(3, true) -> "Wed";
day_name(3, false) -> "Wednesday";
day_name(4, true) -> "Thu";
day_name(4, false) -> "Thursday";
day_name(5, true) -> "Fri";
day_name(5, false) -> "Friday";
day_name(6, true) -> "Sat";
day_name(6, false) -> "Saturday";
day_name(7, true) -> "Sun";
day_name(7, false) -> "Sunday".

%% month_name(Month, Abbreviated)
%%  Convert a month number into an abbreviated/full representation.
%%  NOTE: as of now, this is not locale aware
month_name(1, true) -> "Jan";
month_name(1, false) -> "January";
month_name(2, true) -> "Feb";
month_name(2, false) -> "February";
month_name(3, true) -> "Mar";
month_name(3, false) -> "March";
month_name(4, true) -> "Apr";
month_name(4, false) -> "April";
month_name(5, true) -> "May";
month_name(5, false) -> "May";
month_name(6, true) -> "Jun";
month_name(6, false) -> "June";
month_name(7, true) -> "Jul";
month_name(7, false) -> "July";
month_name(8, true) -> "Aug";
month_name(8, false) -> "August";
month_name(9, true) -> "Sep";
month_name(9, false) -> "September";
month_name(10, true) -> "Oct";
month_name(10, false) -> "October";
month_name(11, true) -> "Nov";
month_name(11, false) -> "November";
month_name(12, true) -> "Dec";
month_name(12, false) -> "December".

difftime([A1,A2|_], St) ->
    {[A2-A1],St}.

time(_, St) ->					%Time since 1 Jan 1970
    {Mega,Sec,Micro} = os:timestamp(),
    {[1.0e6*Mega+Sec+Micro*1.0e-6],St}.
