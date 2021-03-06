%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc This module uses the riak_core_vnode_worker behavior to
%% perform different tasks asynchronously. Worth noting: it is the
%% side effects of `handle_work/3' that matter.

-module(bigset_vnode_worker).
-behaviour(riak_core_vnode_worker).

-export([init_worker/3,
         handle_work/3]).

-include_lib("bigset.hrl").

-record(state, {partition :: pos_integer(),
                batch_size :: pos_integer()}).

-define(RFOLD_OPTS, [{iterator_refresh, true}, {fold_method, streaming}]).

-type itr_res()  :: {eleveldb:itr_ref(), done | decoded_key()}.

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Initialize the worker.
init_worker(VNodeIndex, Args, _Props) ->
    BatchSize = proplists:get_value(batch_size, Args, ?DEFAULT_BATCH_SIZE),
    {ok, #state{partition=VNodeIndex, batch_size=BatchSize}}.

%% @doc Perform the asynchronous fold operation.  State is the state
%% returned from init return {noreply, State} or {reply, Reply,
%% State} the latter sends `Reply' to `Sender' using
%% riak_core_vnode:reply(Sender, Reply)
%% No need for lots of indirection here, is there?
handle_work({get, Id, DB, Set, Opts}, Sender, State) ->
    #state{partition=Partition, batch_size=BatchSize} = State,
    %% clock is first key, this actors clock key is the first key we
    %% care about. Read all the way to last element
    ClockKey = bigset_keys:clock_key(Set, Id),

    Buffer0 = bigset_fold_acc:new(Set, Sender, BatchSize, Partition, Id),

    {DoQuery, Buffer} = case requires_metadata(Opts) of
                 true ->
                     {NotFound, Clock} = bigset:get_clock(ClockKey, DB),
                     if NotFound -> {false, Buffer0};
                        true ->
                             Tombstone = bigset:get_tombstone(Set, Id, DB),
                             {true, bigset_fold_acc:add_metadata(Buffer0, Clock, Tombstone)}
                     end;
                 false ->
                     {true, Buffer0}
             end,

    FoldOpts = add_range_opts(Set, ClockKey, Opts),
    Buffer2 = add_buffer_range_opts(Buffer, FoldOpts, Opts),

    try
        AccFinal = if DoQuery -> perform_read(DB, Buffer2, FoldOpts);
                      true -> Buffer
                   end,
        bigset_fold_acc:finalise(AccFinal)
    catch
        throw:receiver_down -> ok;
        throw:stop_fold     -> ok;
        throw:_PrematureAcc  -> ok %%FinishFun(PrematureAcc)
    end,
    {noreply, State};
handle_work({handoff, DB, FoldFun, Acc0}, Sender, State) ->
    AccFinal = eleveldb:fold(DB, FoldFun, Acc0, ?FOLD_OPTS),
    riak_core_vnode:reply(Sender, AccFinal),
    {noreply, State};
handle_work({contains, Id, DB, Set, Members0}, Sender, State) ->
    #state{partition=Partition} = State,
    Members = lists:usort(Members0),

    Monitor = riak_core_vnode:monitor(Sender),
    %% clock is first key, this actors clock key is the first key we
    %% care about. Read it, and tombstone, then move iterator to first
    %% member and fold over just those entries
    %%
    %% @TODO bench folding over these rather than reads

    {NotFound, Clock} = bigset:get_clock(Set, Id, DB),
    Tombstone = bigset:get_tombstone(Set, Id, DB),

    case NotFound of
        true ->
            riak_core_vnode:reply(Sender, {not_found, Partition, {self(), Monitor}}),
            erlang:demonitor(Monitor, [flush]);
        false ->
            %% @TODO is keys_only faster?
            {ok, Iter} = eleveldb:iterator(DB, [{iterator_refresh, true}], keys_only),
            Subset = read_subset(Set, Tombstone, Members, Iter),
            riak_core_vnode:reply(Sender, {{set, Clock, Subset, done}, Partition, {self(), Monitor}}),
            erlang:demonitor(Monitor, [flush])
    end,
    {noreply, State}.

%% @priv read a subset from the bigset by folding/seeking as needed.
-spec read_subset(set(), bigset_clock:clock(), [member()], eleveldb:itr_ref()) ->
                         [{member(), dot_list()}].
