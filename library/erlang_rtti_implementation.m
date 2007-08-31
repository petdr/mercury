%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et wm=0 tw=0
%-----------------------------------------------------------------------------%
% Copyright (C) 2007 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: erlang_rtti_implementation.m.
% Main author: petdr, wangp.
% Stability: low.
%
% This file is intended to provide the RTTI implementation for the Erlang
% backend.
%
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module erlang_rtti_implementation.
:- interface.

:- import_module deconstruct.
:- import_module list.
:- import_module type_desc.
:- import_module univ.

:- type type_info.
:- type type_ctor_info.
:- type type_ctor_info_evaled.

:- func get_type_info(T::unused) = (type_info::out) is det.

    %
    % Check if two values are equal.
    % Note this is not structural equality because a type
    % can have user-defined equality.
    %
:- pred generic_unify(T::in, T::in) is semidet.

:- pred generic_compare(comparison_result::out, T::in, T::in) is det.

:- pred compare_type_infos(comparison_result::out,
    type_info::in, type_info::in) is det.

:- pred type_ctor_info_and_args(type_info::in, type_ctor_info_evaled::out,
    list(type_info)::out) is det.

:- pred type_ctor_desc(type_desc::in, type_ctor_desc::out) is det.

:- pred type_ctor_desc_and_args(type_desc::in, type_ctor_desc::out,
    list(type_desc)::out) is det.

:- pred make_type_desc(type_ctor_desc::in, list(type_desc)::in,
    type_desc::out) is semidet.

:- pred type_ctor_desc_name_and_arity(type_ctor_desc::in,
    string::out, string::out, int::out) is det.

:- pred deconstruct(T, noncanon_handling, string, int, int, list(univ)).
:- mode deconstruct(in, in(do_not_allow), out, out, out, out) is det.
:- mode deconstruct(in, in(canonicalize), out, out, out, out) is det.
:- mode deconstruct(in, in(include_details_cc), out, out, out, out)
    is cc_multi.
:- mode deconstruct(in, in, out, out, out, out) is cc_multi.

%-----------------------------------------------------------------------------%
%
% Implementations for use from construct.

:- func num_functors(type_desc.type_desc) = int is semidet.

:- pred get_functor(type_desc.type_desc::in, int::in, string::out, int::out,
    list(type_desc.type_desc)::out) is semidet.

:- pred get_functor_with_names(type_desc.type_desc::in, int::in, string::out,
    int::out, list(type_desc.type_desc)::out, list(string)::out)
    is semidet.

:- pred get_functor_ordinal(type_desc.type_desc::in, int::in, int::out)
    is semidet.

:- pred get_functor_lex(type_desc.type_desc::in, int::in, int::out)
    is semidet.

:- func construct(type_desc::in, int::in, list(univ)::in) = (univ::out)
    is semidet.

:- func construct_tuple_2(list(univ), list(type_desc), int) = univ.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module array.
:- import_module char.
:- import_module int.
:- import_module require.
:- import_module string.
:- import_module term_io.
:- import_module type_desc.

    %
    % A type_info can be represented in one of three ways
    % For a type with arity 0
    %   TypeCtorInfo
    % a type with arity > 0
    %   { TypeCtorInfo, TypeInfo0, ..., TypeInfoN }
    % a type with variable arity of size N
    %   { TypeCtorInfo, N, TypeInfo0, ..., TypeInfoN }
    %
    % Note that we usually we pass thunks in place of type_ctor_infos
    % themselves.
    %   
:- pragma foreign_type("Erlang", type_info, "").
:- type type_info ---> type_info.

    % In the Erlang RTTI implementation, this is actually a thunk returning a
    % type_ctor_info.
    %
:- pragma foreign_type("Erlang", type_ctor_info, "").
:- type type_ctor_info ---> type_ctor_info.

    % The actual type_ctor_info, i.e. after evaluating the thunk.  For the
    % representation of a type_ctor_info see erl_rtti.type_ctor_data_to_elds.
    %
:- pragma foreign_type("Erlang", type_ctor_info_evaled, "").
:- type type_ctor_info_evaled ---> type_ctor_info_evaled.

    % The type_ctor_rep needs to be kept up to date with the alternatives
    % given by the function erl_rtti.erlang_type_ctor_rep/1
    %
:- type erlang_type_ctor_rep
    --->    etcr_du
    ;       etcr_dummy
    ;       etcr_list
    ;       etcr_array
    ;       etcr_eqv
    ;       etcr_int
    ;       etcr_float
    ;       etcr_char
    ;       etcr_string
    ;       etcr_void
    ;       etcr_stable_c_pointer
    ;       etcr_c_pointer
    ;       etcr_pred
    ;       etcr_func
    ;       etcr_tuple
    ;       etcr_ref
    ;       etcr_type_desc
    ;       etcr_pseudo_type_desc
    ;       etcr_type_ctor_desc
    ;       etcr_type_info
    ;       etcr_type_ctor_info
    ;       etcr_typeclass_info
    ;       etcr_base_typeclass_info
    ;       etcr_foreign

            % These types shouldn't be needed they are
            % introduced for library predicates which
            % don't apply on this backend.
    ;       etcr_hp
    ;       etcr_subgoal
    ;       etcr_ticket
    .

    % Values of type `type_desc' are represented the same way as values of
    % type `type_info'.
    %
    % Values of type `type_ctor_desc' are NOT represented the same way as
    % values of type `type_ctor_info'.  The representations *are* in fact
    % identical for fixed arity types, but they differ for higher order and
    % tuple types. In that case they are one of the following:
    %
    %   {pred, Arity},
    %   {func, Arity},
    %   {tuple, Arity}

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

get_type_info(T) = T ^ type_info.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

generic_unify(X, Y) :-
    TypeInfo = X ^ type_info,
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    (
        TypeCtorRep = etcr_tuple
    ->
        unify_tuple(TypeInfo, X, Y)
    ;
        ( TypeCtorRep = etcr_pred ; TypeCtorRep = etcr_func )
    ->
        error("unify/2: higher order unification not possible")
    ;
        Arity = TypeCtorInfo ^ type_ctor_arity,
        UnifyPred = TypeCtorInfo ^ type_ctor_unify_pred,
        ( Arity = 0 ->
            semidet_call_3(UnifyPred, X, Y)
        ; Arity = 1 ->
            semidet_call_4(UnifyPred,
                TypeInfo ^ type_info_index(1), X, Y)
        ; Arity = 2 ->
            semidet_call_5(UnifyPred,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                X, Y)
        ; Arity = 3 ->
            semidet_call_6(UnifyPred,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                TypeInfo ^ type_info_index(3),
                X, Y)
        ; Arity = 4 ->
            semidet_call_7(UnifyPred,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                TypeInfo ^ type_info_index(3),
                TypeInfo ^ type_info_index(4),
                X, Y)
        ; Arity = 5 ->
            semidet_call_8(UnifyPred,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                TypeInfo ^ type_info_index(3),
                TypeInfo ^ type_info_index(4),
                TypeInfo ^ type_info_index(5),
                X, Y)
        ;
            error("unify/2: type arity > 5 not supported")
        )
    ).

:- pred unify_tuple(type_info::in, T::in, T::in) is semidet.

unify_tuple(TypeInfo, X, Y) :-
    Arity = TypeInfo ^ var_arity_type_info_arity,
    unify_tuple_pos(1, Arity, TypeInfo, X, Y).

:- pred unify_tuple_pos(int::in, int::in,
        type_info::in, T::in, T::in) is semidet.

