%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2000-2011. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%% We use the dynamic hashing techniques by Per-�ke Larsson as
%% described in "The Design and Implementation of Dynamic Hashing for
%% Sets and Tables in Icon" by Griswold and Townsend.  Much of the
%% terminology comes from that paper as well.

%% The segments are all of the same fixed size and we just keep
%% increasing the size of the top tuple as the table grows.  At the
%% end of the segments tuple we keep an empty segment which we use
%% when we expand the segments.  The segments are expanded by doubling
%% every time n reaches maxn instead of increasing the tuple one
%% element at a time.  It is easier and does not seem detrimental to
%% speed.  The same applies when contracting the segments.
%%
%% Note that as the order of the keys is undefined we may freely
%% reorder keys within in a bucket.

-module(sets_test).

%% Standard interface.
-export([new/0,is_set/ 1 ,size/1 ,to_list/1,from_list/ 1 ]).
-export([is_element/2,add_element/ 2 ,del_element/2 ]).
-export([union/2,union/ 1 ,intersection/2 ,intersection/1]).
-export([is_disjoint/2]).
-export([subtract/2,is_subset/ 2 ]).
-export([fold/3,filter/ 2 ]).

%% Note: mk_seg/1 must be changed too if seg_size is changed.
-define(seg_size, 16).                                                         %% slot激活的初始化个数
-define(max_seg, 32).
-define(expand_load, 5).
-define(contract_load, 3).
-define(exp_size, ?seg_size * ?expand_load ).                       %% 扩张阈值 初始值为16*5=80
-define(con_size, ?seg_size * ?contract_load ).                     %% 收缩阈值 初始值为16*3=48

%%------------------------------------------------------------------------------

-type seg()  :: tuple().
-type segs() :: tuple().

%% Define a hash set.  The default values are the standard ones.
-record(set,
            {size= 0               :: non_neg_integer(),       % Number of elements(元素的数量)
             n= ?seg_size          :: non_neg_integer(),       % Number of active slots(已经激活的的slot数量)
             maxn= ?seg_size       :: pos_integer(),    % Maximum slots(最大slots数)
             bso= ?seg_size div 2 :: non_neg_integer(),  % Buddy slot offset(最大bucket数散列表中当前允许的最大bucket数量，扩张操作需要据此判断是否要增加新的bucket区段，初始为8)
             exp_size= ?exp_size   :: non_neg_integer(),      % Size to expand at(扩张阈值 初始值为16*5=80，当字典中元素个数超过这个值时，字典需要扩展)
             con_size= ?con_size   :: non_neg_integer(),      % Size to contract at(收缩阈值 初始值为16*3=48，当字典中元素个数少于这个值时，字典需要压缩(减少slots的数量))
             empty               :: seg(),                         % Empty segment(作为扩展segs时的初始化的默认值)
             segs                :: segs()                         % Segments(Segments 所有的数据存放的地方，真正储存数量的地方,
                                                                               % 初始结构为{seg}，每经过一次扩展,seg的数量翻倍,seg的结构为{[],[],...},元组中列表的个数为?seg_size定义的大小, 这里的列表叫做bucket)
            }).
%% A declaration equivalent to the following one is hard-coded in erl_types.
%% That declaration contains hard-coded information about the #set{}
%% record and the types of its fields.  So, please make sure that any
%% changes to its structure are also propagated to erl_types.erl.
%%
%% -opaque set() :: #set{}.

%%------------------------------------------------------------------------------

%% new() -> Set
-spec new() -> set().
%% 创建一个新的set数据结构
new() ->
       Empty = mk_seg(?seg_size ),
      #set{empty = Empty , segs = {Empty }}.

%% is_set(Set) -> boolean().
%%  Return 'true' if Set is a set of elements, else 'false'.
-spec is_set( Set ) -> boolean() when
      Set :: term().