read_subset(Set, Tombstone, Members, Iter) ->
    read_subset(Set, Tombstone, Members, maybe_seek(Set, Members, Iter), []).

%% @priv handle each retrieved key and decide whether to fold over
%% elements or seek to next subset element.
-spec read_subset(Set :: set(),
                  Tombstone :: bigset_clock:clock(),
                  Subset :: [member()],
                  ItrResult :: itr_res(),
                  Acc :: [{member(), dot_list()}]) ->
                         Acc :: [{member(), dot_list()}].
read_subset(_Set, _TS, [], {Iter, done}, Acc) ->
     ok = eleveldb:iterator_close(Iter),
     lists:reverse(Acc);
read_subset(Set, TS, [Member | _]=Members, {Iter, {element, Set, Member, Actor, Cnt}}, Acc) ->
    Acc2 = maybe_add_dot(TS, Member, Actor, Cnt, Acc),
    read_subset(Set, TS, Members, fold_iterator(Iter), Acc2);
read_subset(Set, TS, [_Member | Rest], {Iter, {element, Set, Other, Actor, Cnt}}, Acc) ->
    %% trim members
    Members2 = lists:dropwhile(fun(E) -> E < Other end, Rest),
    case Members2 of
        [Other | _] ->
            %% By chance the key is in the subset request, so accumulate it
            Acc2 = maybe_add_dot(TS, Other, Actor, Cnt, Acc),
            read_subset(Set, TS, Members2, fold_iterator(Iter), Acc2);
        _ ->
            %% maybe move the iterator to the next subset member
            read_subset(Set, TS, Members2, maybe_seek(Set, Members2, Iter), Acc)
    end;
read_subset(_Set, _TS, _Members, {Iter, _OtherKey}, Acc) ->
    %% we're done
    ok = eleveldb:iterator_close(Iter),
    lists:reverse(Acc).

%% @priv move the iterator one, like a fold
-spec fold_iterator(eleveldb:itr_ref()) -> itr_res().
fold_iterator(Iter) ->
    move_iterator(Iter, next).

%% @priv If there are subset members still to read, seek to the next,
%% or we're done.
-spec maybe_seek(set(), [member()], eleveldb:itr_ref()) ->
                        itr_res().
maybe_seek(_Set, [], Iter) ->
    {Iter, done};
maybe_seek(Set, Members, Iter) ->
    Key = bigset_keys:insert_member_key(Set, hd(Members), <<>>, 0),
    move_iterator(Iter, Key).

