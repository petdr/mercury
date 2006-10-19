%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 1996-2001, 2003-2006 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: check_typeclass.m.
% Author: dgj.
%
% This module checks conformance of instance declarations to the typeclass
% declaration. It takes various steps to do this.
%
% First, for every method of every instance it generates a new pred
% whose types and modes are as expected by the typeclass declaration and
% whose body just calls the implementation provided by the instance
% declaration.
%
% eg. given the declarations:
%
% :- typeclass c(T) where [
%   pred m(T::in, T::out) is semidet
% ].
%
% :- instance c(int) where [
%   pred(m/2) is my_m
% ].
%
% The correctness of my_m/2 as an implementation of m/2 is checked by
% generating the new predicate:
%
% :- pred 'implementation of m/2'(int::in, int::out) is semidet.
%
% 'implementation of m/2'(HeadVar_1, HeadVar_2) :-
%   my_m(HeadVar_1, HeadVar_2).
%
% By generating the new pred, we check the instance method for type, mode,
% determinism and uniqueness correctness since the generated pred is checked
% in each of those passes too.
%
% Second, this pass checks that all superclass constraints are satisfied
% by the instance declaration.  To do this it attempts to perform context
% reduction on the typeclass constraints, using the instance constraints
% as assumptions.
%
% Third, typeclass constraints on predicate and function declarations are
% checked for ambiguity, taking into consideration the information
% provided by functional dependencies.
%
% Fourth, all visible instances are checked for range-restrictedness and
% mutual consistency, with respect to any functional dependencies.  This
% doesn't necessarily catch all cases of inconsistent instances, however,
% since in general that cannot be done until link time.  We try to catch
% as many cases as possible here, though, since we can give better error
% messages.
%
% This module also checks for cycles in the typeclass hierarchy, and checks
% that each abstract instance has a corresponding concrete instance.
%
% This pass fills in the super class proofs and instance method pred/proc ids
% in the instance table of the HLDS, and fills in the fundeps_ancestors in
% the class table.
%
%---------------------------------------------------------------------------%

:- module check_hlds.check_typeclass.
:- interface.

:- import_module hlds.
:- import_module hlds.hlds_module.
:- import_module hlds.make_hlds.
:- import_module parse_tree.
:- import_module parse_tree.error_util.

:- import_module list.

