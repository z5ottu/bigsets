%%% @author Russell Brown <russelldb@basho.com>
%%% @copyright (C) 2016, Russell Brown
%%% @doc
%%% stolen from bloom.erl and hashtree.erl
%%% @end
%%% Created : 29 Jul 2016 by Russell Brown <russelldb@basho.com>

-module(bigset_bitarray).

-export([new/1, set/2, to_list/1, get/2, member/2, set_all/2, unset/2, size/1, from_list/1, to_binary/1]).

-define(W, 64). %% why is the word size 27? Why not 24? or 128?

-type bit() :: 0 | 1.
-type bit_array() :: array:array(bit()).

%%%===================================================================
%%% bitarray
%%%===================================================================

-spec new(integer()) -> bit_array().
new(N) -> array:new([{size, (N-1) div ?W + 1}, {default, 0}, {fixed, false}]).

-spec set(integer(), bit_array()) -> bit_array().
set(I, A) ->
    AI = I div ?W,
    V = array:get(AI, A),
    V1 = V bor (1 bsl (I rem ?W)),
    array:set(AI, V1, A).

-spec unset(pos_integer(), bit_array()) -> bit_array().
unset(I, A) ->
    AI = I div ?W,
    V = array:get(AI, A),
    V1 = V bor (1 bsr (I rem ?W)),
    array:set(AI, V1, A).

-spec set_all([pos_integer()], bit_array()) -> bit_array().
set_all(Ints, A) ->
    lists:foldl(fun(I, Acc) ->
                        set(I, Acc)
                end,
                A,
                Ints).

-spec get(integer(), bit_array()) -> boolean().
get(I, A) ->
    AI = I div ?W,
    V = array:get(AI, A),
    V band (1 bsl (I rem ?W)) =/= 0.

-spec size(bit_array()) -> pos_integer().
size(A) ->
    array:sparse_foldl(fun(I, V, Acc) ->
                              cnt(V, I * ?W, Acc)
                      end,
                      0,
                      A).

-spec member(pos_integer(), bit_array()) -> boolean().
member(I, A) ->
    get(I, A).

-spec to_list(bit_array()) -> [integer()].
to_list(A) ->
    lists:reverse(
      array:sparse_foldl(fun(I, V, Acc) ->
                                 expand(V, I * ?W, Acc)
                         end, [], A)).

from_list(L) ->
    set_all(L, new(lists:max(L))).

%% Convert bit vector into list of integers, with optional offset.
%% expand(2#01, 0, []) -> [0]
%% expand(2#10, 0, []) -> [1]
%% expand(2#1101, 0,   []) -> [3,2,0]
%% expand(2#1101, 1,   []) -> [4,3,1]
%% expand(2#1101, 10,  []) -> [13,12,10]
%% expand(2#1101, 100, []) -> [103,102,100]
expand(0, _, Acc) ->
    Acc;
expand(V, N, Acc) ->
    Acc2 =
        case (V band 1) of
            1 ->
                [N|Acc];
            0 ->
                Acc
        end,
    expand(V bsr 1, N+1, Acc2).

cnt(0, _, Acc) ->
    Acc;
cnt(V, N, Acc) ->
    Acc2 =
        case (V band 1) of
            1 ->
                Acc +1;
            0 ->
                Acc
        end,
    cnt(V bsr 1, N+1, Acc2).

to_binary(A) ->
    array:sparse_foldl(fun(I, V, Acc) ->
                               [{I, V} | Acc]
                       end,
                       <<>>,
                       A).

%% Hamming weight/population count, stolen from the mighty Greg Burd
%% (ex-Basho!)  https://gist.github.com/gburd/4955104

%% count(0) -> 0;
%% count(X)
%%   when is_integer(X), X > 0, X < 16#FFFFFFFF ->
%%     ((c4(X) bsr 16) + c4(X)) band 16#0000FFFF.
%% c1(V) -> V - ((V bsr 1) band 16#55555555).
%% c2(V) -> ((c1(V) bsr 2) band 16#33333333) + (c1(V) band 16#33333333).
%% c3(V) -> ((c2(V) bsr 4) + c2(V)) band 16#0F0F0F0F.
%% c4(V) -> ((c3(V) bsr 8) + c3(V)) band 16#00FF00FF.