%% @priv performs the `Action' on `Iter'. Common code for handling the
%% result of move and returning an `itr_res()'
-spec move_iterator(eleveldb:itr_ref(), prefetch | key()) ->
                           itr_res().
move_iterator(Iter, Action) ->
    case eleveldb:iterator_move(Iter, Action) of
        {error, invalid_iterator} ->
            {Iter, done};
        {ok, Key} ->
            try
                {Iter, ?BS_KEYS:decode_key(Key)}
            catch C:E ->
                    lager:info("asked to decode ~p", [Key]),
                    throw({C, E})
            end
    end.

%% @priv accumulate only un-removed/tombstoned dots
-spec maybe_add_dot(Tombstone :: bigset_clock:clock(),
                    member(),
                    actor(),
                    pos_integer(),
                    Acc:: [{member(), dot_list()}]) ->
                           Acc :: [{member(), dot_list()}].
maybe_add_dot(Tombstone, Element, Actor, Cnt, Acc) ->
    case bigset_clock:seen({Actor, Cnt}, Tombstone) of
        true ->
            Acc;
        false ->
            add_dot(Element, Actor, Cnt, Acc)
    end.

%% @priv thanks to ordered traversal we can simply append the dot to
%% the existing dot list for an element, or start a new dot list.
-spec add_dot(member(), actor(), pos_integer(), [{member(), dot_list()}]) ->
                     [{member(), dot_list()}].
add_dot(Element, Actor, Cnt, [{Element, DL} | Acc]) ->
    [{Element, lists:umerge([{Actor, Cnt}], DL)} | Acc];
add_dot(Element, Actor, Cnt, Acc) ->
    [{Element, [{Actor, Cnt}]} | Acc].

%% @priv in the case that we have a range start, since we can't
%% control the iterator in a fold, we require that the set metadata is
%% read and added to the buffer. If we could control the iterator in a
%% fold we'd just fold the metadata and then seek to the range start.
-spec requires_metadata(proplists:proplist()) -> boolean().
requires_metadata(Opts) ->
    has_range_start(Opts).

-spec has_range_start(proplists:proplist()) -> boolean().
has_range_start(Opts) ->
    proplists:get_value(range_start, Opts) /= undefined.

%% @doc add any range query information pulled from the `Opts'
%% proplist to the default `?RFOLD_OPTS'. Returns a proplist of fold
%% opts.
-spec add_range_opts(set(), key(), proplists:proplist()) -> proplists:proplist().
add_range_opts(Set, ClockKey, Opts) ->
    add_range_end_opts(Set, Opts, add_range_start_opts(Set, ClockKey, Opts, ?RFOLD_OPTS)).


%% @doc add range start options pulled from `Opts' to the supplied
%% `FoldOpts'
-spec add_range_start_opts(set(),
                           key(),
                           proplists:proplist(),
                           proplists:proplist()) ->
                                  proplists:proplist().
add_range_start_opts(Set, ClockKey, Opts, FoldOpts) ->
    case proplists:get_value(range_start, Opts) of
        undefined ->
            [{start_key, ClockKey} | FoldOpts];
        Element ->
            RangeStartKey = bigset_keys:insert_member_key(Set, Element, <<>>, 0),
            maybe_add_start_inclusive(Opts, [{start_key, RangeStartKey} | FoldOpts])
    end.

%% @doc add any range query options pulled from `Opt' to the
%% `FoldOpts'
-spec add_range_end_opts(set(), proplists:proplist(), proplists:proplist()) ->
                                proplists:proplist().
add_range_end_opts(Set, Opts, FoldOpts) ->
    case proplists:get_value(range_end, Opts) of
        undefined ->
            [{end_key, bigset_keys:end_key(Set)} | FoldOpts];
        Element ->
            %% Ensure that we _can_ include this key. The call to
            %% insert_member_key/4 creates a key that actually sorts
            %% lower than the element key requested as the range
            %% end. We can't create a larger one without knowing the
            %% largest actor and largest counter, so instead, we add a
            %% byte on the end. If such a key _does_ exist, it will
            %% not be returned (same reason we add the byte.)
            BiggerElement = <<Element/binary, $0>>,
            EndKey = bigset_keys:insert_member_key(Set, BiggerElement, <<>>, 0),
            maybe_add_end_inclusive(Opts, [{end_key, EndKey} | FoldOpts])
    end.

maybe_add_start_inclusive(Opts, FoldOpts) ->
    case proplists:get_value(start_inclusive, Opts) of
        false ->
            [{start_inclusive, false} | FoldOpts];
        _ ->
            FoldOpts
    end.

maybe_add_end_inclusive(Opts, FoldOpts) ->
    case proplists:get_value(end_inclusive, Opts) of
        false ->
            [{end_inclusive, false} | FoldOpts];
        _ ->
            FoldOpts
    end.

%% @prive NOTE: this is only here because eleveldb does not expose
%% these options in the API. Paul Place _did_ add them, but only to
%% bigset folds, which we no longer use since MvM suggested the
%% keyformat change to not use the comparator. Until there is some C++
%% love, this is how we do it.
-spec add_buffer_range_opts(bigset_fold_acc:buffer(), proplists:proplist(), proplists:proplist()) ->
                                   bigset_fold_acc:buffer().
add_buffer_range_opts(Buffer, FoldOpts, Opts) ->
    Buffer1 = bigset_fold_acc:set_range_start(Buffer,
                                              proplists:get_value(start_inclusive, FoldOpts, true),
                                              proplists:get_value(range_start, Opts)),
    bigset_fold_acc:set_range_end(Buffer1,
                                  proplists:get_value(end_inclusive, FoldOpts, true),
                                  proplists:get_value(range_end, Opts)).

%% @priv common fold call
-spec perform_read(db(), bigset_fold_acc:buffer(), proplists:proplist()) ->
                          bigset_fold_acc:buffer().
perform_read(DB, Buffer, FoldOpts) ->
    try
        eleveldb:fold(DB, fun bigset_fold_acc:fold/2, Buffer, FoldOpts)
    catch
        {break, Acc} ->
            Acc
    end.