unify_tuple_pos(Loc, TupleArity, TypeInfo, TermA, TermB) :-
    ( Loc > TupleArity ->
        true
    ;
        ArgTypeInfo = TypeInfo ^ var_arity_type_info_index(Loc),

        SubTermA = get_subterm(ArgTypeInfo, TermA, Loc, 0),
        SubTermB = get_subterm(ArgTypeInfo, TermB, Loc, 0),

        generic_unify(SubTermA, unsafe_cast(SubTermB)),

        unify_tuple_pos(Loc + 1, TupleArity, TypeInfo, TermA, TermB)
    ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

generic_compare(Res, X, Y) :-
    TypeInfo = X ^ type_info,
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    (
        TypeCtorRep = etcr_tuple
    ->
        compare_tuple(TypeInfo, Res, X, Y)
    ;
        ( TypeCtorRep = etcr_pred ; TypeCtorRep = etcr_func )
    ->
        error("compare/3: higher order comparison not possible")
    ;
        Arity = TypeCtorInfo ^ type_ctor_arity,
        ComparePred = TypeCtorInfo ^ type_ctor_compare_pred,
        ( Arity = 0 ->
            result_call_4(ComparePred, Res, X, Y)
        ; Arity = 1 ->
            result_call_5(ComparePred, Res,
                TypeInfo ^ type_info_index(1), X, Y)
        ; Arity = 2 ->
            result_call_6(ComparePred, Res,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                X, Y)
        ; Arity = 3 ->
            result_call_7(ComparePred, Res,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                TypeInfo ^ type_info_index(3),
                X, Y)
        ; Arity = 4 ->
            result_call_8(ComparePred, Res,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                TypeInfo ^ type_info_index(3),
                TypeInfo ^ type_info_index(4),
                X, Y)
        ; Arity = 5 ->
            result_call_9(ComparePred, Res,
                TypeInfo ^ type_info_index(1),
                TypeInfo ^ type_info_index(2),
                TypeInfo ^ type_info_index(3),
                TypeInfo ^ type_info_index(4),
                TypeInfo ^ type_info_index(5),
                X, Y)
        ;
            error("compare/3: type arity > 5 not supported")
        )
    ).
    
:- pred compare_tuple(type_info::in, comparison_result::out, T::in, T::in)
    is det.

compare_tuple(TypeInfo, Result, TermA, TermB) :-
    Arity = TypeInfo ^ var_arity_type_info_arity,
    compare_tuple_pos(1, Arity, TypeInfo, Result, TermA, TermB).

:- pred compare_tuple_pos(int::in, int::in, type_info::in,
    comparison_result::out, T::in, T::in) is det.

compare_tuple_pos(Loc, TupleArity, TypeInfo, Result, TermA, TermB) :-
    ( Loc > TupleArity ->
        Result = (=)
    ;
        ArgTypeInfo = TypeInfo ^ var_arity_type_info_index(Loc),

        SubTermA = get_subterm(ArgTypeInfo, TermA, Loc, 0),
        SubTermB = get_subterm(ArgTypeInfo, TermB, Loc, 0),

        generic_compare(SubResult, SubTermA, unsafe_cast(SubTermB)),
        ( SubResult = (=) ->
            compare_tuple_pos(Loc + 1, TupleArity, TypeInfo, Result,
                TermA, TermB)
        ;
            Result = SubResult
        )
    ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

compare_type_infos(Res, TypeInfoA, TypeInfoB) :-
    TA = collapse_equivalences(TypeInfoA),
    TB = collapse_equivalences(TypeInfoB),

    TCA = TA ^ type_ctor_info_evaled,
    TCB = TB ^ type_ctor_info_evaled,

    compare(NameRes, TCA ^ type_ctor_type_name, TCB ^ type_ctor_type_name),
    ( NameRes = (=) ->
        compare(ModuleRes,
            TCA ^ type_ctor_module_name, TCB ^ type_ctor_module_name),
        ( ModuleRes = (=) ->
            (
                type_ctor_is_variable_arity(TCA)
            ->
                ArityA = TA ^ var_arity_type_info_arity,
                ArityB = TB ^ var_arity_type_info_arity,
                compare(ArityRes, ArityA, ArityB),
                ( ArityRes = (=) ->
                    compare_var_arity_typeinfos(1, ArityA, Res, TA, TB)
                ;
                    Res = ArityRes
                )
            ;
                ArityA = TCA ^ type_ctor_arity,
                ArityB = TCA ^ type_ctor_arity,
                compare(ArityRes, ArityA, ArityB),
                ( ArityRes = (=) ->
                    compare_sub_typeinfos(1, ArityA, Res, TA, TB)
                ;
                    Res = ArityRes
                )
            )
        ;
            Res = ModuleRes
        )
    ;
        Res = NameRes
    ).

:- pred compare_sub_typeinfos(int::in, int::in,
    comparison_result::out, type_info::in, type_info::in) is det.

compare_sub_typeinfos(Loc, Arity, Result, TypeInfoA, TypeInfoB) :-
    ( Loc > Arity ->
        Result = (=)
    ;
        SubTypeInfoA = TypeInfoA ^ type_info_index(Loc),
        SubTypeInfoB = TypeInfoB ^ type_info_index(Loc),

        compare_type_infos(SubResult, SubTypeInfoA, SubTypeInfoB),
        ( SubResult = (=) ->
            compare_var_arity_typeinfos(Loc + 1, Arity, Result,
                TypeInfoA, TypeInfoB)
        ;
            Result = SubResult
        )
    ).

:- pred compare_var_arity_typeinfos(int::in, int::in,
    comparison_result::out, type_info::in, type_info::in) is det.

compare_var_arity_typeinfos(Loc, Arity, Result, TypeInfoA, TypeInfoB) :-
    ( Loc > Arity ->
        Result = (=)
    ;
        SubTypeInfoA = TypeInfoA ^ var_arity_type_info_index(Loc),
        SubTypeInfoB = TypeInfoB ^ var_arity_type_info_index(Loc),

        compare_type_infos(SubResult, SubTypeInfoA, SubTypeInfoB),
        ( SubResult = (=) ->
            compare_var_arity_typeinfos(Loc + 1, Arity, Result,
                TypeInfoA, TypeInfoB)
        ;
            Result = SubResult
        )
    ).




    
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

type_ctor_info_and_args(TypeInfo0, TypeCtorInfo, Args) :-
    TypeInfo = collapse_equivalences(TypeInfo0),
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    ( type_ctor_is_variable_arity(TypeCtorInfo) ->
        Args = get_var_arity_arg_type_infos(TypeInfo)
    ;
        Args = get_fixed_arity_arg_type_infos(TypeInfo)
    ).

:- pred type_ctor_is_variable_arity(type_ctor_info_evaled::in) is semidet.

type_ctor_is_variable_arity(TypeCtorInfo) :-
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    ( TypeCtorRep = etcr_tuple
    ; TypeCtorRep = etcr_pred
    ; TypeCtorRep = etcr_func
    ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

type_ctor_desc(TypeDesc, TypeCtorDesc) :-
    type_ctor_desc_and_args(TypeDesc, TypeCtorDesc, _Args).

type_ctor_desc_and_args(TypeDesc, TypeCtorDesc, ArgsDescs) :-
    TypeInfo0 = type_info_from_type_desc(TypeDesc),
    TypeInfo = collapse_equivalences(TypeInfo0),
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    % Handle variable arity types.
    ( TypeCtorRep = etcr_pred ->
        Arity = TypeInfo ^ var_arity_type_info_arity,
        TypeCtorDesc = make_pred_type_ctor_desc(Arity),
        ArgInfos = get_var_arity_arg_type_infos(TypeInfo)

    ; TypeCtorRep = etcr_func ->
        Arity = TypeInfo ^ var_arity_type_info_arity,
        TypeCtorDesc = make_func_type_ctor_desc(Arity),
        ArgInfos = get_var_arity_arg_type_infos(TypeInfo)

    ; TypeCtorRep = etcr_tuple ->
        Arity = TypeInfo ^ var_arity_type_info_arity,
        TypeCtorDesc = make_tuple_type_ctor_desc(Arity),
        ArgInfos = get_var_arity_arg_type_infos(TypeInfo)
    ;
        % Handle fixed arity types.
        TypeCtorDesc = make_fixed_arity_type_ctor_desc(TypeCtorInfo),
        ArgInfos = get_fixed_arity_arg_type_infos(TypeInfo)
    ),
    ArgsDescs = type_descs_from_type_infos(ArgInfos).

:- func make_pred_type_ctor_desc(int) = type_ctor_desc.

:- pragma foreign_proc("Erlang",
    make_pred_type_ctor_desc(Arity::in) = (TypeCtorDesc::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    TypeCtorDesc = {pred, Arity}
").

make_pred_type_ctor_desc(_) = _ :-
    private_builtin.sorry("make_pred_type_ctor_desc").

:- func make_func_type_ctor_desc(int) = type_ctor_desc.

:- pragma foreign_proc("Erlang",
    make_func_type_ctor_desc(Arity::in) = (TypeCtorDesc::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    TypeCtorDesc = {func, Arity}
").

make_func_type_ctor_desc(_) = _ :-
    private_builtin.sorry("make_func_type_ctor_desc").

:- func make_tuple_type_ctor_desc(int) = type_ctor_desc.

:- pragma foreign_proc("Erlang",
    make_tuple_type_ctor_desc(Arity::in) = (TypeCtorDesc::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    TypeCtorDesc = {tuple, Arity}
").

make_tuple_type_ctor_desc(_) = _ :-
    private_builtin.sorry("make_tuple_type_ctor_desc").

:- func make_fixed_arity_type_ctor_desc(type_ctor_info_evaled)
    = type_ctor_desc.

make_fixed_arity_type_ctor_desc(TypeCtorInfo) = TypeCtorDesc :-
    % Fixed arity types have the same representations.
    TypeCtorDesc = unsafe_cast(TypeCtorInfo).

:- func type_info_from_type_desc(type_desc) = type_info.

type_info_from_type_desc(TypeDesc) = TypeInfo :-
    % They have the same representation.
    TypeInfo = unsafe_cast(TypeDesc).

:- func type_descs_from_type_infos(list(type_info)) = list(type_desc).

type_descs_from_type_infos(TypeInfos) = TypeDescs :-
    % They have the same representation.
    TypeDescs = unsafe_cast(TypeInfos).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pragma foreign_proc("Erlang",
    make_type_desc(TypeCtorDesc::in, ArgTypeDescs::in, TypeDesc::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    MakeVarArityTypeDesc =
        (fun(TypeCtorInfo, Arity, ArgTypeInfos) ->
            case Arity =:= length(ArgTypeInfos) of
                true ->
                    TypeInfo = 
                        list_to_tuple([TypeCtorInfo, Arity | ArgTypeDescs]),
                    {true, TypeInfo};
                false ->
                    {false, null}
            end
        end),

    case TypeCtorDesc of
        % Handle the variable arity types.
        {pred, Arity} ->
            TCI = fun mercury__builtin:builtin__type_ctor_info_pred_0/0,
            {SUCCESS_INDICATOR, TypeDesc} = MakeVarArityTypeDesc(TCI, Arity,
                ArgTypeDescs);

        {func, Arity} ->
            TCI = fun mercury__builtin:builtin__type_ctor_info_func_0/0,
            {SUCCESS_INDICATOR, TypeDesc} = MakeVarArityTypeDesc(TCI, Arity,
                ArgTypeDescs);

        {tuple, Arity} ->
            TCI = fun mercury__builtin:builtin__type_ctor_info_tuple_0/0,
            {SUCCESS_INDICATOR, TypeDesc} = MakeVarArityTypeDesc(TCI, Arity,
                ArgTypeDescs);

        % Handle fixed arity types.
        TypeCtorInfo ->
            ArgTypeInfos = ArgTypeDescs,
            case
                mercury__erlang_rtti_implementation:
                    'ML_make_fixed_arity_type_info'(TypeCtorInfo, ArgTypeInfos)
            of
                {TypeInfo} ->
                    SUCCESS_INDICATOR = true,
                    % type_desc and type_info have same representation.
                    TypeDesc = TypeInfo;
                fail ->
                    SUCCESS_INDICATOR = false,
                    TypeDesc = null
            end
    end
").

make_type_desc(_, _, _) :-
    private_builtin.sorry("make_type_desc/3").

:- pred make_fixed_arity_type_info(type_ctor_info_evaled::in,
    list(type_info)::in, type_info::out) is semidet.

:- pragma foreign_export("Erlang", make_fixed_arity_type_info(in, in, out),
    "ML_make_fixed_arity_type_info").

make_fixed_arity_type_info(TypeCtorInfo, ArgTypeInfos, TypeInfo) :-
    TypeCtorInfo ^ type_ctor_arity = list.length(ArgTypeInfos),
    TypeInfo = create_type_info(TypeCtorInfo, ArgTypeInfos).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pragma foreign_proc("Erlang",
    type_ctor_desc_name_and_arity(TypeCtorDesc::in, ModuleName::out, Name::out,
        Arity::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    case TypeCtorDesc of
        {pred, Arity} ->
            ModuleName = <<""builtin"">>,
            Name = <<""pred"">>,
            Arity = Arity;

        {func, Arity} ->
            ModuleName = <<""builtin"">>,
            Name = <<""func"">>,
            Arity = Arity;

        {tuple, Arity} ->
            ModuleName = <<""builtin"">>,
            Name = <<""{}"">>,
            Arity = Arity;

        TypeCtorInfo ->
            {ModuleName, Name, Arity} =
                mercury__erlang_rtti_implementation:
                    'ML_type_ctor_info_name_and_arity'(TypeCtorInfo)
    end
").

type_ctor_desc_name_and_arity(_, _, _, _) :-
    private_builtin.sorry("type_ctor_desc_name_and_arity/4").

:- pred type_ctor_info_name_and_arity(type_ctor_info_evaled::in,
    string::out, string::out, int::out) is det.

:- pragma foreign_export("Erlang",
    type_ctor_info_name_and_arity(in, out, out, out),
    "ML_type_ctor_info_name_and_arity").

type_ctor_info_name_and_arity(TypeCtorInfo, ModuleName, Name, Arity) :-
    ModuleName = TypeCtorInfo ^ type_ctor_module_name,
    Name = TypeCtorInfo ^ type_ctor_type_name,
    Arity = TypeCtorInfo ^ type_ctor_arity.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

deconstruct(Term, NonCanon, Functor, FunctorNumber, Arity, Arguments) :-
    TypeInfo = Term ^ type_info,
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    deconstruct_2(Term, TypeInfo, TypeCtorInfo, TypeCtorRep, NonCanon,
        Functor, FunctorNumber, Arity, Arguments).

:- pred deconstruct_2(T, type_info, type_ctor_info_evaled,
    erlang_type_ctor_rep, noncanon_handling, string, int, int, list(univ)).
:- mode deconstruct_2(in, in, in, in, in(do_not_allow), out, out, out, out)
    is det.
:- mode deconstruct_2(in, in, in, in, in(canonicalize), out, out, out, out)
    is det.
:- mode deconstruct_2(in, in, in, in,
    in(include_details_cc), out, out, out, out) is cc_multi.
:- mode deconstruct_2(in, in, in, in, in, out, out, out, out) is cc_multi.

deconstruct_2(Term, TypeInfo, TypeCtorInfo, TypeCtorRep, NonCanon,
        Functor, FunctorNumber, Arity, Arguments) :-
    (
        TypeCtorRep = etcr_du,
        FunctorReps = TypeCtorInfo ^ type_ctor_functors,
        matching_du_functor(FunctorReps, 0, Term, FunctorRep, FunctorNumber),
        Functor = string.from_char_list(FunctorRep ^ edu_name),
        Arity = FunctorRep ^ edu_orig_arity,
        Arguments = list.map(
            get_du_functor_arg(TypeInfo, FunctorRep, Term), 1 .. Arity)
    ;
        TypeCtorRep = etcr_dummy,
        Functor = TypeCtorInfo ^ type_ctor_dummy_functor_name,
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;
        TypeCtorRep = etcr_list,
        ArgTypeInfo = TypeInfo ^ type_info_index(1),
        ( is_non_empty_list(TypeInfo, ArgTypeInfo, Term, H, T) ->
            Functor = "[|]",
            FunctorNumber = 1,
            Arity = 2,
            Arguments = [univ(H), univ(T)]
        ;
            Functor = "[]",
            FunctorNumber = 0,
            Arity = 0,
            Arguments = []
        )
    ;
        TypeCtorRep = etcr_array,

        % Constrain the T in array(T) to the correct element type.
        type_ctor_and_args(type_of(Term), _, Args),
        ( Args = [ElemType] ->
            has_type(Elem, ElemType),
            same_array_elem_type(Array, Elem)
        ;
            error("An array which doesn't have a type_ctor arg")
        ),

        det_dynamic_cast(Term, Array),

        Functor = "<<array>>",
        FunctorNumber = 0,
        Arity = array.size(Array),
        Arguments = array.foldr(
            (func(Elem, List) = [univ(Elem) | List]),
            Array, [])
    ;
        TypeCtorRep = etcr_eqv,
        EqvTypeInfo = collapse_equivalences(TypeInfo),
        EqvTypeCtorInfo = EqvTypeInfo ^ type_ctor_info_evaled,
        EqvTypeCtorRep = EqvTypeCtorInfo ^ type_ctor_rep,
        deconstruct_2(Term, EqvTypeInfo, EqvTypeCtorInfo, EqvTypeCtorRep,
            NonCanon, Functor, FunctorNumber, Arity, Arguments)
    ;
        TypeCtorRep = etcr_tuple,
        Arity = TypeInfo ^ var_arity_type_info_arity,
        Functor = "{}",
        FunctorNumber = 0,
        Arguments = list.map(get_tuple_arg(TypeInfo, Term), 1 .. Arity)
    ;
        TypeCtorRep = etcr_int,
        det_dynamic_cast(Term, Int),
        Functor = string.int_to_string(Int),
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;
        TypeCtorRep = etcr_float,
        det_dynamic_cast(Term, Float),
        Functor = float_to_string(Float),
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;
        TypeCtorRep = etcr_char,
        det_dynamic_cast(Term, Char),
        Functor = term_io.quoted_char(Char),
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;
        TypeCtorRep = etcr_string,
        det_dynamic_cast(Term, String),
        Functor = term_io.quoted_string(String),
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;
            % There is no way to create values of type `void', so this
            % should never happen.
        TypeCtorRep = etcr_void,
        error(this_file ++ " deconstruct: cannot deconstruct void types")
    ;
        TypeCtorRep = etcr_stable_c_pointer,
        det_dynamic_cast(Term, CPtr),
        Functor = "stable_" ++ string.c_pointer_to_string(CPtr),
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;
        TypeCtorRep = etcr_c_pointer,
        det_dynamic_cast(Term, CPtr),
        Functor = string.c_pointer_to_string(CPtr),
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;
        ( TypeCtorRep = etcr_pred,
            Name = "<<predicate>>"
        ; TypeCtorRep = etcr_func,
            Name = "<<function>>"
        ; TypeCtorRep = etcr_ref,
            Name = "<<reference>>"
        ; TypeCtorRep = etcr_type_desc,
            Name = "<<typedesc>>"
        ; TypeCtorRep = etcr_pseudo_type_desc,
            Name = "<<pseudotypedesc>>"
        ; TypeCtorRep = etcr_type_ctor_desc,
            Name = "<<typectordesc>>"
        ; TypeCtorRep = etcr_type_info,
            Name = "<<typeinfo>>"
        ; TypeCtorRep = etcr_type_ctor_info,
            Name = "<<typectorinfo>>"
        ; TypeCtorRep = etcr_typeclass_info,
            Name = "<<typeclassinfo>>"
        ; TypeCtorRep = etcr_base_typeclass_info,
            Name = "<<basetypeclassinfo>>"
        ),
        (
            NonCanon = do_not_allow,
            error("attempt to deconstruct noncanonical term")
        ;
            NonCanon = canonicalize,
            Functor = Name,
            FunctorNumber = 0,
            Arity = 0,
            Arguments = []
        ;
                % XXX this needs to be fixed
            NonCanon = include_details_cc,
            Functor = Name,
            FunctorNumber = 0,
            Arity = 0,
            Arguments = []
        )
    ;
        TypeCtorRep = etcr_foreign,
        Functor = "<<foreign>>",
        FunctorNumber = 0,
        Arity = 0,
        Arguments = []
    ;

            % These types shouldn't be needed they are
            % introduced for library predicates which
            % don't apply on this backend.
        ( TypeCtorRep = etcr_hp
        ; TypeCtorRep = etcr_subgoal
        ; TypeCtorRep = etcr_ticket
        ),
        error(this_file ++ " deconstruct_2: should never occur: " ++
            string(TypeCtorRep))
    ).

    %
    % matching_du_functor(FunctorReps, Index, Term, FunctorRep, FunctorNumber)
    %
    % finds the erlang_du_functor in the list Functors which describes
    % the given Term.
    %
:- pred matching_du_functor(list(erlang_du_functor)::in, int::in, T::in,
    erlang_du_functor::out, int::out) is det.

matching_du_functor([], _, _, _, _) :-
    error(this_file ++ " matching_du_functor/2").
matching_du_functor([F | Fs], Index, T, Functor, FunctorNumber) :-
    ( matches_du_functor(T, F) ->
        Functor = F,
        FunctorNumber = Index
    ;
        matching_du_functor(Fs, Index + 1, T, Functor, FunctorNumber)
    ).

    %
    % A functor matches a term, if the first argument of the term
    % is the same erlang atom as the recorded in the edu_rep field,
    % and the size of the term matches the calculated size of term.
    %
    % Note we have to do this second step because a functor is distinguished
    % by both it's name and arity.
    %
    % Note it is possible for this code to do the wrong thing, see the comment
    % at the top of erl_unify_gen.m.
    %
:- pred matches_du_functor(T::in, erlang_du_functor::in) is semidet.

matches_du_functor(Term, Functor) :-
    check_functor(Term, Functor ^ edu_rep, Size),
    Functor ^ edu_orig_arity + 1 + extra_args(Functor) = Size.

:- pred check_functor(T::in, erlang_atom::in, int::out) is semidet.
:- pragma foreign_proc("Erlang", check_functor(Term::in, Atom::in, Size::out),
        [will_not_call_mercury, promise_pure, thread_safe], "
    case Atom of
        % This case must come before the next to handle existential types using
        % the '[|]' constructor.  In that case the Erlang term will be a tuple
        % and not a list.
        _ when is_tuple(Term) ->
            Functor = element(1, Term),
            Size = size(Term),
            SUCCESS_INDICATOR = Functor =:= Atom;

        '[|]' ->
            case Term of
                [_ | _] ->
                    SUCCESS_INDICATOR = true;
                _ ->
                    SUCCESS_INDICATOR = false
            end,
            Size = 3;

        '[]' ->
            SUCCESS_INDICATOR = Term =:= [],
            Size = 1
    end
").
check_functor(_, _, 0) :-
    semidet_unimplemented("check_functor/3").


:- some [H, T] pred is_non_empty_list(type_info::in, type_info::in,
    L::in, H::out, T::out) is semidet.

:- pragma foreign_proc("Erlang",
        is_non_empty_list(ListTI::in, ElemTI::in, L::in, H::out, T::out),
        [promise_pure, will_not_call_mercury, thread_safe], "
    % TypeInfo_for_L
    TypeInfo_for_H = ElemTI,
    TypeInfo_for_T = ListTI,
    case L of
        [] ->
            SUCCESS_INDICATOR = false,
            H = void,
            T = void;
        [Head | Tail] ->
            SUCCESS_INDICATOR = true,
            H = Head,
            T = Tail
    end
").

is_non_empty_list(_, _, _, "dummy value", "dummy value") :-
    semidet_unimplemented("is_non_empty_list/5").
    
    %
    % Calculate the number of type_info and type_class_infos which 
    % have been introduced due to existentially quantified type
    % variables on the given functor.
    %
:- func extra_args(erlang_du_functor) = int.

extra_args(Functor) = ExtraArgs :-
    MaybeExist = Functor ^ edu_exist_info,
    (
        MaybeExist = yes(ExistInfo),
            % XXX we should record the number of typeclass_constraints
            % in the exist_info
        ExtraArgs = ExistInfo ^ exist_num_plain_typeinfos +
            list.length(ExistInfo ^ exist_typeclass_constraints)
    ;
        MaybeExist = no,
        ExtraArgs = 0
    ).

    %
    % get_du_functor_arg(TypeInfo, Functor, Term, N)
    %
    % returns a univ which represent the N'th argument of the term, Term,
    % which is described the erlang_du_functor, Functor, and the type_info,
    % TypeInfo.
    %
:- func get_du_functor_arg(type_info, erlang_du_functor, T, int) = univ.

get_du_functor_arg(TypeInfo, Functor, Term, Loc) = Univ :-
    ArgInfo = list.index1_det(Functor ^ edu_arg_infos, Loc),

    MaybePTI = ArgInfo ^ du_arg_type,
    Info = yes({TypeInfo, yes({Functor, Term})}),
    ArgTypeInfo = type_info(Info, MaybePTI),

    SubTerm = get_subterm(ArgTypeInfo, Term, Loc, extra_args(Functor) + 1),
    Univ = univ(SubTerm).

    %
    % get_tuple_arg(TypeInfo, Tuple, N)
    %
    % Get the N'th argument as a univ from the tuple
    % described by the type_info.
    %
:- func get_tuple_arg(type_info, U, int) = univ.

get_tuple_arg(TypeInfo, Term, Loc) = Univ :-
    ArgTypeInfo = TypeInfo ^ var_arity_type_info_index(Loc),
    SubTerm = get_subterm(ArgTypeInfo, Term, Loc, 0),
    Univ = univ(SubTerm).

:- pred same_array_elem_type(array(T)::unused, T::unused) is det.

same_array_elem_type(_, _).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- func collapse_equivalences(type_info) = type_info.

collapse_equivalences(TypeInfo0) = TypeInfo :-
    TypeCtorInfo0 = TypeInfo0 ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo0 ^ type_ctor_rep,
    ( TypeCtorRep = etcr_eqv ->
        PtiInfo = no : pti_info(int),
        TiInfo = yes({TypeInfo0, PtiInfo}),
        EqvType = TypeCtorInfo0 ^ type_ctor_eqv_type,
        TypeInfo1 = type_info(TiInfo, EqvType),
        TypeInfo = collapse_equivalences(TypeInfo1)
    ;
        TypeInfo = TypeInfo0
    ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

num_functors(TypeDesc) = NumFunctors :-
    TypeInfo = type_info_from_type_desc(TypeDesc),
    num_functors(TypeInfo, yes(NumFunctors)).

:- pred num_functors(type_info::in, maybe(int)::out) is det.

num_functors(TypeInfo, MaybeNumFunctors) :-
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    (
        TypeCtorRep = etcr_du,
        FunctorReps = TypeCtorInfo ^ type_ctor_functors,
        MaybeNumFunctors = yes(list.length(FunctorReps))
    ;
        ( TypeCtorRep = etcr_dummy
        ; TypeCtorRep = etcr_tuple
        ),
        MaybeNumFunctors = yes(1)
    ;
        TypeCtorRep = etcr_list,
        MaybeNumFunctors = yes(2)
    ;
        ( TypeCtorRep = etcr_array
        ; TypeCtorRep = etcr_eqv
        ; TypeCtorRep = etcr_int
        ; TypeCtorRep = etcr_float
        ; TypeCtorRep = etcr_char
        ; TypeCtorRep = etcr_string
        ; TypeCtorRep = etcr_void
        ; TypeCtorRep = etcr_stable_c_pointer
        ; TypeCtorRep = etcr_c_pointer
        ; TypeCtorRep = etcr_pred
        ; TypeCtorRep = etcr_func
        ; TypeCtorRep = etcr_ref
        ; TypeCtorRep = etcr_type_desc
        ; TypeCtorRep = etcr_pseudo_type_desc
        ; TypeCtorRep = etcr_type_ctor_desc
        ; TypeCtorRep = etcr_type_info
        ; TypeCtorRep = etcr_type_ctor_info
        ; TypeCtorRep = etcr_typeclass_info
        ; TypeCtorRep = etcr_base_typeclass_info
        ; TypeCtorRep = etcr_foreign
        ),
        MaybeNumFunctors = no
    ;
        ( TypeCtorRep = etcr_hp
        ; TypeCtorRep = etcr_subgoal
        ; TypeCtorRep = etcr_ticket
        ),
        error("num_functors: type_ctor_rep not handled")
    ).

%-----------------------------------------------------------------------------%

get_functor(TypeDesc, FunctorNum, Name, Arity, ArgTypes) :-
    get_functor_with_names(TypeDesc, FunctorNum, Name, Arity, ArgTypes, _).

get_functor_with_names(TypeDesc, FunctorNum, Name, Arity, ArgTypeDescs,
        ArgNames) :-
    TypeInfo = type_info_from_type_desc(TypeDesc),
    MaybeResult = get_functor_with_names(TypeInfo, FunctorNum),
    MaybeResult = yes({Name, Arity, ArgTypeInfos, ArgNames}),
    ArgTypeDescs = type_descs_from_type_infos(ArgTypeInfos).

:- func get_functor_with_names(type_info, int) =
    maybe({string, int, list(type_info), list(string)}).

get_functor_with_names(TypeInfo, NumFunctor) = Result :-
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    (
        TypeCtorRep = etcr_du,
        FunctorReps = TypeCtorInfo ^ type_ctor_functors,
        ( matching_du_functor_number(FunctorReps, NumFunctor, FunctorRep) ->
            MaybeExistInfo = FunctorRep ^ edu_exist_info,
            (
                MaybeExistInfo = yes(_),
                Result = no
            ;
                MaybeExistInfo = no,
                ArgInfos = FunctorRep ^ edu_arg_infos,

                list.map2(
                    (pred(ArgInfo::in, ArgTypeInfo::out, ArgName::out) is det :-
                        MaybePTI = ArgInfo ^ du_arg_type,
                        Info = yes({TypeInfo, no : pti_info(int)}),
                        ArgTypeInfo = type_info(Info, MaybePTI),
                        
                        MaybeArgName = ArgInfo ^ du_arg_name,
                        (
                            MaybeArgName = yes(ArgName0),
                            ArgName = string.from_char_list(ArgName0)
                        ;
                            MaybeArgName = no,
                            ArgName = ""
                        )
                    ), ArgInfos, ArgTypes, ArgNames),

                Name = string.from_char_list(FunctorRep ^ edu_name),
                Arity = FunctorRep ^ edu_orig_arity,
                Result = yes({Name, Arity, ArgTypes, ArgNames})
            )
        ;
            Result = no
        )
    ;
        TypeCtorRep = etcr_dummy,
        Name = TypeCtorInfo ^ type_ctor_dummy_functor_name,
        Arity = 0,
        ArgTypes = [],
        ArgNames = [],
        Result = yes({Name, Arity, ArgTypes, ArgNames})
    ;
        TypeCtorRep = etcr_tuple,
        type_ctor_info_and_args(TypeInfo, _TypeCtorInfo, ArgTypes),
        Name = "{}",
        Arity = list.length(ArgTypes),
        ArgNames = list.duplicate(Arity, ""),
        Result = yes({Name, Arity, ArgTypes, ArgNames})
    ;
        TypeCtorRep = etcr_list,
        ( NumFunctor = 0 ->
            Name = "[]",
            Arity = 0,
            ArgTypes = [],
            ArgNames = [],
            Result = yes({Name, Arity, ArgTypes, ArgNames})

        ; NumFunctor = 1 ->
            ArgTypeInfo = TypeInfo ^ type_info_index(1),

            Name = "[|]",
            Arity = 2,
            ArgTypes = [ArgTypeInfo, TypeInfo],
            ArgNames = ["", ""],
            Result = yes({Name, Arity, ArgTypes, ArgNames})
        ;
            Result = no
        )
    ;
        ( TypeCtorRep = etcr_array
        ; TypeCtorRep = etcr_eqv
        ; TypeCtorRep = etcr_int
        ; TypeCtorRep = etcr_float
        ; TypeCtorRep = etcr_char
        ; TypeCtorRep = etcr_string
        ; TypeCtorRep = etcr_void
        ; TypeCtorRep = etcr_stable_c_pointer
        ; TypeCtorRep = etcr_c_pointer
        ; TypeCtorRep = etcr_pred
        ; TypeCtorRep = etcr_func
        ; TypeCtorRep = etcr_ref
        ; TypeCtorRep = etcr_type_desc
        ; TypeCtorRep = etcr_pseudo_type_desc
        ; TypeCtorRep = etcr_type_ctor_desc
        ; TypeCtorRep = etcr_type_info
        ; TypeCtorRep = etcr_type_ctor_info
        ; TypeCtorRep = etcr_typeclass_info
        ; TypeCtorRep = etcr_base_typeclass_info
        ; TypeCtorRep = etcr_foreign
        ),
        Result = no
    ;
        ( TypeCtorRep = etcr_hp
        ; TypeCtorRep = etcr_subgoal
        ; TypeCtorRep = etcr_ticket
        ),
        error("num_functors: type_ctor_rep not handled")
    ).

get_functor_ordinal(TypeDesc, FunctorNum, Ordinal) :-
    TypeInfo = type_info_from_type_desc(TypeDesc),
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    (
        TypeCtorRep = etcr_du,
        FunctorReps = TypeCtorInfo ^ type_ctor_functors,
        matching_du_functor_number(FunctorReps, FunctorNum, FunctorRep),
        Ordinal = FunctorRep ^ edu_ordinal
    ;
        TypeCtorRep = etcr_dummy,
        FunctorNum = 0,
        Ordinal = 0
    ;
        TypeCtorRep = etcr_list,
        (
            Ordinal = 0,
            FunctorNum = 0
        ;
            Ordinal = 1,
            FunctorNum = 1
        )
    ;
        TypeCtorRep = etcr_tuple,
        FunctorNum = 0,
        Ordinal = 0
    ).

get_functor_lex(TypeDesc, Ordinal, FunctorNum) :-
    TypeInfo = type_info_from_type_desc(TypeDesc),
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,
    (
        TypeCtorRep = etcr_du,
        FunctorReps = TypeCtorInfo ^ type_ctor_functors,
        matching_du_ordinal(FunctorReps, Ordinal, FunctorRep),
        FunctorNum = FunctorRep ^ edu_lex
    ;
        TypeCtorRep = etcr_dummy,
        FunctorNum = 0,
        Ordinal = 0
    ;
        TypeCtorRep = etcr_list,
        (
            Ordinal = 0,
            FunctorNum = 0
        ;
            Ordinal = 1,
            FunctorNum = 1
        )
    ;
        TypeCtorRep = etcr_tuple,
        Ordinal = 0,
        FunctorNum = 0
    ).

:- pred matching_du_ordinal(list(erlang_du_functor)::in, int::in,
    erlang_du_functor::out) is semidet.

matching_du_ordinal(Fs, Ordinal, Functor) :-
    list.index0(Fs, Ordinal, Functor),
    % Sanity check.
    ( Functor ^ edu_ordinal = Ordinal ->
        true
    ;
        error(this_file ++ " matching_du_ordinal/3")
    ).

:- pred matching_du_functor_number(list(erlang_du_functor)::in, int::in,
    erlang_du_functor::out) is semidet.

matching_du_functor_number([F | Fs], FunctorNum, Functor) :-
    ( F ^ edu_lex = FunctorNum ->
        Functor = F
    ;
        matching_du_functor_number(Fs, FunctorNum, Functor)
    ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

construct(TypeDesc, Index, Args) = Term :-
    TypeInfo = collapse_equivalences(unsafe_cast(TypeDesc)),
    TypeCtorInfo = TypeInfo ^ type_ctor_info_evaled,
    TypeCtorRep = TypeCtorInfo ^ type_ctor_rep,

    ( 
        TypeCtorRep = etcr_du,
        Result = get_functor_with_names(TypeInfo, Index),
        Result = yes({FunctorName, _FunctorArity, ArgTypes, _ArgNames}),
        check_arg_types(Args, ArgTypes),
        Term = construct_univ(TypeInfo, FunctorName, Args)
    ;
        TypeCtorRep = etcr_dummy,
        Term = construct_univ(TypeInfo, "false", [])
    ;
        TypeCtorRep = etcr_list,
        ( Index = 1, Args = [Head, Tail] ->
            compare_type_infos((=),
                univ_type_info(Head), TypeInfo ^ type_info_index(1)),
            compare_type_infos((=), univ_type_info(Tail), TypeInfo),
            Term = construct_list_cons_univ(TypeInfo, Head, Tail)
        ;
            Index = 0,
            Args = [],
            Term = construct_empty_list_univ(TypeInfo)
        )
    ;
        TypeCtorRep = etcr_tuple,
        Arity = TypeInfo ^ var_arity_type_info_arity,
        check_tuple_arg_types(TypeInfo, 1 .. Arity, Args),
        Term = construct_tuple_univ(TypeInfo, Args)
    ;
        ( TypeCtorRep = etcr_array
        ; TypeCtorRep = etcr_eqv
        ; TypeCtorRep = etcr_int
        ; TypeCtorRep = etcr_float
        ; TypeCtorRep = etcr_char
        ; TypeCtorRep = etcr_string
        ; TypeCtorRep = etcr_void
        ; TypeCtorRep = etcr_stable_c_pointer
        ; TypeCtorRep = etcr_c_pointer
        ; TypeCtorRep = etcr_pred
        ; TypeCtorRep = etcr_func
        ; TypeCtorRep = etcr_ref
        ; TypeCtorRep = etcr_type_desc
        ; TypeCtorRep = etcr_pseudo_type_desc
        ; TypeCtorRep = etcr_type_ctor_desc
        ; TypeCtorRep = etcr_type_info
        ; TypeCtorRep = etcr_type_ctor_info
        ; TypeCtorRep = etcr_typeclass_info
        ; TypeCtorRep = etcr_base_typeclass_info
        ; TypeCtorRep = etcr_foreign
        ; TypeCtorRep = etcr_hp
        ; TypeCtorRep = etcr_subgoal
        ; TypeCtorRep = etcr_ticket
        ),
        error("construct: unable to construct something of type " ++
                string(TypeCtorRep))
    ).

:- pred check_arg_types(list(univ)::in, list(type_info)::in) is semidet.

check_arg_types([], []).
check_arg_types([U | Us], [TI | TIs]) :-
    compare_type_infos((=), univ_type_info(U), TI),
    check_arg_types(Us, TIs).

:- pred check_tuple_arg_types(type_info::in,
    list(int)::in, list(univ)::in) is semidet.

check_tuple_arg_types(_, [], []).
check_tuple_arg_types(TypeInfo, [I | Is], [U | Us]) :-
    compare_type_infos((=),
        TypeInfo ^ var_arity_type_info_index(I), univ_type_info(U)),
    check_tuple_arg_types(TypeInfo, Is, Us).

:- func univ_type_info(univ) = type_info.

:- pragma foreign_proc(erlang,
        univ_type_info(Univ::in) = (TypeInfo::out),
        [will_not_call_mercury, thread_safe, promise_pure], "
    {univ_cons, TypeInfo, _} = Univ
").

univ_type_info(_) = _ :-
    private_builtin.sorry("univ_type_info").


    %
    % Construct a du type and store it in a univ.
    %
:- func construct_univ(type_info, string, list(univ)) = univ.

:- pragma foreign_proc(erlang,
        construct_univ(TypeInfo::in, Functor::in, Args::in) = (Univ::out),
        [will_not_call_mercury, thread_safe, promise_pure], "
    if
        is_binary(Functor) ->
            List = binary_to_list(Functor);
        true ->
            List = Functor
    end,
    Univ = {univ_cons, TypeInfo, list_to_tuple(
            [list_to_atom(List) | lists:map(fun univ_to_value/1, Args)])}
").

construct_univ(_, _, _) = _ :-
    private_builtin.sorry("construct_univ").

    %
    % Construct a tuple and store it in a univ.
    %
:- func construct_tuple_univ(type_info, list(univ)) = univ.

:- pragma foreign_proc(erlang,
        construct_tuple_univ(TypeInfo::in, Args::in) = (Univ::out),
        [will_not_call_mercury, thread_safe, promise_pure], "
    Univ = {univ_cons, TypeInfo,
        list_to_tuple(lists:map(fun univ_to_value/1, Args))}
").

construct_tuple_univ(_, _) = _ :-
    private_builtin.sorry("construct_tuple_univ").

    %
    % Construct a empty list and store it in a univ.
    %
:- func construct_empty_list_univ(type_info) = univ.

:- pragma foreign_proc(erlang,
        construct_empty_list_univ(TypeInfo::in) = (Univ::out),
        [will_not_call_mercury, thread_safe, promise_pure], "
    Univ = {univ_cons, TypeInfo, []}
").

construct_empty_list_univ(_) = _ :-
    private_builtin.sorry("construct_empty_list_univ").

    %
    % Construct a cons cell and store it in a univ.
    %
:- func construct_list_cons_univ(type_info, univ, univ) = univ.

:- pragma foreign_proc(erlang,
        construct_list_cons_univ(TypeInfo::in, H::in, T::in) = (Univ::out),
        [will_not_call_mercury, thread_safe, promise_pure], "
    Univ = {univ_cons, TypeInfo, [univ_to_value(H) | univ_to_value(T)]}
").

construct_list_cons_univ(_, _, _) = _ :-
    private_builtin.sorry("construct_list_cons_univ").

:- pragma foreign_code(erlang, "
    %
    % Get the value out of the univ
    % Note we assume that we've checked that the value is consistent
    % with another type_info elsewhere,
    % for example in check_arg_types and check_tuple_arg_types
    %
univ_to_value(Univ) ->
    {univ_cons, _UnivTypeInfo, Value} = Univ,
    Value.
    
").
    
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

construct_tuple_2(Args, ArgTypes, Arity) = Tuple :-
    TypeInfo = unsafe_cast(type_of(_ : {})),
    Tuple = construct_tuple_3(TypeInfo, Arity, ArgTypes, Args).

:- func construct_tuple_3(type_info, int, list(type_desc), list(univ)) = univ.

:- pragma foreign_proc(erlang,
        construct_tuple_3(TI::in,
                Arity::in, ArgTypes::in, Args::in) = (Term::out),
        [will_not_call_mercury, thread_safe, promise_pure], "

        % Get the type_ctor_info from the empty tuple type_info
        % and use that to create the correct var_arity type_info
    TCI = element(?ML_ti_type_ctor_info, TI),
    TupleTypeInfo = list_to_tuple([TCI, Arity | ArgTypes]),

    Tuple = list_to_tuple(lists:map(fun univ_to_value/1, Args)),

    Term = {univ_cons, TupleTypeInfo, Tuple}
").

construct_tuple_3(_, _, _, _) = _ :-
    private_builtin.sorry("construct_tuple_3").


%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pragma foreign_decl("Erlang", "
    % These are macros for efficiency.

    % Location of element in a type_info
    -define(ML_ti_type_ctor_info, 1).
    -define(ML_ti_var_arity, 2).

    % Location of elements in a type_ctor_info
    -define(ML_tci_arity, 1).
    -define(ML_tci_version, 2).
    -define(ML_tci_unify_pred, 3).
    -define(ML_tci_compare_pred, 4).
    -define(ML_tci_module_name, 5).
    -define(ML_tci_type_name, 6).
    -define(ML_tci_type_ctor_rep, 7).
    -define(ML_tci_details, 8).
").

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- func type_info(T::unused) = (type_info::out) is det.

:- pragma foreign_proc("Erlang",
    type_info(_T::unused) = (TypeInfo::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    TypeInfo = TypeInfo_for_T
").

type_info(_) = type_info :-
    det_unimplemented("type_info").

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- func type_ctor_info_evaled(type_info) = type_ctor_info_evaled.

:- pragma foreign_proc("Erlang",
    type_ctor_info_evaled(TypeInfo::in) = (TypeCtorInfo::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
        % 
        % If the type_info is for a type with arity 0,
        % then the type_info is already the type_ctor info.
        % We evaluate the thunk to get the actual type_ctor_info data.
        %
    if
        is_function(TypeInfo, 0) ->
            TypeCtorInfo = TypeInfo();
        true ->
            FirstElement = element(?ML_ti_type_ctor_info, TypeInfo),
            TypeCtorInfo = FirstElement()
    end
").

type_ctor_info_evaled(_) = type_ctor_info_evaled :-
    det_unimplemented("type_ctor_info_evaled").

:- func var_arity_type_info_arity(type_info) = int.

:- pragma foreign_proc("Erlang",
    var_arity_type_info_arity(TypeInfo::in) = (Arity::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Arity = element(?ML_ti_var_arity, TypeInfo)
").

var_arity_type_info_arity(_) = 0 :-
    det_unimplemented("var_arity_type_info_arity").

    %
    % TI ^ type_info_index(I)
    %
    % returns the I'th type_info from the given standard type_info TI.
    % NOTE indexes start at one.
    % 
:- func type_info_index(int, type_info) = type_info.

type_info_index(I, TI) = TI ^ unsafe_type_info_index(I + 1).

    %
    % TI ^ var_arity_type_info_index(I)
    %
    % returns the I'th type_info from the given variable arity type_info TI.
    % NOTE indexes start at one.
    % 
:- func var_arity_type_info_index(int, type_info) = type_info.

var_arity_type_info_index(I, TI) = TI ^ unsafe_type_info_index(I + 2).

    %
    % Use type_info_index or var_arity_type_info_index, never this predicate
    % directly.
    %
:- func unsafe_type_info_index(int, type_info) = type_info.

:- pragma foreign_proc("Erlang",
    unsafe_type_info_index(Index::in, TypeInfo::in) = (SubTypeInfo::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SubTypeInfo = element(Index, TypeInfo)
").

unsafe_type_info_index(_, _) = type_info :-
    det_unimplemented("unsafe_type_info_index").

:- func get_fixed_arity_arg_type_infos(type_info) = list(type_info).

:- pragma foreign_proc("Erlang",
    get_fixed_arity_arg_type_infos(TypeInfo::in) = (Args::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    if
        is_tuple(TypeInfo) ->
            [_TypeCtorInfo | Args] = tuple_to_list(TypeInfo);
        is_function(TypeInfo, 0) ->
            Args = []   % zero arity type_info
    end
").

get_fixed_arity_arg_type_infos(_) = _ :-
    private_builtin.sorry("get_fixed_arity_arg_type_infos").

:- func get_var_arity_arg_type_infos(type_info) = list(type_info).

:- pragma foreign_proc("Erlang",
    get_var_arity_arg_type_infos(TypeInfo::in) = (Args::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Args = lists:nthtail(?ML_ti_var_arity, tuple_to_list(TypeInfo))
").

get_var_arity_arg_type_infos(_) = _ :-
    private_builtin.sorry("get_var_arity_arg_type_infos").

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- func type_ctor_rep(type_ctor_info_evaled) = erlang_type_ctor_rep.

:- pragma foreign_proc("Erlang",
    type_ctor_rep(TypeCtorInfo::in) = (TypeCtorRep::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    % io:format(""type_ctor_rep(~p)~n"", [TypeCtorInfo]),
    TypeCtorRep = element(?ML_tci_type_ctor_rep, TypeCtorInfo),
    % io:format(""type_ctor_rep(~p) = ~p~n"", [TypeCtorInfo, TypeCtorRep]),
    void
").

type_ctor_rep(_) = _ :-
    % This version is only used for back-ends for which there is no
    % matching foreign_proc version.
    private_builtin.sorry("type_ctor_rep").

:- some [P] func type_ctor_unify_pred(type_ctor_info_evaled) = P.

:- pragma foreign_proc("Erlang",
    type_ctor_unify_pred(TypeCtorInfo::in) = (UnifyPred::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
        % The TypeInfo is never used so this is safe
    TypeInfo_for_P = 0,
    UnifyPred = element(?ML_tci_unify_pred, TypeCtorInfo)
").

type_ctor_unify_pred(_) = "dummy value" :-
    det_unimplemented("type_ctor_unify_pred").

:- some [P] func type_ctor_compare_pred(type_ctor_info_evaled) = P.

:- pragma foreign_proc("Erlang",
    type_ctor_compare_pred(TypeCtorInfo::in) = (ComparePred::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
        % The TypeInfo is never used so this is safe
    TypeInfo_for_P = 0,
    ComparePred = element(?ML_tci_compare_pred, TypeCtorInfo)
").

type_ctor_compare_pred(_) = "dummy value" :-
    det_unimplemented("type_ctor_compare_pred").

:- func type_ctor_module_name(type_ctor_info_evaled) = string.

:- pragma foreign_proc("Erlang",
    type_ctor_module_name(TypeCtorInfo::in) = (ModuleName::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    ModuleName = list_to_binary(element(?ML_tci_module_name, TypeCtorInfo))
").

type_ctor_module_name(_) = "dummy value" :-
    det_unimplemented("type_ctor_module_name").

:- func type_ctor_type_name(type_ctor_info_evaled) = string.

:- pragma foreign_proc("Erlang",
    type_ctor_type_name(TypeCtorInfo::in) = (TypeName::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    TypeName = list_to_binary(element(?ML_tci_type_name, TypeCtorInfo))
").

type_ctor_type_name(_) = "dummy value" :-
    det_unimplemented("type_ctor_type_name").

:- func type_ctor_arity(type_ctor_info_evaled) = int.

:- pragma foreign_proc("Erlang",
    type_ctor_arity(TypeCtorInfo::in) = (Arity::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Arity = element(?ML_tci_arity, TypeCtorInfo)
").

type_ctor_arity(_) = 0 :-
    det_unimplemented("type_ctor_arity").

:- func type_ctor_functors(type_ctor_info_evaled) = list(erlang_du_functor).

:- pragma foreign_proc("Erlang",
    type_ctor_functors(TypeCtorInfo::in) = (Functors::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Functors = element(?ML_tci_details, TypeCtorInfo)
").

type_ctor_functors(_) = [] :-
    det_unimplemented("type_ctor_functors").

:- func type_ctor_dummy_functor_name(type_ctor_info_evaled) = string.

:- pragma foreign_proc("Erlang",
    type_ctor_dummy_functor_name(TypeCtorInfo::in) = (Functor::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Functor = list_to_binary(element(?ML_tci_details, TypeCtorInfo))
").

type_ctor_dummy_functor_name(_) = "dummy value" :-
    det_unimplemented("type_ctor_dummy_functor_name").

:- func type_ctor_eqv_type(type_ctor_info_evaled) = maybe_pseudo_type_info.

:- pragma foreign_proc("Erlang",
    type_ctor_eqv_type(TypeCtorInfo::in) = (EqvType::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    EqvType = element(?ML_tci_details, TypeCtorInfo)
").

type_ctor_eqv_type(_) = plain(type_info_thunk) :-
    det_unimplemented("type_ctor_eqv_type").

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

    % Get a subterm term, given its type_info, the original term, its index
    % and the start region size.
    %
:- some [T] func get_subterm(type_info, U, int, int) = T.

get_subterm(_::in, _::in, _::in, _::in) = (42::out) :-
    det_unimplemented("get_subterm").

:- pragma foreign_proc("Erlang",
    get_subterm(TypeInfo::in, Term::in, Index::in, ExtraArgs::in) = (Arg::out),
    [promise_pure],
"
    % TypeInfo_for_U to avoid compiler warning

    TypeInfo_for_T = TypeInfo,
    case Term of
        % If there are any extra arguments then we would not use the list
        % syntax.
        [A | _] when Index =:= 1 ->
            Arg = A;
        [_ | B] when Index =:= 2 ->
            Arg = B;

        _ when is_tuple(Term) ->
            Arg = element(Index + ExtraArgs, Term)
    end
").

:- func unsafe_cast(T) = U.

:- pragma foreign_proc("Erlang",
    unsafe_cast(VarIn::in) = (VarOut::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    VarOut = VarIn
").

unsafe_cast(_) = _ :-
    % This version is only used for back-ends for which there is no
    % matching foreign_proc version.
    private_builtin.sorry("unsafe_cast").

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

    % Implement generic calls -- we could use call/N but then we would
    % have to create a real closure.
    %
    % We first give "unimplemented" definitions in Mercury, which will be
    % used by default.

:- pred semidet_call_3(P::in, T::in, U::in) is semidet.
semidet_call_3(_::in, _::in, _::in) :-
    semidet_unimplemented("semidet_call_3").

:- pred semidet_call_4(P::in, A::in, T::in, U::in) is semidet.
semidet_call_4(_::in, _::in, _::in, _::in) :-
    semidet_unimplemented("semidet_call_4").

:- pred semidet_call_5(P::in, A::in, B::in, T::in, U::in) is semidet.
semidet_call_5(_::in, _::in, _::in, _::in, _::in) :-
    semidet_unimplemented("semidet_call_5").

:- pred semidet_call_6(P::in, A::in, B::in, C::in, T::in, U::in) is semidet.
semidet_call_6(_::in, _::in, _::in, _::in, _::in, _::in) :-
    semidet_unimplemented("semidet_call_6").

:- pred semidet_call_7(P::in, A::in, B::in, C::in, D::in, T::in, U::in)
    is semidet.
semidet_call_7(_::in, _::in, _::in, _::in, _::in, _::in, _::in) :-
    semidet_unimplemented("semidet_call_7").

:- pred semidet_call_8(P::in, A::in, B::in, C::in, D::in, E::in, T::in, U::in)
    is semidet.
semidet_call_8(_::in, _::in, _::in, _::in, _::in, _::in, _::in, _::in) :-
    semidet_unimplemented("semidet_call_8").

:- pred result_call_4(P::in, comparison_result::out,
    T::in, U::in) is det.
result_call_4(_::in, (=)::out, _::in, _::in) :-
    det_unimplemented("result_call_4").

:- pred result_call_5(P::in, comparison_result::out,
    A::in, T::in, U::in) is det.
result_call_5(_::in, (=)::out, _::in, _::in, _::in) :-
    det_unimplemented("comparison_result").

:- pred result_call_6(P::in, comparison_result::out,
    A::in, B::in, T::in, U::in) is det.
result_call_6(_::in, (=)::out, _::in, _::in, _::in, _::in) :-
    det_unimplemented("comparison_result").

:- pred result_call_7(P::in, comparison_result::out,
    A::in, B::in, C::in, T::in, U::in) is det.
result_call_7(_::in, (=)::out, _::in, _::in, _::in, _::in, _::in) :-
    det_unimplemented("comparison_result").

:- pred result_call_8(P::in, comparison_result::out,
    A::in, B::in, C::in, D::in, T::in, U::in) is det.
result_call_8(_::in, (=)::out, _::in, _::in, _::in, _::in, _::in, _::in) :-
    det_unimplemented("comparison_result").

:- pred result_call_9(P::in, comparison_result::out,
    A::in, B::in, C::in, D::in, E::in, T::in, U::in) is det.
result_call_9(_::in, (=)::out, _::in, _::in, _::in, _::in, _::in,
        _::in, _::in) :-
    det_unimplemented("result_call_9").

:- pred semidet_unimplemented(string::in) is semidet.

semidet_unimplemented(S) :-
    ( semidet_succeed ->
        error(this_file ++ ": unimplemented: " ++ S)
    ;
        semidet_succeed
    ).

:- pred det_unimplemented(string::in) is det.

det_unimplemented(S) :-
    ( semidet_succeed ->
        error(this_file ++ ": unimplemented: " ++ S)
    ;
        true
    ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

    % We override the above definitions in the Erlang backend.

:- pragma foreign_proc("Erlang",
    semidet_call_3(Pred::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SUCCESS_INDICATOR = case Pred(X, Y) of {} -> true; fail -> false end
").
:- pragma foreign_proc("Erlang",
    semidet_call_4(Pred::in, A::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SUCCESS_INDICATOR = case Pred(A, X, Y) of {} -> true; fail -> false end
").
:- pragma foreign_proc("Erlang",
    semidet_call_5(Pred::in, A::in, B::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SUCCESS_INDICATOR = case Pred(A, B, X, Y) of {} -> true; fail -> false end
").
:- pragma foreign_proc("Erlang",
    semidet_call_6(Pred::in, A::in, B::in, C::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SUCCESS_INDICATOR =
        case Pred(A, B, C, X, Y) of
            {} -> true;
            fail -> false
        end
").
:- pragma foreign_proc("Erlang",
    semidet_call_7(Pred::in, A::in, B::in, C::in, D::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SUCCESS_INDICATOR =
        case Pred(A, B, C, D, X, Y) of
            {} -> true;
            fail -> false
        end
").
:- pragma foreign_proc("Erlang",
    semidet_call_8(Pred::in, A::in, B::in, C::in, D::in, E::in,
        X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SUCCESS_INDICATOR =
        case Pred(A, B, C, D, E, X, Y) of
            {} -> true;
            fail -> false
        end
").

:- pragma foreign_proc("Erlang",
    result_call_4(Pred::in, Res::out, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Res = Pred(X, Y)
").

:- pragma foreign_proc("Erlang",
    result_call_5(Pred::in, Res::out, A::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Res = Pred(A, X, Y)
").
:- pragma foreign_proc("Erlang",
    result_call_6(Pred::in, Res::out, A::in, B::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Res = Pred(A, B, X, Y)
").
:- pragma foreign_proc("Erlang",
    result_call_7(Pred::in, Res::out, A::in, B::in, C::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Res = Pred(A, B, C, X, Y)
").
:- pragma foreign_proc("Erlang",
    result_call_8(Pred::in, Res::out, A::in, B::in, C::in, D::in, X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Res = Pred(A, B, C, D, X, Y)
").
:- pragma foreign_proc("Erlang",
    result_call_9(Pred::in, Res::out, A::in, B::in, C::in, D::in, E::in,
        X::in, Y::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Res = Pred(A, B, C, D, E, X, Y)
").

%-----------------------------------------------------------------------------%

:- pred det_dynamic_cast(T::in, U::out) is det.

det_dynamic_cast(Term, Actual) :-
    type_to_univ(Term, Univ),
    det_univ_to_type(Univ, Actual).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
%
% These types have to be kept in sync with the corresponding types in
% compiler/erlang_rtti.m
%

:- import_module maybe.

:- type erlang_atom.
:- pragma foreign_type("Erlang", erlang_atom, "").
:- type erlang_atom ---> erlang_atom.

:- type erlang_du_functor
    --->    erlang_du_functor(
                edu_name            :: list(char),
                edu_orig_arity      :: int,
                edu_ordinal         :: int,
                edu_lex             :: int,
                edu_rep             :: erlang_atom,
                edu_arg_infos       :: list(du_arg_info),
                edu_exist_info      :: maybe(exist_info)
            ).

:- type du_arg_info
    --->    du_arg_info(
                du_arg_name         :: maybe(list(char)),
                du_arg_type         :: maybe_pseudo_type_info
            ).

:- type exist_info
    --->    exist_info(
                exist_num_plain_typeinfos   :: int,
                exist_num_typeinfos_in_tcis :: int,
                exist_typeclass_constraints :: list(tc_constraint),
                exist_typeinfo_locns        :: list(exist_typeinfo_locn)
            ).

:- type tc_constraint
    --->    tc_constraint(
                tcc_class_name          :: tc_name,
                tcc_types               :: list(tc_type)
            ).

:- type exist_typeinfo_locn
    --->    plain_typeinfo(
                int         % The typeinfo is stored directly in the cell,
                            % at this offset.
            )
    ;       typeinfo_in_tci(
                int,        % The typeinfo is stored indirectly in the
                            % typeclass info stored at this offset in the cell.

                int         % To find the typeinfo inside the typeclass info
                            % structure, give this integer to the
                            % MR_typeclass_info_type_info macro.
            ).

:- type tc_name
    --->    tc_name(
                tcn_module              :: module_name,
                tcn_name                :: list(char),
                tcn_arity               :: int
            ).

:- type module_name == sym_name.

:- type sym_name
    --->    unqualified(list(char))
    ;       qualified(sym_name, list(char)).

:- type tc_type == maybe_pseudo_type_info.

:- type maybe_pseudo_type_info
    --->    pseudo(pseudo_type_info_thunk)
    ;       plain(type_info_thunk).

        
%-----------------------------------------------------------------------------%

:- type ti_info(T) == maybe({type_info, pti_info(T)}).
:- type pti_info(T) == maybe({erlang_du_functor, T}).

    %
    % Given a plain or pseudo type_info, return the concrete type_info
    % which represents the type.
    %
:- func type_info(ti_info(T), maybe_pseudo_type_info) = type_info.

type_info(Info, MaybePTI) = TypeInfo :-
    (
        MaybePTI = pseudo(PseudoThunk),
        (
            Info = yes({ParentTypeInfo, MaybeFunctorAndTerm}),
            TypeInfo = eval_pseudo_type_info(
                ParentTypeInfo, MaybeFunctorAndTerm, PseudoThunk)
        ;
            Info = no,
            error("type_info/2: missing parent type_info")
        )
    ;
        MaybePTI = plain(PlainThunk),
        TypeInfo = eval_type_info_thunk(Info, PlainThunk)
    ).

:- func eval_pseudo_type_info(type_info,
    pti_info(T), pseudo_type_info_thunk) = type_info.

eval_pseudo_type_info(ParentTypeInfo, MaybeFunctorAndTerm, Thunk) = TypeInfo :-
    EvalResult = eval_pseudo_type_info_thunk(Thunk),
    (
        EvalResult = universal_type_info(N),
        TypeInfo = ParentTypeInfo ^ type_info_index(N)
    ;
        EvalResult = existential_type_info(N),
        (
            MaybeFunctorAndTerm = yes({Functor, Term}),
            TypeInfo = exist_type_info(ParentTypeInfo, Functor, Term, N)
        ;
            MaybeFunctorAndTerm = no,
            error("eval_pseudo_type_info requires a functor rep")
        )
    ;
        EvalResult = pseudo_type_info(PseudoTypeInfo),
        Info = yes({ParentTypeInfo, MaybeFunctorAndTerm}),
        TypeInfo = eval_type_info(Info, unsafe_cast(PseudoTypeInfo))
    ).

:- func exist_type_info(type_info, erlang_du_functor, T, int) = type_info.

exist_type_info(TypeInfo, Functor, Term, N) = ArgTypeInfo :-
    MaybeExist = Functor ^ edu_exist_info,
    (
        MaybeExist = yes(ExistInfo),
        ExistLocn = list.index1_det(ExistInfo ^ exist_typeinfo_locns, N),
        (
            ExistLocn = plain_typeinfo(X),

                % plain_typeinfo index's start at 0, so we need to
                % add two to get to the first index.
            ArgTypeInfo = unsafe_cast(get_subterm(TypeInfo, Term, X, 2))
        ;
            ExistLocn = typeinfo_in_tci(A, B),

                % A starts at index 0 and measures from the start
                % of the list of plain type_infos
                %
                % B starts at index 1 and measures from the start
                % of the type_class_info
                %
                % Hence the addition of two extra arguments to find the
                % type_class_info and then the addition of one extra
                % arg to find the type_info in the type_class_info.
                %
                % Note it's safe to pass a bogus type_info to
                % get_subterm because we never use the returned
                % type_info.
                %
            Bogus = TypeInfo,
            TypeClassInfo = get_subterm(Bogus, Term, A, 2),
            ArgTypeInfo = unsafe_cast(
                get_subterm(Bogus, TypeClassInfo, B, 1))
        )
    ;
        MaybeExist = no,
        error(this_file ++ " exist_type_info: no exist info")
    ).

:- func eval_type_info_thunk(ti_info(T), type_info_thunk) = type_info.

eval_type_info_thunk(I, Thunk) = TypeInfo :-
    TI = eval_type_info_thunk_2(Thunk),
    TypeInfo = eval_type_info(I, TI).

:- func eval_type_info(ti_info(T), type_info) = type_info.

eval_type_info(I, TI) = TypeInfo :-
    TypeCtorInfo = TI ^ type_ctor_info_evaled,
    ( type_ctor_is_variable_arity(TypeCtorInfo) ->
        Arity = TI ^ var_arity_type_info_arity,
        ArgTypeInfos = list.map(var_arity_arg_type_info(I, TI), 1 .. Arity),
        TypeInfo = create_var_arity_type_info(TypeCtorInfo, Arity, ArgTypeInfos)
    ; TypeCtorInfo ^ type_ctor_arity = 0 ->
        TypeInfo = TI
    ;
        Arity = TypeCtorInfo ^ type_ctor_arity,
        ArgTypeInfos = list.map(arg_type_info(I, TI), 1 .. Arity),
        TypeInfo = create_type_info(TypeCtorInfo, ArgTypeInfos)
    ).


:- func var_arity_arg_type_info(ti_info(T), TypeInfo, int) = type_info.

var_arity_arg_type_info(Info, TypeInfo, Index) = ArgTypeInfo :-
    MaybePTI = TypeInfo ^ var_arity_pseudo_type_info_index(Index),
    ArgTypeInfo = type_info(Info, MaybePTI).

:- func arg_type_info(ti_info(T), TypeInfo, int) = type_info.

arg_type_info(Info, TypeInfo, Index) = ArgTypeInfo :-
    MaybePTI = TypeInfo ^ pseudo_type_info_index(Index),
    ArgTypeInfo = type_info(Info, MaybePTI).

%-----------------------------------------------------------------------------%

:- func create_type_info(type_ctor_info_evaled, list(type_info)) = type_info.

:- pragma foreign_proc("Erlang",
        create_type_info(TypeCtorInfo::in, Args::in) = (TypeInfo::out),
        [promise_pure, will_not_call_mercury, thread_safe], "
    % TypeCtorInfo was evaluated by eval_type_info, so we wrap it back up in a
    % thunk.  It may or may not be costly to do this, when we could have
    % already used the one we extracted out of the type_info.
    TypeCtorInfoFun = fun() -> TypeCtorInfo end,
    TypeInfo =
        case Args of
            [] ->
                TypeCtorInfoFun;
            [_|_] ->
                list_to_tuple([TypeCtorInfoFun | Args])
        end
").

create_type_info(_, _) = type_info :-
    det_unimplemented("create_type_info/2").
    

:- func create_var_arity_type_info(type_ctor_info_evaled,
    int, list(type_info)) = type_info.

:- pragma foreign_proc("Erlang",
        create_var_arity_type_info(TypeCtorInfo::in,
            Arity::in, Args::in) = (TypeInfo::out),
        [promise_pure, will_not_call_mercury, thread_safe], "
    % TypeCtorInfo was evaluated by eval_type_info, so we wrap it back up in a
    % thunk.  It may or may not be costly to do this, when we could have
    % already used the one we extracted out of the type_info.
    TypeCtorInfoFun = fun() -> TypeCtorInfo end,
    TypeInfo = list_to_tuple([TypeCtorInfoFun, Arity | Args])
").

create_var_arity_type_info(_, _, _) = type_info :-
    det_unimplemented("create_var_arity_type_info/3").
    
%-----------------------------------------------------------------------------%

    %
    % A pseudo_type_info can be represented in one of three ways
    % For a type with arity 0
    %   TypeCtorInfo
    % a type with arity > 0
    %   { TypeCtorInfo, PseudoTypeInfo0, ..., PseudoTypeInfoN }
    % a type with variable arity of size N
    %   { TypeCtorInfo, N, PseudoTypeInfo0, ..., PseudoTypeInfoN }
    %   
:- type pseudo_type_info.
:- pragma foreign_type("Erlang", pseudo_type_info, "").
:- type pseudo_type_info ---> pseudo_type_info.

    %
    % TI ^ pseudo_type_info_index(I)
    %
    % returns the I'th maybe_pseudo_type_info from the given type_info
    % or pseudo_type_info
    % NOTE indexes start at one.
    % 
:- func pseudo_type_info_index(int, T) = maybe_pseudo_type_info.

pseudo_type_info_index(I, TI) = TI ^ unsafe_pseudo_type_info_index(I + 1).

    %
    % TI ^ var_arity_pseudo_type_info_index(I)
    %
    % NOTE indexes start at one.
    % 
:- func var_arity_pseudo_type_info_index(int, T) = maybe_pseudo_type_info.

var_arity_pseudo_type_info_index(I, TI) = 
    TI ^ unsafe_pseudo_type_info_index(I + 2).

    %
    % Use pseudo_type_info_index or var_arity_pseudo_type_info_index, never
    % this predicate directly.
    %
:- func unsafe_pseudo_type_info_index(int, T) = maybe_pseudo_type_info.

:- pragma foreign_proc("Erlang",
    unsafe_pseudo_type_info_index(Index::in, TypeInfo::in) = (Maybe::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    Maybe = element(Index, TypeInfo),
    %io:format(""unsafe_pseudo_type_info_index(~p, ~p) = ~p~n"",
    %    [Index, TypeInfo, Maybe]),
    void
").

unsafe_pseudo_type_info_index(_, _) = pseudo(pseudo_type_info_thunk) :-
    det_unimplemented("unsafe_pseudo_type_info_index").

%-----------------------------------------------------------------------------%

:- type pseudo_type_info_thunk.
:- pragma foreign_type("Erlang", pseudo_type_info_thunk, "").
:- type pseudo_type_info_thunk ---> pseudo_type_info_thunk.

:- type evaluated_pseudo_type_info_thunk
    --->    universal_type_info(int)
    ;       existential_type_info(int)
    ;       pseudo_type_info(pseudo_type_info)
    .

:- func eval_pseudo_type_info_thunk(pseudo_type_info_thunk) =
    evaluated_pseudo_type_info_thunk.

:- pragma foreign_proc("Erlang",
        eval_pseudo_type_info_thunk(Thunk::in) = (TypeInfo::out),
        [will_not_call_mercury, thread_safe, promise_pure], "
    MaybeTypeInfo = Thunk(),
    TypeInfo =
        if 
            is_integer(MaybeTypeInfo), MaybeTypeInfo < 512 ->
                { universal_type_info, MaybeTypeInfo };
            is_integer(MaybeTypeInfo) ->
                { existential_type_info, MaybeTypeInfo - 512 };
            true ->
                { pseudo_type_info, MaybeTypeInfo }
        end,
    % io:format(""eval_pseudo_type_info: ~p~n"", [TypeInfo]),
    void
").
eval_pseudo_type_info_thunk(X) = erlang_rtti_implementation.unsafe_cast(X) :-
    det_unimplemented("eval_pseudo_type_info/1").

%-----------------------------------------------------------------------------%

:- type type_info_thunk.
:- pragma foreign_type("Erlang", type_info_thunk, "").
:- type type_info_thunk ---> type_info_thunk.

:- func eval_type_info_thunk_2(type_info_thunk) = type_info.
:- pragma foreign_proc("Erlang", eval_type_info_thunk_2(Thunk::in) = (TypeInfo::out),
        [will_not_call_mercury, thread_safe, promise_pure], "
    TypeInfo = Thunk(),
    % io:format(""eval_type_info_thunk_2(~p) = ~p~n"", [Thunk, TypeInfo]),
    void
").
eval_type_info_thunk_2(X) = erlang_rtti_implementation.unsafe_cast(X) :-
    det_unimplemented("eval_type_info_thunk_2/1").

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- interface.
:- pred is_erlang_backend is semidet.
:- implementation.

:- pragma foreign_proc("Erlang", is_erlang_backend,
        [will_not_call_mercury, thread_safe, promise_pure], "
    SUCCESS_INDICATOR = true
").

is_erlang_backend :-
    semidet_fail.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "erlang_rtti_implementation.m".

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%