:- pred check_typeclasses(module_info::in, module_info::out,
    make_hlds_qual_info::in, make_hlds_qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.typeclasses.
:- import_module hlds.hlds_code_util.
:- import_module hlds.hlds_data.
:- import_module hlds.hlds_error_util.
:- import_module hlds.hlds_pred.
:- import_module hlds.hlds_rtti.
:- import_module hlds.passes_aux.
:- import_module hlds.pred_table.
:- import_module libs.
:- import_module libs.compiler_util.
:- import_module libs.globals.
:- import_module libs.options.
:- import_module mdbcomp.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.mercury_to_mercury.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_out.
:- import_module parse_tree.prog_type.
:- import_module parse_tree.prog_type_subst.
:- import_module parse_tree.prog_util.

:- import_module assoc_list.
:- import_module bool.
:- import_module io.
:- import_module map.
:- import_module maybe.
:- import_module multi_map.
:- import_module pair.
:- import_module set.
:- import_module solutions.
:- import_module string.
:- import_module svmap.
:- import_module svmulti_map.
:- import_module svset.
:- import_module term.
:- import_module varset.

%---------------------------------------------------------------------------%

check_typeclasses(!ModuleInfo, !QualInfo, !Specs) :-
    module_info_get_globals(!.ModuleInfo, Globals),
    globals.lookup_bool_option(Globals, verbose, Verbose),
    trace [io(!IO1)] (
        maybe_write_string(Verbose, "% Checking typeclass instances...\n",
            !IO1)
    ),
    check_instance_decls(!ModuleInfo, !QualInfo, !Specs),

    trace [io(!IO2)] (
        maybe_write_string(Verbose, "% Checking for cyclic classes...\n",
            !IO2)
    ),
    check_for_cyclic_classes(!ModuleInfo, !Specs),

    trace [io(!IO3)] (
    maybe_write_string(Verbose,
        "% Checking for missing concrete instances...\n", !IO3)
    ),
    check_for_missing_concrete_instances(!ModuleInfo, !Specs),

    trace [io(!IO4)] (
    maybe_write_string(Verbose,
        "% Checking functional dependencies on instances...\n", !IO4)
    ),
    check_functional_dependencies(!ModuleInfo, !Specs),

    trace [io(!IO5)] (
        maybe_write_string(Verbose, "% Checking typeclass constraints...\n",
            !IO5)
    ),
    check_typeclass_constraints(!ModuleInfo, !Specs).

%---------------------------------------------------------------------------%

:- pred check_instance_decls(module_info::in, module_info::out,
    make_hlds_qual_info::in, make_hlds_qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_instance_decls(!ModuleInfo, !QualInfo, !Specs) :-
    module_info_get_class_table(!.ModuleInfo, ClassTable),
    module_info_get_instance_table(!.ModuleInfo, InstanceTable0),
    map.to_assoc_list(InstanceTable0, InstanceList0),
    list.map_foldl3(check_one_class(ClassTable), InstanceList0, InstanceList,
        !ModuleInfo, !QualInfo, [], NewSpecs),
    module_info_get_globals(!.ModuleInfo, Globals),
    Errors = contains_errors(Globals, NewSpecs),
    (
        Errors = no,
        map.from_assoc_list(InstanceList, InstanceTable),
        module_info_set_instance_table(InstanceTable, !ModuleInfo)
    ;
        Errors = yes
    ),
    !:Specs = NewSpecs ++ !.Specs.

    % Check all the instances of one class.
    %
:- pred check_one_class(class_table::in,
    pair(class_id, list(hlds_instance_defn))::in,
    pair(class_id, list(hlds_instance_defn))::out,
    module_info::in, module_info::out,
    make_hlds_qual_info::in, make_hlds_qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_one_class(ClassTable, ClassId - InstanceDefns0, ClassId - InstanceDefns,
        !ModuleInfo, !QualInfo, !Specs) :-
    map.lookup(ClassTable, ClassId, ClassDefn),
    ClassDefn = hlds_class_defn(ImportStatus, SuperClasses, _FunDeps,
        _Ancestors, ClassVars, _Kinds, Interface, ClassInterface,
        ClassVarSet, TermContext),
    (
        status_defined_in_this_module(ImportStatus) = yes,
        Interface = class_interface_abstract
    ->
        ClassId = class_id(ClassName, ClassArity),
        Pieces = [words("Error: no definition for typeclass"),
            sym_name_and_arity(ClassName / ClassArity), nl],
        Msg = simple_msg(TermContext, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_type_check, [Msg]),
        !:Specs = [Spec | !.Specs],
        InstanceDefns = InstanceDefns0
    ;
        solutions.solutions(
            ( pred(PredId::out) is nondet :-
                list.member(ClassProc, ClassInterface),
                ClassProc = hlds_class_proc(PredId, _)
            ),
            PredIds),
        list.map_foldl3(
            check_class_instance(ClassId, SuperClasses, ClassVars,
                ClassInterface, Interface, ClassVarSet, PredIds),
            InstanceDefns0, InstanceDefns,
            !ModuleInfo, !QualInfo, !Specs)
    ).

    % Check one instance of one class.
    %
:- pred check_class_instance(class_id::in, list(prog_constraint)::in,
    list(tvar)::in, hlds_class_interface::in, class_interface::in,
    tvarset::in, list(pred_id)::in,
    hlds_instance_defn::in, hlds_instance_defn::out,
    module_info::in, module_info::out,
    make_hlds_qual_info::in, make_hlds_qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_class_instance(ClassId, SuperClasses, Vars, HLDSClassInterface,
        ClassInterface, ClassVarSet, PredIds, !InstanceDefn,
        !ModuleInfo, !QualInfo, !Specs):-
    % Check conformance of the instance body.
    !.InstanceDefn = hlds_instance_defn(_, _, TermContext, _, _,
        InstanceBody, _, _, _),
    (
        InstanceBody = instance_body_abstract
    ;
        InstanceBody = instance_body_concrete(InstanceMethods),
        check_concrete_class_instance(ClassId, Vars,
            HLDSClassInterface, ClassInterface,
            PredIds, TermContext, InstanceMethods,
            !InstanceDefn, !ModuleInfo, !QualInfo, !Specs)
    ),
    % Check that the superclass constraints are satisfied for the types
    % in this instance declaration.
    check_superclass_conformance(ClassId, SuperClasses, Vars, ClassVarSet,
        !.ModuleInfo, !InstanceDefn, !Specs).

:- pred check_concrete_class_instance(class_id::in, list(tvar)::in,
    hlds_class_interface::in, class_interface::in,
    list(pred_id)::in, term.context::in,
    instance_methods::in, hlds_instance_defn::in, hlds_instance_defn::out,
    module_info::in, module_info::out,
    make_hlds_qual_info::in, make_hlds_qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_concrete_class_instance(ClassId, Vars, HLDSClassInterface,
        ClassInterface, PredIds, TermContext, InstanceMethods, !InstanceDefn,
        !ModuleInfo, !QualInfo, !Specs) :-
    (
        ClassInterface = class_interface_abstract,
        ClassId = class_id(ClassName, ClassArity),
        Pieces = [words("Error: instance declaration for abstract typeclass"),
            sym_name_and_arity(ClassName / ClassArity), suffix("."), nl],
        Msg = simple_msg(TermContext, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_type_check, [Msg]),
        !:Specs = [Spec | !.Specs]
    ;
        ClassInterface = class_interface_concrete(_),
        InstanceCheckInfo0 = instance_check_info(!.InstanceDefn,
            [], !.ModuleInfo, !.QualInfo),
        list.foldl2(check_instance_pred(ClassId, Vars, HLDSClassInterface),
            PredIds, InstanceCheckInfo0, InstanceCheckInfo, !Specs),
        InstanceCheckInfo = instance_check_info(!:InstanceDefn,
            RevInstanceMethods, !:ModuleInfo, !:QualInfo),

        % We need to make sure that the MaybePredProcs field is set to yes(_)
        % after this pass. Normally that will be handled by
        % check_instance_pred, but we also need to handle it below,
        % in case the class has no methods.
        MaybePredProcs1 = !.InstanceDefn ^ instance_hlds_interface,
        (
            MaybePredProcs1 = yes(_),
            MaybePredProcs = MaybePredProcs1
        ;
            MaybePredProcs1 = no,
            MaybePredProcs = yes([])
        ),

        % Make sure the list of instance methods is in the same order
        % as the methods in the class definition. intermod.m relies on this.
        OrderedInstanceMethods = list.reverse(RevInstanceMethods),

        !:InstanceDefn = !.InstanceDefn ^ instance_hlds_interface
            := MaybePredProcs,
        !:InstanceDefn = !.InstanceDefn ^ instance_body
            := instance_body_concrete(OrderedInstanceMethods),

        % Check if there are any instance methods left over, which did not
        % match any of the methods from the class interface.
        Context = !.InstanceDefn ^ instance_context,
        check_for_bogus_methods(InstanceMethods, ClassId, PredIds,
            Context, !.ModuleInfo, !Specs)
    ).

    % Check if there are any instance methods left over, which did not match
    % any of the methods from the class interface. If so, add an appropriate
    % error message to the list of error messages.
    %
:- pred check_for_bogus_methods(instance_methods::in, class_id::in,
    list(pred_id)::in, prog_context::in, module_info::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_for_bogus_methods(InstanceMethods, ClassId, ClassPredIds, Context,
        ModuleInfo, !Specs) :-
    module_info_get_predicate_table(ModuleInfo, PredTable),
    DefnIsOK = (pred(Method::in) is semidet :-
        % Find this method definition's p/f, name, arity
        Method = instance_method(MethodPredOrFunc, MethodName, _MethodDefn,
            MethodArity, _Context),
        % Search for pred_ids matching that p/f, name, arity, and succeed
        % if the method definition p/f, name, and arity matches at least one
        % of the methods from the class interface.
        adjust_func_arity(MethodPredOrFunc, MethodArity, MethodPredArity),
        predicate_table_search_pf_sym_arity(PredTable, is_fully_qualified,
            MethodPredOrFunc, MethodName, MethodPredArity, MatchingPredIds),
        some [PredId] (
            list.member(PredId, MatchingPredIds),
            list.member(PredId, ClassPredIds)
        )
    ),
    list.filter(DefnIsOK, InstanceMethods, _OKInstanceMethods,
        BogusInstanceMethods),
    (
        BogusInstanceMethods = []
    ;
        BogusInstanceMethods = [_ | _],
        % There were one or more bogus methods.
        % Construct an appropriate error message.
        ClassId = class_id(ClassName, ClassArity),
        ErrorMsgStart =  [
            words("In instance declaration for"),
            sym_name_and_arity(ClassName / ClassArity),
            suffix(":"),
            words("incorrect method name(s):")
        ],
        ErrorMsgBody0 = list.map(format_method_name, BogusInstanceMethods),
        ErrorMsgBody1 = list.condense(ErrorMsgBody0),
        ErrorMsgBody = list.append(ErrorMsgBody1, [suffix(".")]),
        Pieces = ErrorMsgStart ++ ErrorMsgBody,
        Msg = simple_msg(Context, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_type_check, [Msg]),
        !:Specs = [Spec | !.Specs]
    ).

:- func format_method_name(instance_method) = format_components.

format_method_name(Method) = MethodName :-
    Method = instance_method(PredOrFunc, Name, _Defn, Arity, _Context),
    adjust_func_arity(PredOrFunc, Arity, PredArity),
    MethodName = [p_or_f(PredOrFunc), sym_name_and_arity(Name / PredArity)].

%----------------------------------------------------------------------------%

:- type instance_check_info
    --->    instance_check_info(
                hlds_instance_defn,
                instance_methods,   % The instance methods in reverse
                                    % order of the methods in the class
                                    % declaration.
                module_info,
                make_hlds_qual_info
            ).

    % This structure holds the information about a particular instance
    % method.
:- type instance_method_info
    --->    instance_method_info(
                im_module_info          :: module_info,
                im_qual_info            :: make_hlds_qual_info,

                % Name that the introduced pred should be given.
                im_introduced_pred_name :: sym_name,

                % Arity of the method. (For funcs, this is the original arity,
                % not the arity as a predicate.)
                im_method_arity         :: arity,

                % Existentially quantified type variables.
                im_existq_tvars         :: existq_tvars,

                % Expected types of arguments.
                im_expected_arg_types   :: list(mer_type),

                % Constraints from class method.
                im_method_constraints   :: prog_constraints,

                % Modes and determinisms of the required procs.
                im_modes_and_detism     :: list(modes_and_detism),

                im_tvarset              :: tvarset,

                % Import status of instance decl.
                im_import_status        :: import_status,

                % Is method pred or func?
                im_pred_or_func         :: pred_or_func
            ).

%----------------------------------------------------------------------------%

    % Check one pred in one instance of one class.
    %
:- pred check_instance_pred(class_id::in, list(tvar)::in,
    hlds_class_interface::in, pred_id::in,
    instance_check_info::in, instance_check_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_instance_pred(ClassId, ClassVars, ClassInterface, PredId,
        !InstanceCheckInfo, !Specs) :-
    !.InstanceCheckInfo = instance_check_info(InstanceDefn0,
        OrderedMethods0, ModuleInfo0, QualInfo0),
    solutions.solutions((pred(ProcId::out) is nondet :-
            list.member(ClassProc, ClassInterface),
            ClassProc = hlds_class_proc(PredId, ProcId)
        ), ProcIds),
    module_info_pred_info(ModuleInfo0, PredId, PredInfo),
    pred_info_get_arg_types(PredInfo, ArgTypeVars, ExistQVars, ArgTypes),
    pred_info_get_class_context(PredInfo, ClassContext0),
    pred_info_get_markers(PredInfo, Markers0),
    remove_marker(marker_class_method, Markers0, Markers),
    % The first constraint in the class context of a class method is always
    % the constraint for the class of which it is a member. Seeing that we are
    % checking an instance declaration, we don't check that constraint...
    % the instance declaration itself satisfies it!
    ( ClassContext0 = constraints([_ | OtherUnivCs], ExistCs) ->
        UnivCs = OtherUnivCs,
        ClassContext = constraints(UnivCs, ExistCs)
    ;
        unexpected(this_file,
            "check_instance_pred: no constraint on class method")
    ),
    MethodName0 = pred_info_name(PredInfo),
    PredModule = pred_info_module(PredInfo),
    MethodName = qualified(PredModule, MethodName0),
    PredArity = pred_info_orig_arity(PredInfo),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    adjust_func_arity(PredOrFunc, Arity, PredArity),
    pred_info_get_procedures(PredInfo, ProcTable),
    list.map(
        (pred(TheProcId::in, ModesAndDetism::out) is det :-
            map.lookup(ProcTable, TheProcId, ProcInfo),
            proc_info_get_argmodes(ProcInfo, Modes),
            % If the determinism declaration on the method was omitted,
            % then make_hlds will have already issued an error message,
            % so don't complain here.
            proc_info_get_declared_determinism(ProcInfo, MaybeDetism),
            proc_info_get_inst_varset(ProcInfo, InstVarSet),
            ModesAndDetism = modes_and_detism(Modes, InstVarSet, MaybeDetism)
        ), ProcIds, ArgModes),

    InstanceDefn0 = hlds_instance_defn(_, Status, _, _, InstanceTypes,
        _, _, _, _),

    % Work out the name of the predicate that we will generate
    % to check this instance method.
    make_introduced_pred_name(ClassId, MethodName, Arity,
        InstanceTypes, PredName),

    MethodInfo0 = instance_method_info(ModuleInfo0, QualInfo0, PredName,
        Arity, ExistQVars, ArgTypes, ClassContext, ArgModes,
        ArgTypeVars, Status, PredOrFunc),

    check_instance_pred_procs(ClassId, ClassVars, MethodName, Markers,
        InstanceDefn0, InstanceDefn, OrderedMethods0, OrderedMethods,
        MethodInfo0, MethodInfo, !Specs),

    MethodInfo = instance_method_info(ModuleInfo, QualInfo, _PredName,
        _Arity, _ExistQVars, _ArgTypes, _ClassContext, _ArgModes,
        _ArgTypeVars, _Status, _PredOrFunc),

    !:InstanceCheckInfo = instance_check_info(InstanceDefn,
        OrderedMethods, ModuleInfo, QualInfo).

:- type modes_and_detism
    --->    modes_and_detism(
                list(mer_mode),
                inst_varset,
                maybe(determinism)
            ).

:- pred check_instance_pred_procs(class_id::in, list(tvar)::in, sym_name::in,
    pred_markers::in, hlds_instance_defn::in, hlds_instance_defn::out,
    instance_methods::in, instance_methods::out,
    instance_method_info::in, instance_method_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_instance_pred_procs(ClassId, ClassVars, MethodName, Markers,
        InstanceDefn0, InstanceDefn, OrderedInstanceMethods0,
        OrderedInstanceMethods, !Info, !Specs) :-
    InstanceDefn0 = hlds_instance_defn(InstanceModuleName, InstanceStatus,
        InstanceContext, InstanceConstraints, InstanceTypes,
        InstanceBody, MaybeInstancePredProcs, InstanceVarSet, InstanceProofs),
    !.Info = instance_method_info(_ModuleInfo, _QualInfo, _PredName, Arity,
        _ExistQVars, _ArgTypes, _ClassContext, _ArgModes, _ArgTypeVars,
        _Status, PredOrFunc),
    get_matching_instance_defns(InstanceBody, PredOrFunc, MethodName,
        Arity, MatchingInstanceMethods),
    (
        MatchingInstanceMethods = [InstanceMethod],
        OrderedInstanceMethods = [InstanceMethod | OrderedInstanceMethods0],
        InstanceMethod = instance_method(_, _, InstancePredDefn, _, Context),
        produce_auxiliary_procs(ClassId, ClassVars, Markers,
            InstanceTypes, InstanceConstraints,
            InstanceVarSet, InstanceModuleName,
            InstancePredDefn, Context,
            InstancePredId, InstanceProcIds, !Info, !Specs),
        MakeClassProc = (pred(TheProcId::in, PredProcId::out) is det :-
                PredProcId = hlds_class_proc(InstancePredId, TheProcId)
            ),
        list.map(MakeClassProc, InstanceProcIds, InstancePredProcs1),
        (
            MaybeInstancePredProcs = yes(InstancePredProcs0),
            InstancePredProcs = InstancePredProcs0 ++ InstancePredProcs1
        ;
            MaybeInstancePredProcs = no,
            InstancePredProcs = InstancePredProcs1
        ),
        InstanceDefn = hlds_instance_defn(InstanceModuleName, InstanceStatus,
            Context, InstanceConstraints, InstanceTypes,
            InstanceBody, yes(InstancePredProcs), InstanceVarSet,
            InstanceProofs)
    ;
        MatchingInstanceMethods = [Instance1, Instance2 | LaterInstances],
        % Duplicate method definition error.
        OrderedInstanceMethods = OrderedInstanceMethods0,
        InstanceDefn = InstanceDefn0,
        ClassId = class_id(ClassName, _ClassArity),
        ClassNameString = sym_name_to_string(ClassName),
        InstanceTypesString = mercury_type_list_to_string(InstanceVarSet,
            InstanceTypes),
        HeaderPieces =
            [words("In instance declaration for"),
            words("`" ++ ClassNameString ++
                "(" ++ InstanceTypesString ++ ")':"),
            words("multiple implementations of type class"),
            p_or_f(PredOrFunc), words("method"),
            sym_name_and_arity(MethodName / Arity), suffix("."), nl],
        HeadingMsg = simple_msg(InstanceContext, [always(HeaderPieces)]),
        Instance1Context = Instance1 ^ instance_method_decl_context,
        FirstPieces = [words("First definition appears here."), nl],
        FirstMsg = simple_msg(Instance1Context, [always(FirstPieces)]),
        DefnToMsg = (pred(Definition::in, Msg::out) is det :-
            TheContext = Definition ^ instance_method_decl_context,
            SubsequentPieces =
                [words("Subsequent definition appears here."), nl],
            Msg = simple_msg(TheContext, [always(SubsequentPieces)])
        ),
        list.map(DefnToMsg, [Instance2 | LaterInstances], LaterMsgs),

        Spec = error_spec(severity_error, phase_type_check,
            [HeadingMsg, FirstMsg | LaterMsgs]),
        !:Specs = [Spec | !.Specs]
    ;
        MatchingInstanceMethods = [],
        % Undefined method error.
        OrderedInstanceMethods = OrderedInstanceMethods0,
        InstanceDefn = InstanceDefn0,
        ClassId = class_id(ClassName, _ClassArity),
        ClassNameString = sym_name_to_string(ClassName),
        InstanceTypesString = mercury_type_list_to_string(InstanceVarSet,
            InstanceTypes),

        Pieces = [words("In instance declaration for"),
            words("`" ++ ClassNameString ++
                "(" ++ InstanceTypesString ++ ")'"),
            suffix(":"),
            words("no implementation for type class"), p_or_f(PredOrFunc),
            words("method"), sym_name_and_arity(MethodName / Arity),
            suffix("."), nl],
        Msg = simple_msg(InstanceContext, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_type_check, [Msg]),
        !:Specs = [Spec | !.Specs]
    ).

    % Get all the instance definitions which match the specified
    % predicate/function name/arity, with multiple clause definitions
    % being combined into a single definition.
    %
:- pred get_matching_instance_defns(instance_body::in, pred_or_func::in,
    sym_name::in, arity::in, instance_methods::out) is det.

get_matching_instance_defns(instance_body_abstract, _, _, _, []).
get_matching_instance_defns(instance_body_concrete(InstanceMethods),
        PredOrFunc, MethodName, MethodArity, ResultList) :-
    % First find the instance method definitions that match this
    % predicate/function's name and arity
    list.filter(
        (pred(Method::in) is semidet :-
            Method = instance_method(PredOrFunc, MethodName, _MethodDefn,
                MethodArity, _Context)
        ),
        InstanceMethods, MatchingMethods),
    (
        MatchingMethods = [First, _Second | _],
        FirstContext = First ^ instance_method_decl_context,
        \+ (
            list.member(DefnViaName, MatchingMethods),
            DefnViaName = instance_method(_, _, InstanceProcDef, _, _),
            InstanceProcDef = DefnViaName ^ instance_method_proc_def,
            InstanceProcDef = instance_proc_def_name(_)
        )
    ->
        % If all of the instance method definitions for this pred/func
        % are clauses, and there are more than one of them, then we must
        % combine them all into a single definition.
        MethodToClause = (pred(Method::in, Clauses::out) is semidet :-
            Method = instance_method(_, _, Defn, _, _),
            Defn = instance_proc_def_clauses(Clauses)
        ),
        list.filter_map(MethodToClause, MatchingMethods, ClausesList),
        list.condense(ClausesList, FlattenedClauses),
        CombinedMethod = instance_method(PredOrFunc, MethodName,
            instance_proc_def_clauses(FlattenedClauses), MethodArity,
            FirstContext),
        ResultList = [CombinedMethod]
    ;
        % If there are less than two matching method definitions,
        % or if any of the instance method definitions is a method name,
        % then we're done.
        ResultList = MatchingMethods
    ).

:- pred produce_auxiliary_procs(class_id::in, list(tvar)::in, pred_markers::in,
    list(mer_type)::in, list(prog_constraint)::in, tvarset::in,
    module_name::in, instance_proc_def::in, prog_context::in,
    pred_id::out, list(proc_id)::out,
    instance_method_info::in, instance_method_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

produce_auxiliary_procs(ClassId, ClassVars, Markers0,
        InstanceTypes0, InstanceConstraints0, InstanceVarSet,
        InstanceModuleName, InstancePredDefn, Context, PredId,
        InstanceProcIds, Info0, Info, !Specs) :-

    Info0 = instance_method_info(ModuleInfo0, QualInfo0, PredName,
        Arity, ExistQVars0, ArgTypes0, ClassMethodClassContext0,
        ArgModes, TVarSet0, Status0, PredOrFunc),

    % Rename the instance variables apart from the class variables.
    tvarset_merge_renaming(TVarSet0, InstanceVarSet, TVarSet1, Renaming),
    apply_variable_renaming_to_type_list(Renaming, InstanceTypes0,
        InstanceTypes1),
    apply_variable_renaming_to_prog_constraint_list(Renaming,
        InstanceConstraints0, InstanceConstraints1),

    % Work out what the type variables are bound to for this
    % instance, and update the class types appropriately.
    map.from_corresponding_lists(ClassVars, InstanceTypes1, TypeSubst),
    apply_subst_to_type_list(TypeSubst, ArgTypes0, ArgTypes1),
    apply_subst_to_prog_constraints(TypeSubst, ClassMethodClassContext0,
        ClassMethodClassContext1),

    % Calculate which type variables we need to keep.  This includes all
    % type variables appearing in the arguments, the class method context and
    % the instance constraints.  (Type variables in the existq_tvars must
    % occur either in the argument types or in the class method context;
    % type variables in the instance types must appear in the arguments.)
    type_vars_list(ArgTypes1, ArgTVars),
    prog_constraints_get_tvars(ClassMethodClassContext1, MethodContextTVars),
    constraint_list_get_tvars(InstanceConstraints1, InstanceTVars),
    list.condense([ArgTVars, MethodContextTVars, InstanceTVars], VarsToKeep0),
    list.sort_and_remove_dups(VarsToKeep0, VarsToKeep),

    % Project away the unwanted type variables.
    varset.squash(TVarSet1, VarsToKeep, TVarSet, SquashSubst),
    apply_variable_renaming_to_type_list(SquashSubst, ArgTypes1, ArgTypes),
    apply_variable_renaming_to_prog_constraints(SquashSubst,
        ClassMethodClassContext1, ClassMethodClassContext),
    apply_partial_map_to_list(SquashSubst, ExistQVars0, ExistQVars),
    apply_variable_renaming_to_type_list(SquashSubst, InstanceTypes1,
        InstanceTypes),
    apply_variable_renaming_to_prog_constraint_list(SquashSubst,
        InstanceConstraints1, InstanceConstraints),

    % Add the constraints from the instance declaration to the constraints
    % from the class method. This allows an instance method to have constraints
    % on it which are not part of the instance declaration as a whole.
    ClassMethodClassContext = constraints(UnivConstraints1, ExistConstraints),
    list.append(InstanceConstraints, UnivConstraints1, UnivConstraints),
    ClassContext = constraints(UnivConstraints, ExistConstraints),

    % Introduce a new predicate which calls the implementation
    % given in the instance declaration.
    map.init(Proofs),
    map.init(ConstraintMap),
    add_marker(marker_class_instance_method, Markers0, Markers1),
    (
        InstancePredDefn = instance_proc_def_name(_),
        % For instance methods which are defined using the named syntax
        % (e.g. "pred(...) is ...") rather than the clauses syntax, we record
        % an additional marker; the only effect of this marker is that we
        % output slightly different error messages for such predicates.
        add_marker(marker_named_class_instance_method, Markers1, Markers)
    ;
        InstancePredDefn = instance_proc_def_clauses(_),
        Markers = Markers1
    ),

    IsImported = status_is_imported(Status0),
    (
        IsImported = yes,
        Status = status_opt_imported
    ;
        IsImported = no,
        Status = Status0
    ),

    adjust_func_arity(PredOrFunc, Arity, PredArity),
    produce_instance_method_clauses(InstancePredDefn, PredOrFunc,
        PredArity, ArgTypes, Markers, Context, Status, ClausesInfo,
        ModuleInfo0, ModuleInfo1, QualInfo0, QualInfo, !Specs),

    % Fill in some information in the pred_info which is used by polymorphism
    % to make sure the type-infos and typeclass-infos are added in the correct
    % order.
    MethodConstraints = instance_method_constraints(ClassId,
        InstanceTypes, InstanceConstraints, ClassMethodClassContext),
    pred_info_init(InstanceModuleName, PredName, PredArity, PredOrFunc,
        Context, origin_instance_method(MethodConstraints), Status,
        goal_type_none, Markers, ArgTypes, TVarSet, ExistQVars, ClassContext,
        Proofs, ConstraintMap, ClausesInfo, PredInfo0),
    pred_info_set_clauses_info(ClausesInfo, PredInfo0, PredInfo1),

    % Add procs with the expected modes and determinisms
    AddProc = (pred(ModeAndDet::in, NewProcId::out,
            OldPredInfo::in, NewPredInfo::out) is det :-
        ModeAndDet = modes_and_detism(Modes, InstVarSet, MaybeDet),
        add_new_proc(InstVarSet, PredArity, Modes, yes(Modes), no,
            MaybeDet, Context, address_is_taken,
            OldPredInfo, NewPredInfo, NewProcId)
    ),
    list.map_foldl(AddProc, ArgModes, InstanceProcIds, PredInfo1, PredInfo),

    module_info_get_predicate_table(ModuleInfo1, PredicateTable1),
    module_info_get_partial_qualifier_info(ModuleInfo1, PQInfo),
    % XXX Why do we need to pass may_be_unqualified here, rather than passing
    % must_be_qualified or calling the predicate_table_insert/4 version?
    predicate_table_insert_qual(PredInfo, may_be_unqualified, PQInfo, PredId,
        PredicateTable1, PredicateTable),
    module_info_set_predicate_table(PredicateTable, ModuleInfo1, ModuleInfo),

    Info = instance_method_info(ModuleInfo, QualInfo, PredName, Arity,
        ExistQVars, ArgTypes, ClassContext, ArgModes, TVarSet, Status,
        PredOrFunc).

%---------------------------------------------------------------------------%

    % Make the name of the introduced pred used to check a particular
    % instance of a particular class method
    %
    % XXX This isn't quite perfect, I suspect
    %
:- pred make_introduced_pred_name(class_id::in, sym_name::in, arity::in,
    list(mer_type)::in, sym_name::out) is det.

make_introduced_pred_name(ClassId, MethodName, Arity, InstanceTypes,
        PredName) :-
    ClassId = class_id(ClassName, _ClassArity),
    ClassNameString = sym_name_to_string_sep(ClassName, "__"),
    MethodNameString = sym_name_to_string_sep(MethodName, "__"),
    % Perhaps we should include the arity in this mangled string?
    string.int_to_string(Arity, ArityString),
    make_instance_string(InstanceTypes, InstanceString),
    string.append_list(
        [introduced_pred_name_prefix,
        ClassNameString, "____",
        InstanceString, "____",
        MethodNameString, "_",
        ArityString],
        PredNameString),
    PredName = unqualified(PredNameString).

    % The prefix added to the class method name for the predicate
    % used to call a class method for a specific instance.
    %
:- func introduced_pred_name_prefix = string.

introduced_pred_name_prefix = "ClassMethod_for_".

%---------------------------------------------------------------------------%

    % Check that the superclass constraints are satisfied for the
    % types in this instance declaration.
    %
:- pred check_superclass_conformance(class_id::in, list(prog_constraint)::in,
    list(tvar)::in, tvarset::in, module_info::in,
    hlds_instance_defn::in, hlds_instance_defn::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_superclass_conformance(ClassId, ProgSuperClasses0, ClassVars0,
        ClassVarSet, ModuleInfo, InstanceDefn0, InstanceDefn, !Specs) :-

    InstanceDefn0 = hlds_instance_defn(A, B, Context, InstanceProgConstraints,
        InstanceTypes, F, G, InstanceVarSet0, Proofs0),
    tvarset_merge_renaming(InstanceVarSet0, ClassVarSet, InstanceVarSet1,
        Renaming),

    % Make the constraints in terms of the instance variables.
    apply_variable_renaming_to_prog_constraint_list(Renaming,
        ProgSuperClasses0, ProgSuperClasses),

    % Now handle the class variables.
    apply_variable_renaming_to_tvar_list(Renaming, ClassVars0, ClassVars),

    % Calculate the bindings.
    map.from_corresponding_lists(ClassVars, InstanceTypes, TypeSubst),

    module_info_get_class_table(ModuleInfo, ClassTable),
    module_info_get_instance_table(ModuleInfo, InstanceTable),
    module_info_get_superclass_table(ModuleInfo, SuperClassTable),

    % Build a suitable constraint context for checking the instance.
    % To do this, we assume any constraints on the instance declaration
    % (that is, treat them as universal constraints on a predicate) and try
    % to prove the constraints on the class declaration (that is, treat them
    % as existential constraints on a predicate).
    %
    % We don't bother assigning ids to these constraints, since the resulting
    % constraint map is not used anyway.
    %
    init_hlds_constraint_list(ProgSuperClasses, SuperClasses),
    init_hlds_constraint_list(InstanceProgConstraints, InstanceConstraints),
    make_hlds_constraints(ClassTable, InstanceVarSet1, SuperClasses,
        InstanceConstraints, Constraints0),

    % Try to reduce the superclass constraints, using the declared instance
    % constraints and the usual context reduction rules.
    map.init(ConstraintMap0),
    typeclasses.reduce_context_by_rule_application(ClassTable,
        InstanceTable, SuperClassTable, ClassVars, TypeSubst, _,
        InstanceVarSet1, InstanceVarSet2,
        Proofs0, Proofs1, ConstraintMap0, _,
        Constraints0, Constraints),
    UnprovenConstraints = Constraints ^ unproven,

    (
        UnprovenConstraints = [],
        InstanceDefn = hlds_instance_defn(A, B, Context,
            InstanceProgConstraints, InstanceTypes, F, G,
            InstanceVarSet2, Proofs1)
    ;
        UnprovenConstraints = [_ | UnprovenConstraintsTail],
        ClassId = class_id(ClassName, _ClassArity),
        ClassNameString = sym_name_to_string(ClassName),
        InstanceTypesString = mercury_type_list_to_string(InstanceVarSet2,
            InstanceTypes),
        constraint_list_to_string(ClassVarSet, UnprovenConstraints,
            ConstraintsString),
        Pieces = [words("In instance declaration for"),
            words("`" ++ ClassNameString ++ "(" ++ InstanceTypesString ++ ")'"),
            words(choose_number(UnprovenConstraintsTail,
                "superclass constraint", "superclass constraints")),
            words("not satisfied:"), words(ConstraintsString), suffix("."),
            nl],
        Msg = simple_msg(Context, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_type_check, [Msg]),
        !:Specs = [Spec | !.Specs],
        InstanceDefn = InstanceDefn0
    ).

:- pred constraint_list_to_string(tvarset::in, list(hlds_constraint)::in,
    string::out) is det.

constraint_list_to_string(_, [], "").
constraint_list_to_string(VarSet, [C | Cs], String) :-
    retrieve_prog_constraint(C, P),
    String0 = mercury_constraint_to_string(VarSet, P),
    constraint_list_to_string_2(VarSet, Cs, String1),
    string.append_list(["`", String0, "'", String1], String).

:- pred constraint_list_to_string_2(tvarset::in, list(hlds_constraint)::in,
    string::out) is det.

constraint_list_to_string_2(_VarSet, [], "").
constraint_list_to_string_2(VarSet, [C | Cs], String) :-
    retrieve_prog_constraint(C, P),
    String0 = mercury_constraint_to_string(VarSet, P),
    constraint_list_to_string_2(VarSet, Cs, String1),
    string.append_list([", `", String0, "'", String1], String).

%---------------------------------------------------------------------------%

    % Check that every abstract instance in the interface of a module
    % has a corresponding concrete instance in the implementation.
    %
:- pred check_for_missing_concrete_instances(module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_for_missing_concrete_instances(!ModuleInfo, !Specs) :-
    module_info_get_instance_table(!.ModuleInfo, InstanceTable),
    % Grab all the abstract instance declarations in the interface of this
    % module and all the concrete instances defined in the implementation.
    gather_abstract_and_concrete_instances(InstanceTable,
        AbstractInstances, ConcreteInstances),
    map.foldl(check_for_corresponding_instances(ConcreteInstances),
        AbstractInstances, !Specs).

    % gather_abstract_and_concrete_instances(Table,
    %   AbstractInstances, ConcreteInstances).
    %
    % Search the instance_table and create a table of abstract
    % instances that occur in the module interface and a table of
    % concrete instances that occur in the module implementation.
    % Imported instances are not included at all.
    %
:- pred gather_abstract_and_concrete_instances(instance_table::in,
    instance_table::out, instance_table::out) is det.

gather_abstract_and_concrete_instances(InstanceTable, Abstracts,
        Concretes) :-
    map.foldl2(partition_instances_for_class, InstanceTable,
        multi_map.init, Abstracts, multi_map.init, Concretes).

    % Partition all the non-imported instances for a particular
    % class into two groups, those that are abstract and in the
    % module interface and those that are concrete and in the module
    % implementation.  Concrete instances cannot occur in the
    % interface and we ignore abstract instances in the implementation.
    %
:- pred partition_instances_for_class(class_id::in,
    list(hlds_instance_defn)::in, instance_table::in, instance_table::out,
    instance_table::in, instance_table::out) is det.

partition_instances_for_class(ClassId, Instances, !Abstracts, !Concretes) :-
    list.foldl2(partition_instances_for_class_2(ClassId), Instances,
        !Abstracts, !Concretes).

:- pred partition_instances_for_class_2(class_id::in, hlds_instance_defn::in,
    instance_table::in, instance_table::out,
    instance_table::in, instance_table::out) is det.

partition_instances_for_class_2(ClassId, InstanceDefn, !Abstracts,
        !Concretes) :-
    ImportStatus = InstanceDefn ^ instance_status,
    IsImported = status_is_imported(ImportStatus),
    (
        IsImported = no,
        Body = InstanceDefn ^ instance_body,
        (
            Body = instance_body_abstract,
            IsExported = status_is_exported_to_non_submodules(ImportStatus),
            (
                IsExported = yes,
                svmulti_map.add(ClassId, InstanceDefn, !Abstracts)
            ;
                IsExported = no
            )
        ;
            Body = instance_body_concrete(_),
            svmulti_map.add(ClassId, InstanceDefn, !Concretes)
        )
    ;
        IsImported = yes
    ).

:- pred check_for_corresponding_instances(instance_table::in,
    class_id::in, list(hlds_instance_defn)::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_for_corresponding_instances(Concretes, ClassId, InstanceDefns,
        !Specs) :-
    list.foldl(check_for_corresponding_instances_2(Concretes, ClassId),
        InstanceDefns, !Specs).

:- pred check_for_corresponding_instances_2(instance_table::in, class_id::in,
    hlds_instance_defn::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_for_corresponding_instances_2(Concretes, ClassId, AbstractInstance,
        !Specs) :-
    AbstractTypes = AbstractInstance ^ instance_types,
    ( multi_map.search(Concretes, ClassId, ConcreteInstances) ->
        (
            list.member(ConcreteInstance, ConcreteInstances),
            ConcreteTypes = ConcreteInstance ^ instance_types,
            ConcreteTypes = AbstractTypes
        ->
            MissingConcreteError = no
        ;
            % There were concrete instances for ClassId in the implementation
            % but none of them matches the abstract instance we have.
            MissingConcreteError = yes
        )
    ;
        % There were no concrete instances for ClassId in the implementation.
        MissingConcreteError = yes
    ),
    (
        MissingConcreteError = yes,
        ClassId = class_id(ClassName, _),
        ClassNameString = sym_name_to_string(ClassName),
        AbstractTypesString = mercury_type_list_to_string(
            AbstractInstance ^ instance_tvarset, AbstractTypes),
        AbstractInstanceName = ClassNameString ++
            "(" ++ AbstractTypesString ++ ")",
        % XXX Should we mention any constraints on the instance declaration?
        Pieces = [words("Error: abstract instance declaration"),
            words("for"), quote(AbstractInstanceName),
            words("has no corresponding concrete"),
            words("instance in the implementation."), nl],
        AbstractInstanceContext = AbstractInstance ^ instance_context,
        Msg = simple_msg(AbstractInstanceContext, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_type_check, [Msg]),
        !:Specs = [Spec | !.Specs]
    ;
        MissingConcreteError = no
    ).

%-----------------------------------------------------------------------------%

    % Check for cyclic classes in the class table by traversing the class
    % hierarchy for each class. While we are doing this, calculate the set
    % of ancestors with functional dependencies for each class, and enter
    % this information in the class table.
    %
:- pred check_for_cyclic_classes(module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_for_cyclic_classes(!ModuleInfo, !Specs) :-
    module_info_get_class_table(!.ModuleInfo, ClassTable0),
    ClassIds = map.keys(ClassTable0),
    foldl3(find_cycles([]), ClassIds, ClassTable0, ClassTable, set.init, _,
        [], Cycles),
    !:Specs = list.map(report_cyclic_classes(ClassTable), Cycles) ++ !.Specs,
    module_info_set_class_table(ClassTable, !ModuleInfo).

:- type class_path == list(class_id).

    % find_cycles(Path, ClassId, !ClassTable, !Visited, !Cycles)
    %
    % Perform a depth first traversal of the class hierarchy, starting
    % from ClassId.  Path contains a list of nodes joining the current
    % node to the root.  When we reach a node that has already been visited,
    % check whether there is a cycle in the Path.
    %
:- pred find_cycles(class_path::in, class_id::in,
    class_table::in, class_table::out,
    set(class_id)::in, set(class_id)::out,
    list(class_path)::in, list(class_path)::out) is det.

find_cycles(Path, ClassId, !ClassTable, !Visited, !Cycles) :-
    find_cycles_2(Path, ClassId, _, _, !ClassTable, !Visited, !Cycles).

    % As above, but also return this class's parameters and ancestor list.
    %
:- pred find_cycles_2(class_path::in, class_id::in, list(tvar)::out,
    list(prog_constraint)::out, class_table::in, class_table::out,
    set(class_id)::in, set(class_id)::out,
    list(class_path)::in, list(class_path)::out) is det.

find_cycles_2(Path, ClassId, Params, Ancestors, !ClassTable, !Visited,
        !Cycles) :-
    ClassDefn0 = map.lookup(!.ClassTable, ClassId),
    Params = ClassDefn0 ^ class_vars,
    Kinds = ClassDefn0 ^ class_kinds,
    ( set.member(ClassId, !.Visited) ->
        ( find_cycle(ClassId, Path, [ClassId], Cycle) ->
            !:Cycles = [Cycle | !.Cycles]
        ;
            true
        ),
        Ancestors = ClassDefn0 ^ class_fundep_ancestors
    ;
        svset.insert(ClassId, !Visited),

        % Make this class its own ancestor, but only if it has fundeps on it.
        FunDeps = ClassDefn0 ^ class_fundeps,
        (
            FunDeps = [],
            Ancestors0 = []
        ;
            FunDeps = [_ | _],
            ClassId = class_id(ClassName, _),
            prog_type.var_list_to_type_list(Kinds, Params, Args),
            Ancestors0 = [constraint(ClassName, Args)]
        ),
        Superclasses = ClassDefn0 ^ class_supers,
        foldl4(find_cycles_3([ClassId | Path]), Superclasses,
            !ClassTable, !Visited, !Cycles, Ancestors0, Ancestors),
        ClassDefn = ClassDefn0 ^ class_fundep_ancestors := Ancestors,
        svmap.det_update(ClassId, ClassDefn, !ClassTable)
    ).

    % As we go, accumulate the ancestors from all the superclasses,
    % with the class parameters bound to the corresponding arguments.
    % Note that we don't need to merge varsets because typeclass
    % parameters are guaranteed to be distinct variables.
    %
:- pred find_cycles_3(class_path::in, prog_constraint::in,
    class_table::in, class_table::out,
    set(class_id)::in, set(class_id)::out,
    list(class_path)::in, list(class_path)::out,
    list(prog_constraint)::in, list(prog_constraint)::out) is det.

find_cycles_3(Path, Constraint, !ClassTable, !Visited, !Cycles, !Ancestors) :-
    Constraint = constraint(Name, Args),
    list.length(Args, Arity),
    ClassId = class_id(Name, Arity),
    find_cycles_2(Path, ClassId, Params, NewAncestors0, !ClassTable,
        !Visited, !Cycles),
    map.from_corresponding_lists(Params, Args, Binding),
    apply_subst_to_prog_constraint_list(Binding, NewAncestors0, NewAncestors),
    list.append(NewAncestors, !Ancestors).

    % find_cycle(ClassId, PathRemaining, PathSoFar, Cycle):
    %
    % Check if ClassId is present in PathRemaining, and if so then make
    % a cycle out of the front part of the path up to the point where
    % the ClassId is found.  The part of the path checked so far is
    % accumulated in PathSoFar.
    %
:- pred find_cycle(class_id::in, class_path::in, class_path::in,
    class_path::out) is semidet.

find_cycle(ClassId, [Head | Tail], Path0, Cycle) :-
    Path = [Head | Path0],
    ( ClassId = Head ->
        Cycle = Path
    ;
        find_cycle(ClassId, Tail, Path, Cycle)
    ).

    % Report an error using the format
    %
    %   module.m:NNN: Error: cyclic superclass relation detected:
    %   module.m:NNN:   `foo/N' <= `bar/N' <= `baz/N' <= `foo/N'
    %
:- func report_cyclic_classes(class_table, class_path) = error_spec.

report_cyclic_classes(ClassTable, ClassPath) = Spec :-
    (
        ClassPath = [],
        unexpected(this_file, "report_cyclic_classes: empty cycle found.")
    ;
        ClassPath = [ClassId | Tail],
        Context = map.lookup(ClassTable, ClassId) ^ class_context,
        ClassId = class_id(Name, Arity),
        RevPieces0 = [sym_name_and_arity(Name/Arity),
            words("Error: cyclic superclass relation detected:")],
        RevPieces = foldl(add_path_element, Tail, RevPieces0),
        Pieces = list.reverse(RevPieces),
        Msg = simple_msg(Context, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [Msg])
    ).

:- func add_path_element(class_id, list(format_component))
    = list(format_component).

add_path_element(class_id(Name, Arity), RevPieces0) =
    [sym_name_and_arity(Name/Arity), words("<=") | RevPieces0].

%---------------------------------------------------------------------------%

    % Check that all instances are range restricted with respect to the
    % functional dependencies.  This means that, for each functional
    % dependency, the set of tvars in the range arguments must be a
    % subset of the set of tvars in the domain arguments.
    % (Note that with the requirement of distinct variables as arguments,
    % this implies that all range arguments must be ground.  However,
    % this code should work even if that requirement is lifted in future.)
    %
    % Also, check that all pairs of visible instances are mutually
    % consistent with respect to the functional dependencies.  This is
    % true iff the most general unifier of corresponding domain arguments
    % (if it exists) is also a unifier of the corresponding range
    % arguments.
    %
:- pred check_functional_dependencies(module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_functional_dependencies(!ModuleInfo, !Specs) :-
    module_info_get_instance_table(!.ModuleInfo, InstanceTable),
    map.keys(InstanceTable, ClassIds),
    list.foldl2(check_fundeps_class, ClassIds, !ModuleInfo, !Specs).

:- pred check_fundeps_class(class_id::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_fundeps_class(ClassId, !ModuleInfo, !Specs) :-
    module_info_get_class_table(!.ModuleInfo, ClassTable),
    map.lookup(ClassTable, ClassId, ClassDefn),
    module_info_get_instance_table(!.ModuleInfo, InstanceTable),
    map.lookup(InstanceTable, ClassId, InstanceDefns),
    FunDeps = ClassDefn ^ class_fundeps,
    check_range_restrictedness(ClassId, InstanceDefns, FunDeps,
        !ModuleInfo, !Specs),
    check_consistency(ClassId, ClassDefn, InstanceDefns, FunDeps,
        !ModuleInfo, !Specs).

:- pred check_range_restrictedness(class_id::in, list(hlds_instance_defn)::in,
    hlds_class_fundeps::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_range_restrictedness(_, [], _, !ModuleInfo, !Specs).
check_range_restrictedness(ClassId, [InstanceDefn | InstanceDefns], FunDeps,
        !ModuleInfo, !Specs) :-
    list.foldl2(check_range_restrictedness_2(ClassId, InstanceDefn),
        FunDeps, !ModuleInfo, !Specs),
    check_range_restrictedness(ClassId, InstanceDefns, FunDeps,
        !ModuleInfo, !Specs).

:- pred check_range_restrictedness_2(class_id::in, hlds_instance_defn::in,
    hlds_class_fundep::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_range_restrictedness_2(ClassId, InstanceDefn, FunDep, !ModuleInfo,
        !Specs) :-
    Types = InstanceDefn ^ instance_types,
    FunDep = fundep(Domain, Range),
    DomainTypes = restrict_list_elements(Domain, Types),
    type_vars_list(DomainTypes, DomainVars),
    RangeTypes = restrict_list_elements(Range, Types),
    type_vars_list(RangeTypes, RangeVars),
    solutions.solutions((pred(V::out) is nondet :-
            list.member(V, RangeVars),
            \+ list.member(V, DomainVars)
        ), UnboundVars),
    (
        UnboundVars = []
    ;
        UnboundVars = [_ | _],
        Spec = report_range_restriction_error(ClassId, InstanceDefn,
            UnboundVars),
        !:Specs = [Spec | !.Specs]
    ).

    % The error message is intended to look like this:
    %
    % long_module_name:001: In instance for typeclass `long_class/2':
    % long_module_name:001:   functional dependency not satisfied: type
    % long_module_name:001:   variables T1, T2 and T3 occur in the range of a
    % long_module_name:001:   functional dependency, but are not in the
    % long_module_name:001:   domain.

:- func report_range_restriction_error(class_id, hlds_instance_defn,
    list(tvar)) = error_spec.

report_range_restriction_error(ClassId, InstanceDefn, Vars) = Spec :-
    ClassId = class_id(SymName, Arity),
    TVarSet = InstanceDefn ^ instance_tvarset,
    Context = InstanceDefn ^ instance_context,

    VarsStrs = list.map((func(Var) = mercury_var_to_string(Var, TVarSet, no)),
        Vars),

    Pieces = [words("In instance for typeclass"),
        sym_name_and_arity(SymName / Arity), suffix(":"), nl,
        words("functional dependency not satisfied:"),
        words(choose_number(Vars, "type variable", "type variables"))]
        ++ list_to_pieces(VarsStrs) ++
        [words(choose_number(Vars, "occurs", "occur")),
        words("in the range of the functional dependency, but"),
        words(choose_number(Vars, "is", "are")),
        words("not in the domain."), nl],
    Msg = simple_msg(Context, [always(Pieces)]),
    Spec = error_spec(severity_error, phase_type_check, [Msg]).

    % Check the consistency of each (unordered) pair of instances.
    %
:- pred check_consistency(class_id::in, hlds_class_defn::in,
    list(hlds_instance_defn)::in, hlds_class_fundeps::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_consistency(_, _, [], _, !ModuleInfo, !Specs).
check_consistency(ClassId, ClassDefn, [Instance | Instances], FunDeps,
        !ModuleInfo, !Specs) :-
    list.foldl2(check_consistency_pair(ClassId, ClassDefn, FunDeps, Instance),
        Instances, !ModuleInfo, !Specs),
    check_consistency(ClassId, ClassDefn, Instances, FunDeps,
        !ModuleInfo, !Specs).

:- pred check_consistency_pair(class_id::in, hlds_class_defn::in,
    hlds_class_fundeps::in, hlds_instance_defn::in, hlds_instance_defn::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_consistency_pair(ClassId, ClassDefn, FunDeps, InstanceA, InstanceB,
        !ModuleInfo, !Specs) :-
    list.foldl2(
        check_consistency_pair_2(ClassId, ClassDefn, InstanceA, InstanceB),
        FunDeps, !ModuleInfo, !Specs).

:- pred check_consistency_pair_2(class_id::in, hlds_class_defn::in,
    hlds_instance_defn::in, hlds_instance_defn::in, hlds_class_fundep::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_consistency_pair_2(ClassId, ClassDefn, InstanceA, InstanceB, FunDep,
        !ModuleInfo, !Specs) :-
    TVarSetA = InstanceA ^ instance_tvarset,
    TVarSetB = InstanceB ^ instance_tvarset,
    tvarset_merge_renaming(TVarSetA, TVarSetB, _, Renaming),

    TypesA = InstanceA ^ instance_types,
    TypesB0 = InstanceB ^ instance_types,
    apply_variable_renaming_to_type_list(Renaming, TypesB0, TypesB),

    FunDep = fundep(Domain, Range),
    DomainA = restrict_list_elements(Domain, TypesA),
    DomainB = restrict_list_elements(Domain, TypesB),

    ( type_unify_list(DomainA, DomainB, [], map.init, Subst) ->
        RangeA0 = restrict_list_elements(Range, TypesA),
        RangeB0 = restrict_list_elements(Range, TypesB),
        apply_rec_subst_to_type_list(Subst, RangeA0, RangeA),
        apply_rec_subst_to_type_list(Subst, RangeB0, RangeB),
        ( RangeA = RangeB ->
            true
        ;
            Spec = report_consistency_error(ClassId, ClassDefn,
                InstanceA, InstanceB, FunDep),
            !:Specs = [Spec | !.Specs]
        )
    ;
        true
    ).

:- func report_consistency_error(class_id, hlds_class_defn,
    hlds_instance_defn, hlds_instance_defn, hlds_class_fundep) = error_spec.

report_consistency_error(ClassId, ClassDefn, InstanceA, InstanceB, FunDep)
        = Spec :-
    ClassId = class_id(SymName, Arity),
    Params = ClassDefn ^ class_vars,
    TVarSet = ClassDefn ^ class_tvarset,
    ContextA = InstanceA ^ instance_context,
    ContextB = InstanceB ^ instance_context,

    FunDep = fundep(Domain, Range),
    DomainParams = restrict_list_elements(Domain, Params),
    RangeParams = restrict_list_elements(Range, Params),
    DomainList = mercury_vars_to_string(DomainParams, TVarSet, no),
    RangeList = mercury_vars_to_string(RangeParams, TVarSet, no),
    FunDepStr = "`(" ++ DomainList ++ " -> " ++ RangeList ++ ")'",

    PiecesA = [words("Inconsistent instance declaration for typeclass"),
        sym_name_and_arity(SymName / Arity),
        words("with functional dependency"), fixed(FunDepStr),
        suffix("."), nl],
    PiecesB = [words("Here is the conflicting instance.")],

    MsgA = simple_msg(ContextA, [always(PiecesA)]),
    MsgB = error_msg(yes(ContextB), yes, 0, [always(PiecesB)]),
    Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [MsgA, MsgB]).

%---------------------------------------------------------------------------%

    % Look for pred or func declarations for which the type variables in
    % the constraints are not all determined by the type variables in the
    % type and the functional dependencies.  Likewise look for
    % constructors for which the existential type variables in the
    % constraints are not all determined by the type variables in the
    % constructor arguments and the functional dependencies.
    %
:- pred check_typeclass_constraints(module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_typeclass_constraints(!ModuleInfo, !Specs) :-
    module_info_predids(!.ModuleInfo, PredIds),
    list.foldl2(check_pred_constraints, PredIds, !ModuleInfo, !Specs),
    module_info_get_type_table(!.ModuleInfo, TypeTable),
    map.keys(TypeTable, TypeCtors),
    list.foldl2(check_ctor_constraints(TypeTable), TypeCtors,
        !ModuleInfo, !Specs).

:- pred check_pred_constraints(pred_id::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_pred_constraints(PredId, !ModuleInfo, !Specs) :-
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
    (
        pred_info_get_import_status(PredInfo, ImportStatus),
        needs_ambiguity_check(ImportStatus) = no
    ->
        true
    ;
        trace [io(!IO)] (
            write_pred_progress_message("% Checking typeclass constraints on ",
                PredId, !.ModuleInfo, !IO)
        ),

        check_pred_type_ambiguities(PredInfo, !ModuleInfo, !Specs),
        check_constraint_quant(PredInfo, !ModuleInfo, !Specs)
    ).

:- func needs_ambiguity_check(import_status) = bool.

needs_ambiguity_check(status_imported(_)) =             no.
needs_ambiguity_check(status_external(_)) =             yes.
needs_ambiguity_check(status_abstract_imported) =       no.
needs_ambiguity_check(status_pseudo_imported) =         no.
needs_ambiguity_check(status_opt_imported) =            no.
needs_ambiguity_check(status_exported) =                yes.
needs_ambiguity_check(status_opt_exported) =            yes.
needs_ambiguity_check(status_abstract_exported) =       yes.
needs_ambiguity_check(status_pseudo_exported) =         yes.
needs_ambiguity_check(status_exported_to_submodules) =  yes.
needs_ambiguity_check(status_local) =                   yes.

:- pred check_pred_type_ambiguities(pred_info::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_pred_type_ambiguities(PredInfo, !ModuleInfo, !Specs) :-
    pred_info_get_typevarset(PredInfo, TVarSet),
    pred_info_get_arg_types(PredInfo, ArgTypes),
    pred_info_get_class_context(PredInfo, Constraints),
    type_vars_list(ArgTypes, TVars),
    get_unbound_tvars(TVarSet, TVars, Constraints, !.ModuleInfo, UnboundTVars),
    (
        UnboundTVars = []
    ;
        UnboundTVars = [_ | _],
        Spec = report_unbound_tvars_in_pred_context(UnboundTVars, PredInfo),
        !:Specs = [Spec | !.Specs]
    ).

:- pred check_ctor_constraints(type_table::in, type_ctor::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_ctor_constraints(TypeTable, TypeCtor, !ModuleInfo, !Specs) :-
    map.lookup(TypeTable, TypeCtor, TypeDefn),
    get_type_defn_body(TypeDefn, Body),
    ( Body = hlds_du_type(Ctors, _, _, _, _, _) ->
        list.foldl2(check_ctor_type_ambiguities(TypeCtor, TypeDefn), Ctors,
            !ModuleInfo, !Specs)
    ;
        true
    ).

:- pred check_ctor_type_ambiguities(type_ctor::in, hlds_type_defn::in,
    constructor::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_ctor_type_ambiguities(TypeCtor, TypeDefn, Ctor, !ModuleInfo, !Specs) :-
    Ctor = ctor(ExistQVars, Constraints, _, CtorArgs),
    assoc_list.values(CtorArgs, ArgTypes),
    type_vars_list(ArgTypes, ArgTVars),
    list.filter((pred(V::in) is semidet :- list.member(V, ExistQVars)),
        ArgTVars, ExistQArgTVars),
    get_type_defn_tvarset(TypeDefn, TVarSet),
    get_unbound_tvars(TVarSet, ExistQArgTVars, constraints([], Constraints),
        !.ModuleInfo, UnboundTVars),
    (
        UnboundTVars = []
    ;
        UnboundTVars = [_ | _],
        Spec = report_unbound_tvars_in_ctor_context(UnboundTVars, TypeCtor,
            TypeDefn),
        !:Specs = [Spec | !.Specs]
    ).

:- pred get_unbound_tvars(tvarset::in, list(tvar)::in, prog_constraints::in,
    module_info::in, list(tvar)::out) is det.

get_unbound_tvars(TVarSet, TVars, Constraints, ModuleInfo, UnboundTVars) :-
    module_info_get_class_table(ModuleInfo, ClassTable),
    InducedFunDeps = induced_fundeps(ClassTable, TVarSet, Constraints),
    FunDepsClosure = fundeps_closure(InducedFunDeps, list_to_set(TVars)),
    solutions.solutions(
        constrained_var_not_in_closure(Constraints, FunDepsClosure),
            UnboundTVars).

:- pred constrained_var_not_in_closure(prog_constraints::in, set(tvar)::in,
    tvar::out) is nondet.

constrained_var_not_in_closure(ClassContext, Closure, UnboundTVar) :-
    ClassContext = constraints(UnivCs, ExistCs),
    (
        Constraints = UnivCs
    ;
        Constraints = ExistCs
    ),
    prog_type.constraint_list_get_tvars(Constraints, TVars),
    list.member(UnboundTVar, TVars),
    \+ set.member(UnboundTVar, Closure).

:- type induced_fundeps == list(induced_fundep).
:- type induced_fundep
    --->    fundep(
                domain      :: set(tvar),
                range       :: set(tvar)
            ).

:- func induced_fundeps(class_table, tvarset, prog_constraints)
    = induced_fundeps.

induced_fundeps(ClassTable, TVarSet, constraints(UnivCs, ExistCs))
    = foldl(induced_fundeps_2(ClassTable, TVarSet), UnivCs,
        foldl(induced_fundeps_2(ClassTable, TVarSet), ExistCs, [])).

:- func induced_fundeps_2(class_table, tvarset, prog_constraint,
    induced_fundeps) = induced_fundeps.

induced_fundeps_2(ClassTable, TVarSet, Constraint, FunDeps0) = FunDeps :-
    Constraint = constraint(Name, Args),
    Arity = length(Args),
    ClassDefn = map.lookup(ClassTable, class_id(Name, Arity)),
    % The ancestors includes all superclasses of Constraint which have
    % functional dependencies on them (possibly including Constraint itself).
    ClassAncestors = ClassDefn ^ class_fundep_ancestors,
    (
        % Optimize the common case.
        ClassAncestors = [],
        FunDeps = FunDeps0
    ;
        ClassAncestors = [_ | _],
        ClassTVarSet = ClassDefn ^ class_tvarset,
        ClassParams = ClassDefn ^ class_vars,

        % We can ignore the resulting tvarset, since any new variables
        % will become bound when the arguments are bound. (This follows
        % from the fact that constraints on class declarations can only use
        % variables that appear in the head of the declaration.)

        tvarset_merge_renaming(TVarSet, ClassTVarSet, _, Renaming),
        apply_variable_renaming_to_prog_constraint_list(Renaming,
            ClassAncestors, RenamedAncestors),
        apply_variable_renaming_to_tvar_list(Renaming, ClassParams,
            RenamedParams),
        map.from_corresponding_lists(RenamedParams, Args, Subst),
        apply_subst_to_prog_constraint_list(Subst, RenamedAncestors,
            Ancestors),
        FunDeps = foldl(induced_fundeps_3(ClassTable), Ancestors, FunDeps0)
    ).

:- func induced_fundeps_3(class_table, prog_constraint, induced_fundeps)
    = induced_fundeps.

induced_fundeps_3(ClassTable, Constraint, FunDeps0) = FunDeps :-
    Constraint = constraint(Name, Args),
    Arity = length(Args),
    ClassDefn = map.lookup(ClassTable, class_id(Name, Arity)),
    FunDeps = foldl(induced_fundep(Args), ClassDefn ^ class_fundeps, FunDeps0).

:- func induced_fundep(list(mer_type), hlds_class_fundep, induced_fundeps)
    = induced_fundeps.

induced_fundep(Args, fundep(Domain0, Range0), FunDeps)
        = [fundep(Domain, Range) | FunDeps] :-
    Domain = set.fold(induced_vars(Args), Domain0, set.init),
    Range = set.fold(induced_vars(Args), Range0, set.init).

:- func induced_vars(list(mer_type), int, set(tvar)) = set(tvar).

induced_vars(Args, ArgNum, Vars) = union(Vars, NewVars) :-
    Arg = list.index1_det(Args, ArgNum),
    type_vars(Arg, ArgVars),
    NewVars = set.list_to_set(ArgVars).

:- func fundeps_closure(induced_fundeps, set(tvar)) = set(tvar).

fundeps_closure(FunDeps, TVars) = fundeps_closure_2(FunDeps, TVars, set.init).

:- func fundeps_closure_2(induced_fundeps, set(tvar), set(tvar)) = set(tvar).

fundeps_closure_2(FunDeps0, NewVars0, Result0) = Result :-
    ( set.empty(NewVars0) ->
        Result = Result0
    ;
        Result1 = set.union(Result0, NewVars0),
        FunDeps1 = list.map(remove_vars(NewVars0), FunDeps0),
        list.foldl2(collect_determined_vars, FunDeps1, [], FunDeps,
            set.init, NewVars),
        Result = fundeps_closure_2(FunDeps, NewVars, Result1)
    ).

:- func remove_vars(set(tvar), induced_fundep) = induced_fundep.

remove_vars(Vars, fundep(Domain0, Range0)) = fundep(Domain, Range) :-
    Domain = set.difference(Domain0, Vars),
    Range = set.difference(Range0, Vars).

:- pred collect_determined_vars(induced_fundep::in, induced_fundeps::in,
    induced_fundeps::out, set(tvar)::in, set(tvar)::out) is det.

collect_determined_vars(FunDep @ fundep(Domain, Range), !FunDeps, !Vars) :-
    ( set.empty(Domain) ->
        !:Vars = set.union(Range, !.Vars)
    ;
        !:FunDeps = [FunDep | !.FunDeps]
    ).

    % The error message is intended to look like this:
    %
    % long_module_name:001: In declaration for function `long_function/2':
    % long_module_name:001:   error in type class constraints: type variables
    % long_module_name:001:   T1, T2 and T3 occur in the constraints, but are
    % long_module_name:001:   not determined by the function's argument or
    % long_module_name:001:   result types.
    %
    % long_module_name:002: In declaration for predicate `long_predicate/3':
    % long_module_name:002:   error in type class constraints: type variable
    % long_module_name:002:   T occurs in the constraints, but is not
    % long_module_name:002:   determined by the predicate's argument types.
    %
    % long_module_name:002: In declaration for type `long_type/3':
    % long_module_name:002:   error in type class constraints: type variable
    % long_module_name:002:   T occurs in the constraints, but is not
    % long_module_name:002:   determined by the constructor's argument types.

:- func report_unbound_tvars_in_pred_context(list(tvar), pred_info)
    = error_spec.

report_unbound_tvars_in_pred_context(Vars, PredInfo) = Spec :-
    pred_info_context(PredInfo, Context),
    pred_info_get_arg_types(PredInfo, TVarSet, _, ArgTypes),
    PredName = pred_info_name(PredInfo),
    Module = pred_info_module(PredInfo),
    SymName = qualified(Module, PredName),
    Arity = length(ArgTypes),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),

    VarsStrs = list.map((func(Var) = mercury_var_to_string(Var, TVarSet, no)),
        Vars),

    Pieces0 = [words("In declaration for"),
        simple_call(simple_call_id(PredOrFunc, SymName, Arity)),
        suffix(":"), nl,
        words("error in type class constraints:"),
        words(choose_number(Vars, "type variable", "type variables"))]
        ++ list_to_pieces(VarsStrs) ++
        [words(choose_number(Vars, "occurs", "occur")),
        words("in the constraints, but"),
        words(choose_number(Vars, "is", "are")),
        words("not determined by the")],
    (
        PredOrFunc = predicate,
        Pieces = Pieces0 ++ [words("predicate's argument types."), nl]
    ;
        PredOrFunc = function,
        Pieces = Pieces0 ++ [words("function's argument or result types."), nl]
    ),
    Msg = simple_msg(Context,
        [always(Pieces),
        verbose_only(report_unbound_tvars_explanation)]),
    Spec = error_spec(severity_error, phase_type_check, [Msg]).

:- func report_unbound_tvars_in_ctor_context(list(tvar), type_ctor,
    hlds_type_defn) = error_spec.

report_unbound_tvars_in_ctor_context(Vars, TypeCtor, TypeDefn) = Spec :-
    get_type_defn_context(TypeDefn, Context),
    get_type_defn_tvarset(TypeDefn, TVarSet),
    TypeCtor = type_ctor(SymName, Arity),

    VarsStrs = list.map((func(Var) = mercury_var_to_string(Var, TVarSet, no)),
        Vars),

    Pieces = [words("In declaration for type"),
        sym_name_and_arity(SymName / Arity), suffix(":"), nl,
        words("error in type class constraints:"),
        words(choose_number(Vars, "type variable", "type variables"))]
        ++ list_to_pieces(VarsStrs) ++
        [words(choose_number(Vars, "occurs", "occur")),
        words("in the constraints, but"),
        words(choose_number(Vars, "is", "are")),
        words("not determined by the constructor's argument types."), nl],
    Msg = simple_msg(Context,
        [always(Pieces),
        verbose_only(report_unbound_tvars_explanation)]),
    Spec = error_spec(severity_error, phase_type_check, [Msg]).

:- func report_unbound_tvars_explanation = list(format_component).

report_unbound_tvars_explanation =
    [words("All types occurring in typeclass constraints"),
    words("must be fully determined."),
    words("A type is fully determined if one of the"),
    words("following holds:"),
    nl,
    words("1) All type variables occurring in the type"),
    words("are determined."),
    nl,
    words("2) The type occurs in a constraint argument,"),
    words("that argument is in the range of some"),
    words("functional dependency for that class, and"),
    words("the types in all of the domain arguments for"),
    words("that functional dependency are fully"),
    words("determined."),
    nl,
    words("A type variable is determined if one of the"),
    words("following holds:"),
    nl,
    words("1) The type variable occurs in the argument"),
    words("types of the predicate, function, or"),
    words("constructor which is constrained."),
    nl,
    words("2) The type variable occurs in a type which"),
    words("is fully determined."),
    nl,
    words("See the ""Functional dependencies"" section"),
    words("of the reference manual for details."), nl].

%---------------------------------------------------------------------------%

    % Check that all types appearing in universal (existential) constraints are
    % universally (existentially) quantified.
    %
:- pred check_constraint_quant(pred_info::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

check_constraint_quant(PredInfo, !ModuleInfo, !Specs) :-
    pred_info_get_exist_quant_tvars(PredInfo, ExistQVars),
    pred_info_get_class_context(PredInfo, Constraints),
    Constraints = constraints(UnivCs, ExistCs),
    prog_type.constraint_list_get_tvars(UnivCs, UnivTVars),
    solutions.solutions((pred(V::out) is nondet :-
            list.member(V, UnivTVars),
            list.member(V, ExistQVars)
        ), BadUnivTVars),
    maybe_report_badly_quantified_vars(PredInfo, universal_constraint,
        BadUnivTVars, !ModuleInfo, !Specs),
    prog_type.constraint_list_get_tvars(ExistCs, ExistTVars),
    list.delete_elems(ExistTVars, ExistQVars, BadExistTVars),
    maybe_report_badly_quantified_vars(PredInfo, existential_constraint,
        BadExistTVars, !ModuleInfo, !Specs).

:- type quant_error_type
    --->    universal_constraint
    ;       existential_constraint.

:- pred maybe_report_badly_quantified_vars(pred_info::in, quant_error_type::in,
    list(tvar)::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

maybe_report_badly_quantified_vars(PredInfo, QuantErrorType, TVars,
        !ModuleInfo, !Specs) :-
    (
        TVars = []
    ;
        TVars = [_ | _],
        Spec = report_badly_quantified_vars(PredInfo, QuantErrorType, TVars),
        !:Specs = [Spec | !.Specs]
    ).

:- func report_badly_quantified_vars(pred_info, quant_error_type, list(tvar))
    = error_spec.

report_badly_quantified_vars(PredInfo, QuantErrorType, TVars) = Spec :-
    pred_info_get_typevarset(PredInfo, TVarSet),
    pred_info_context(PredInfo, Context),

    InDeclaration = [words("In declaration of")] ++
        describe_one_pred_info_name(should_module_qualify, PredInfo) ++
        [suffix(":")],
    TypeVariables = [words("type variable"),
        suffix(choose_number(TVars, "", "s"))],
    TVarsStrs = list.map((func(V) = mercury_var_to_string(V, TVarSet, no)),
        TVars),
    TVarsPart = list_to_pieces(TVarsStrs),
    Are = words(choose_number(TVars, "is", "are")),
    (
        QuantErrorType = universal_constraint,
        BlahConstrained = words("universally constrained"),
        BlahQuantified = words("existentially quantified")
    ;
        QuantErrorType = existential_constraint,
        BlahConstrained = words("existentially constrained"),
        BlahQuantified = words("universally quantified")
    ),
    Pieces = InDeclaration ++ TypeVariables ++ TVarsPart ++
        [Are, BlahConstrained, suffix(","), words("but"), Are,
        BlahQuantified, suffix("."), nl],
    Msg = simple_msg(Context, [always(Pieces)]),
    Spec = error_spec(severity_error, phase_type_check, [Msg]).

%---------------------------------------------------------------------------%

:- func this_file = string.

this_file = "check_typeclass.m".

%---------------------------------------------------------------------------%
:- end_module check_typeclass.
%---------------------------------------------------------------------------%