%% 判断当前结构是set结构
is_set(#set{}) -> true;

is_set(_) -> false.

%% size(Set) -> int().
%%  Return the number of elements in Set.
-spec size( Set ) -> non_neg_integer() when
      Set :: set().
%% 拿到set数据结构中的数据元素的个数
size(S) -> S#set.size.

%% to_list(Set) -> [Elem].
%%  Return the elements in Set as a list.
-spec to_list( Set ) -> List when
      Set :: set(),
      List :: [term()].
%% 将set数据结构中的数据元素全部转化为list元素
to_list(S) ->
      fold( fun (Elem , List) -> [Elem | List] end, [], S ).

%% from_list([Elem]) -> Set.
%%  Build a set from the elements in List.
-spec from_list( List ) -> Set when
      List :: [term()],
      Set :: set().
%% 通过列表创建一个新的set数据结构
from_list(L) ->
      lists:foldl( fun (E , S) -> add_element( E , S ) end, new(), L ).

%% is_element(Element, Set) -> boolean().
%%  Return 'true' if Element is an element of Set, else 'false'.
-spec is_element( Element , Set ) -> boolean() when
      Element :: term(),
      Set :: set().
%% 判断E是否是set数据结构中的元素
is_element(E, S) ->
       %% 计算slot，主要是根据hash值来计算
       Slot = get_slot(S , E),
       %% 根据槽位Slot得到对应的bucket数据
       Bkt = get_bucket(S , Slot),
       %% 判断元素是否在列表中
      lists:member( E , Bkt ).

%% add_element(Element, Set) -> Set.
%%  Return Set with Element inserted in it.
-spec add_element( Element , Set1 ) -> Set2 when
      Element :: term(),
      Set1 :: set(),
      Set2 :: set().
%% 向set数据结构中添加元素
add_element(E, S0) ->
       %% 计算slot，主要是根据hash值来计算
       Slot = get_slot(S0 , E),
       %% 根据槽位Slot得到对应的bucket数据，然后执行相应的操作
      { S1 ,Ic } = on_bucket(fun ( B0 ) -> add_bkt_el(E, B0, B0) end, S0 , Slot ),
       %% 如果元素数量超过上限则需要对set数据结构进行扩展
      maybe_expand( S1 , Ic ).

-spec add_bkt_el( T , [T ], [T]) -> {[ T ], 0 | 1}.
%% 增加元素的实际操作
add_bkt_el(E, [E | _], Bkt) -> {Bkt, 0};

add_bkt_el(E, [_ | B], Bkt) ->
      add_bkt_el( E , B , Bkt);

add_bkt_el(E, [], Bkt) -> {[ E | Bkt ], 1}.

%% del_element(Element, Set) -> Set.
%%  Return Set but with Element removed.
-spec del_element( Element , Set1 ) -> Set2 when
      Element :: term(),
      Set1 :: set(),
      Set2 :: set().
%% 将set数据结构中的E元素删除掉
del_element(E, S0) ->
       %% 计算slot，主要是根据hash值来计算
    Slot = get_slot( S0 , E ),
       %% 根据槽位Slot得到对应的bucket数据，然后执行相应的操作
    {S1,Dc} = on_bucket( fun (B0 ) -> del_bkt_el( E , B0 ) end, S0 , Slot ),
       %% 如果元素数量小于需要收缩的数量，则对set数据结构进行收缩操作
    maybe_contract( S1 , Dc ).

-spec del_bkt_el( T , [T ]) -> {[ T ], 0 | 1}.
%% 实际删除元素的操作函数
del_bkt_el(E, [E | Bkt]) -> {Bkt, 1};

del_bkt_el(E, [Other | Bkt0 ]) ->
      { Bkt1 , Dc } = del_bkt_el(E, Bkt0),
      {[ Other | Bkt1 ], Dc};

del_bkt_el(_, []) -> {[], 0 }.

%% union(Set1, Set2) -> Set
%%  Return the union of Set1 and Set2.
-spec union( Set1 , Set2 ) -> Set3 when
      Set1 :: set(),
      Set2 :: set(),
      Set3 :: set().
%% 将S1和S2这两个set数据结构进行合并(S2的数据数量大于S1的，则将S1的数据合并到S2中)
union(S1, S2) when S1 #set.size < S2 #set.size ->
    fold(fun ( E , S ) -> add_element( E , S ) end, S2 , S1 );

%% 将S1和S2这两个set数据结构进行合并(S1的数据数量大于S2的，则将S2的数据合并到S1中)
union(S1, S2) ->
    fold(fun ( E , S ) -> add_element( E , S ) end, S1 , S2 ).

%% union([Set]) -> Set
%%  Return the union of the list of sets.
-spec union( SetList ) -> Set when
      SetList :: [set()],
      Set :: set().
%% 将列表中所有的set数据结构进行合并
union([S1, S2 | Ss]) ->
      union1(union( S1 , S2 ), Ss);

union([S]) -> S;

union([]) -> new().

-spec union1(set(), [set()]) -> set().
union1(S1, [S2 | Ss]) ->
      union1(union( S1 , S2 ), Ss);

union1(S1, []) -> S1 .

%% intersection(Set1, Set2) -> Set.
%%  Return the intersection of Set1 and Set2.
-spec intersection( Set1 , Set2 ) -> Set3 when
      Set1 :: set(),
      Set2 :: set(),
      Set3 :: set().
%% 获取S1和S2这两个set数据结构的交集(S2中的数据量大于S1，则遍历S1数据结构)
intersection(S1, S2) when S1 #set.size < S2 #set.size ->
    filter(fun ( E ) -> is_element(E, S2) end, S1 );

%% 获取S1和S2这两个set数据结构的交集(S2中的数据量小于等于S1，则遍历S2数据结构)
intersection(S1, S2) ->
    filter(fun ( E ) -> is_element(E, S1) end, S2 ).

%% intersection([Set]) -> Set.
%%  Return the intersection of the list of sets.
-spec intersection( SetList ) -> Set when
      SetList :: [set(),...],
      Set :: set().
%% 获取set数据结构列表中所有set的交集
intersection([S1, S2 | Ss]) ->
      intersection1(intersection( S1 , S2 ), Ss);

intersection([S]) -> S.

-spec intersection1(set(), [set()]) -> set().
intersection1(S1, [S2 | Ss]) ->
      intersection1(intersection( S1 , S2 ), Ss);

intersection1(S1, []) -> S1 .

%% is_disjoint(Set1, Set2) -> boolean().
%%  Check whether Set1 and Set2 are disjoint.
-spec is_disjoint( Set1 , Set2 ) -> boolean() when
      Set1 :: set(),
      Set2 :: set().
%% disjoint：不相交的
%% 判断S1和S2这两个set数据结构是不相交的
is_disjoint(S1, S2) when S1 #set.size < S2 #set.size ->
      fold( fun (_ , false) -> false;
                  ( E , true) -> not is_element( E , S2 )
             end , true, S1 );

is_disjoint(S1, S2) ->
      fold( fun (_ , false) -> false;
                  ( E , true) -> not is_element( E , S1 )
             end , true, S2 ).

%% subtract(Set1, Set2) -> Set.
%%  Return all and only the elements of Set1 which are not also in
%%  Set2.
-spec subtract( Set1 , Set2 ) -> Set3 when
      Set1 :: set(),
      Set2 :: set(),
      Set3 :: set().
%% 将S2中存在于S1中的元素，从S1结构中去除掉，即减去交集
subtract(S1, S2) ->
      filter( fun (E ) -> not is_element( E , S2 ) end, S1 ).

%% is_subset(Set1, Set2) -> boolean().
%%  Return 'true' when every element of Set1 is also a member of
%%  Set2, else 'false'.
-spec is_subset( Set1 , Set2 ) -> boolean() when
      Set1 :: set(),
      Set2 :: set().
%% 判断S1和S2这两个set数据结构是否存在交集
is_subset(S1, S2) ->
      fold( fun (E , Sub) -> Sub andalso is_element( E , S2 ) end, true, S1 ).

%% fold(Fun, Accumulator, Set) -> Accumulator.
%%  Fold function Fun over all elements in Set and return Accumulator.
-spec fold( Function , Acc0 , Set) -> Acc1 when
      Function :: fun ((E :: term(),AccIn) -> AccOut),
      Set :: set(),
      Acc0 :: T ,
      Acc1 :: T ,
      AccIn :: T ,
      AccOut :: T .
%% 对set数据结构进行foldl操作
fold(F, Acc, D) -> fold_set( F , Acc , D).

%% filter(Fun, Set) -> Set.
%%  Filter Set with Fun.
-spec filter( Pred , Set1 ) -> Set2 when
      Pred :: fun ((E :: term()) -> boolean()),
      Set1 :: set(),
      Set2 :: set().
%% 给set数据结构进行过滤操作
filter(F, D) -> filter_set( F , D ).

%% get_slot(Hashdb, Key) -> Slot.
%%  Get the slot.  First hash on the new range, if we hit a bucket
%%  which has not been split use the unsplit buddy bucket.
-spec get_slot(set(), term()) -> non_neg_integer().
%% 对Key进行Hash得到对应的Slot槽位号
get_slot(T, Key) ->
       H = erlang:phash(Key , T#set.maxn),
       if
             H > T #set.n -> H - T#set.bso;
            true -> H
       end .

%% get_bucket(Hashdb, Slot) -> Bucket.
-spec get_bucket(set(), non_neg_integer()) -> term().
%% 从T这个set数据结构中通过Slot拿到对应的bucket数据
get_bucket(T, Slot) -> get_bucket_s( T #set.segs, Slot ).

%% on_bucket(Fun, Hashdb, Slot) -> {NewHashDb,Result}.
%%  Apply Fun to the bucket in Slot and replace the returned bucket.
-spec on_bucket( fun ((_ ) -> {[ _ ], 0 | 1}), set(), non_neg_integer()) ->
        {set(), 0 | 1 }.
on_bucket(F, T, Slot) ->
    SegI = (( Slot -1 ) div ?seg_size ) + 1 ,
    BktI = (( Slot -1 ) rem ?seg_size ) + 1 ,
    Segs = T#set.segs,
    Seg = element( SegI , Segs ),
    B0 = element( BktI , Seg ),
    {B1, Res} = F(B0),                     %Op on the bucket.
    {T#set{segs = setelement( SegI , Segs , setelement(BktI, Seg, B1 ))},Res }.

%% fold_set(Fun, Acc, Dictionary) -> Dictionary.
%% filter_set(Fun, Dictionary) -> Dictionary.

%%  Work functions for fold and filter operations.  These traverse the
%%  hash structure rebuilding as necessary.  Note we could have
%%  implemented map and hash using fold but these should be faster.
%%  We hope!
%% 对set数据结构进行foldl操作
fold_set(F, Acc, D) when is_function( F , 2 ) ->
       Segs = D #set.segs,
      fold_segs( F , Acc , Segs, tuple_size( Segs )).


%% 对segs进行foldl操作
fold_segs(F, Acc, Segs, I) when I >= 1 ->
       Seg = element(I , Segs),
      fold_segs( F , fold_seg(F , Acc, Seg, tuple_size( Seg )), Segs , I - 1);

fold_segs(_, Acc, _, _) -> Acc.


%% 对seg进行foldl操作
fold_seg(F, Acc, Seg, I) when I >= 1 ->
      fold_seg( F , fold_bucket(F , Acc, element( I , Seg )), Seg, I - 1);

fold_seg(_, Acc, _, _) -> Acc.


%% 对bucket进程foldl操作
fold_bucket(F, Acc, [E | Bkt]) ->
      fold_bucket( F , F (E, Acc), Bkt);

fold_bucket(_, Acc, []) -> Acc .


%% 根据F函数过来掉D这个set数据结构中的元素
filter_set(F, D) when is_function( F , 1 ) ->
       Segs0 = tuple_to_list(D #set.segs),
      { Segs1 , Fc } = filter_seg_list(F, Segs0, [], 0 ),
      maybe_contract( D #set{segs = list_to_tuple(Segs1 )}, Fc).


%% 过滤segs中的元素
filter_seg_list(F, [Seg | Segs], Fss, Fc0) ->
       Bkts0 = tuple_to_list(Seg ),
      { Bkts1 , Fc1 } = filter_bkt_list(F, Bkts0, [], Fc0 ),
      filter_seg_list( F , Segs , [list_to_tuple(Bkts1) | Fss ], Fc1 );

filter_seg_list(_, [], Fss, Fc) ->
      {lists:reverse( Fss , []),Fc }.


%% 过滤seg中的元素
filter_bkt_list(F, [Bkt0 | Bkts], Fbs, Fc0) ->
      { Bkt1 , Fc1 } = filter_bucket(F, Bkt0, [], Fc0 ),
      filter_bkt_list( F , Bkts , [Bkt1 | Fbs], Fc1);

filter_bkt_list(_, [], Fbs, Fc) ->
      {lists:reverse( Fbs ), Fc }.


%% 过滤掉bucket中的元素
filter_bucket(F, [E | Bkt], Fb, Fc) ->
       case F (E) of
            true -> filter_bucket(F , Bkt, [E | Fb], Fc);
            false -> filter_bucket(F , Bkt, Fb, Fc + 1)
       end ;

filter_bucket(_, [], Fb, Fc) -> {Fb, Fc}.

%% get_bucket_s(Segments, Slot) -> Bucket.
%% put_bucket_s(Segments, Slot, Bucket) -> NewSegments.
%% 根据Slot槽位号得到对应的bucket数据
get_bucket_s(Segs, Slot) ->
       SegI = ((Slot - 1) div ?seg_size ) + 1 ,
       BktI = ((Slot - 1) rem ?seg_size ) + 1 ,
      element( BktI , element(SegI , Segs)).


%% 向Slot槽位号设置Bkt元素列表
put_bucket_s(Segs, Slot, Bkt) ->
       SegI = ((Slot - 1) div ?seg_size ) + 1 ,
       BktI = ((Slot - 1) rem ?seg_size ) + 1 ,
       Seg = setelement(BktI , element(SegI, Segs), Bkt),
      setelement( SegI , Segs , Seg).

-spec maybe_expand(set(), 0 | 1 ) -> set().
maybe_expand(T0, Ic) when T0 #set.size + Ic > T0#set.exp_size ->
       %% 如果当前已经激活的slot数量等于当前最大的slot数量，则将当前的slot数量翻倍
       T = maybe_expand_segs(T0 ),                 %Do we need more segments.
       N = T #set.n + 1,                     %Next slot to expand into
       Segs0 = T #set.segs,
       Slot1 = N - T#set.bso,
       %% 得到Slot1对应的bucket数据
       B = get_bucket_s(Segs0 , Slot1),
       Slot2 = N ,
       %% 将Slot1中的数据重新进行hash操作
      { B1 , B2 } = rehash(B, Slot1, Slot2, T#set.maxn),
       %% 将映射在Slot1中的数据存入Slot1中
       Segs1 = put_bucket_s(Segs0 , Slot1, B1),
       %% 将映射在Slot2中的数据存入Slot2中
       Segs2 = put_bucket_s(Segs1 , Slot2, B2),
       T #set{size = T #set.size + Ic,
              n = N ,
              exp_size = N * ?expand_load ,
              con_size = N * ?contract_load ,
              segs = Segs2 };

%% 当前set数据结构中的数据没有大于需要扩展的大小，则只更新set数据结构中的数据量
maybe_expand(T, Ic) -> T#set{size = T #set.size + Ic }.

-spec maybe_expand_segs(set()) -> set().
%% 如果当前已经激活的slot数量等于当前最大的slot数量，则将当前的slot数量翻倍
maybe_expand_segs(T) when T #set.n =:= T #set.maxn ->
       T #set{maxn = 2 * T#set.maxn,
              bso  = 2 * T #set.bso,
              segs = expand_segs( T #set.segs, T #set.empty)};

maybe_expand_segs(T) -> T.

-spec maybe_contract(set(), non_neg_integer()) -> set().
%% 当T这个set数据结构中的数据量大小减去丢弃的Dc个元素后如果小于set数据结构收缩的下限值，则需要对set数据结构进行收缩操作
maybe_contract(T, Dc) when T #set.size - Dc < T#set.con_size,
                     T #set.n > ?seg_size ->
    N = T#set.n,
    Slot1 = N - T #set.bso,
    Segs0 = T #set.segs,
       %% 拿到Slot1对应的bucket数据
    B1 = get_bucket_s( Segs0 , Slot1 ),
    Slot2 = N ,
       %% 拿到Slot2对应的bucket数据
    B2 = get_bucket_s( Segs0 , Slot2 ),
       %% 将Slot1和Slot2中的元素全部存入Slot1对应的bucket中
    Segs1 = put_bucket_s( Segs0 , Slot1 , B1 ++ B2),
       %% 将Slot2中的元素清空
    Segs2 = put_bucket_s( Segs1 , Slot2 , []),     %Clear the upper bucket
       %% 将当前激活的Slot数量减一
    N1 = N - 1,
       %% 如果当前激活的slot数量等于bso的值，则需要正的对set数据结构进行收缩操作
    maybe_contract_segs( T #set{size = T #set.size - Dc,
                        n = N1 ,
                        exp_size = N1 * ?expand_load ,
                        con_size = N1 * ?contract_load ,
                        segs = Segs2 });

%% 当T这个set数据结构中的数据量大小减去丢弃的Dc个元素后如果大于等于set数据结构收缩的下限值，则只更新当前set数据结构的元素数量
maybe_contract(T, Dc) -> T#set{size = T #set.size - Dc }.

-spec maybe_contract_segs(set()) -> set().
%% 如果当前激活的slot数量等于bso的值，则需要正的对set数据结构进行收缩操作
maybe_contract_segs(T) when T #set.n =:= T #set.bso ->
    T#set{maxn = T #set.maxn div 2,
        bso  = T #set.bso div 2,
        segs = contract_segs( T #set.segs)};

maybe_contract_segs(T) -> T.

%% rehash(Bucket, Slot1, Slot2, MaxN) -> {Bucket1,Bucket2}.
-spec rehash([ T ], integer(), pos_integer(), pos_integer()) -> {[T ],[T ]}.
%% 对列表中的元素重新进行hash操作得到新的hash值
rehash([E | T], Slot1, Slot2, MaxN) ->
      { L1 , L2 } = rehash(T, Slot1, Slot2, MaxN),
       case erlang:phash(E , MaxN) of
             Slot1 -> {[E | L1], L2};
             Slot2 -> {L1, [E | L2]}
       end ;

rehash([], _, _, _) -> {[], []}.

%% mk_seg(Size) -> Segment.
-spec mk_seg( 16 ) -> seg().
%% 单个setment初始化结构
mk_seg(16) -> {[], [], [], [], [], [], [], [], [], [], [], [], [], [], [], []}.

%% expand_segs(Segs, EmptySeg) -> NewSegs.
%% contract_segs(Segs) -> NewSegs.
%%  Expand/contract the segment tuple by doubling/halving the number
%%  of segments.  We special case the powers of 2 upto 32, this should
%%  catch most case.  N.B. the last element in the segments tuple is
%%  an extra element containing a default empty segment.
-spec expand_segs(segs(), seg()) -> segs().
%% 将当前的slot数量扩展翻两倍
expand_segs({B1}, Empty) ->
      { B1 , Empty };

expand_segs({B1, B2}, Empty) ->
      { B1 , B2 , Empty, Empty};

expand_segs({B1, B2, B3, B4}, Empty) ->
      { B1 , B2 , B3, B4, Empty, Empty, Empty, Empty};

expand_segs({B1, B2, B3, B4, B5, B6, B7, B8}, Empty) ->
      { B1 , B2 , B3, B4, B5, B6, B7, B8,
       Empty , Empty , Empty, Empty, Empty, Empty, Empty, Empty};

expand_segs({B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14 , B15 , B16}, Empty) ->
      { B1 , B2 , B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15, B16 ,
       Empty , Empty , Empty, Empty, Empty, Empty, Empty, Empty,
       Empty , Empty , Empty, Empty, Empty, Empty, Empty, Empty};

expand_segs(Segs, Empty) ->
      list_to_tuple(tuple_to_list( Segs )
                                ++ lists:duplicate(tuple_size( Segs ), Empty )).

-spec contract_segs(segs()) -> segs().
%% 将当前的slot数量收缩一半
contract_segs({B1, _}) ->
      { B1 };

contract_segs({B1, B2, _, _}) ->
      { B1 , B2 };

contract_segs({B1, B2, B3, B4, _, _, _, _}) ->
      { B1 , B2 , B3, B4};

contract_segs({B1, B2, B3, B4, B5, B6, B7, B8, _, _, _, _, _, _, _, _}) ->
      { B1 , B2 , B3, B4, B5, B6, B7, B8};

contract_segs({B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14 , B15 , B16,
                     _ , _ , _, _, _, _, _, _, _, _, _, _, _, _, _, _}) ->
      { B1 , B2 , B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15, B16 };

contract_segs(Segs) ->
       Ss = tuple_size(Segs ) div 2 ,
      list_to_tuple(lists:sublist(tuple_to_list( Segs ), 1 , Ss)). 

