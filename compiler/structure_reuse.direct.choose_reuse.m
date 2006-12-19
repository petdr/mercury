%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2006 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: structure_reuse.direct.choose_reuse.m.
% Main authors: nancy.
%
% Given a dead cell table listing the deconstructions that may leave garbage
% (dead cells), we compute the concrete assignments of which constructions can
% profit from these dead cells. Obviously, we want to find those assignments
% which result in the 'best' form of memory reuse possible for the given goals.
%
% Hence, the assignment problem is translated into a mapping problem (inspired
% from Debray's paper: "On copy avoidance in single assignment languages", and
% restricted to reuse of dead cells by at most one new cell).
%
% When assigning constructions to dead deconstructions, a table is first
% computed. For each dead cell, a value is computed that reflects the gain
% a reuse might bring, and the list of constructions involved with reusing it.
% The cell with highest value is selected first, the according constructions
% are annotated, and the table is recomputed. This process is repeated until
% no reusable dead deconstructions are left. 
%
% The value of a dead cell (a specific deconstruction) is computed taking 
% into account the call graph which can be simplified to take only into account
% construction-unifications, conjunctions, and disjunctions. 
% The source of the graph is the deconstruction, the leaves are
% either constructions, or empty. The branches are either conjunctions
% or disjunctions. 
% The value of the dead cell is then computed as follows: 
%   - value of a conjunction = maximum of the values of each of the 
%       conjunct branches. 
%       Intuitively: if a dead deconstruction is followed by
%       two constructions which might reuse the dead cell: pick
%       the one which allows the most potential gain. 
%   - value of a disjunction = average of the value of each of the
%       disjunct branches. 
%       Intuitively: if a dead deconstruction is followed by
%       a disjunction with 2 disjuncts. If reuse is only possible
%       in one of the branches, allowing this reuse means that 
%       a priori reuse will occur in only 50% of the cases. 
%       The value of the disjunct should take this into account. 
%       Without precise notion of which branches are executed
%       more often, taking the simple average of the values is 
%       a good approximation. 
%   - value of a construction = a value that takes into account
%       the cost of constructing a new cell and compares it
%       to the cost of updating a dead cell. If the arities
%       between the dead and new cell differ, a penalty cost
%       is added (approximated as the gain one would have had if
%       the unusable words would have been reused too). 
%       Weights are used to estimate all of these costs and are
%       hard-coded. I don't think there is any need in making
%       these values an option. 
%
% Once the table is computed, the cell with highest value is selected.
% To cut the decision between different dead cells with the same
% value, we select the dead cell that has the least number of
% opportunities to be reused. 
%
% e.g. 
%   X can be reused by 5 different constructions, 
%       but reaches its highest value for a construction C1
%       (value 10).
%   Y can be reused by only one construction, also C1 (value 10). 
%
% First selecting X (and reusing it with construction C1) would 
% jeopardize the reuse of Y and leaves us with only one cell reused. 
% If, on the contrary, one would select Y first, chances are that
% after recomputing the table, X can still be reused by other
% constructions, hence possibly 2 cells reused. 
% Even if Y would be of smaller value, selecting Y first would still 
% be more interesting. Hence, instead of selecting the cell 
% with highest value, we select the cell with highest
% value/degree ratio, degree being the number of constructions at which
% the cell could potentially be reused. 
%   
% Note that cells being deconstructed in the different branches of a
% disjunction can now also be reused after the the disjunction. 
%
% e.g.:
%   ( 
%       ..., X => f(... ), ...      % X dies
%   ; 
%       ..., X => g(... ), ...      % X dies
%   ), 
%   Y <= f(... ), ...           % Y can reuse X
%
% In this example, it is allowed to reuse X for Y. And it will also be
% discovered by the analysis. 
%
%-----------------------------------------------------------------------------%

:- module transform_hlds.ctgc.structure_reuse.direct.choose_reuse.
:- interface.

:- pred determine_reuse(reuse_strategy::in, module_info::in, proc_info::in,
    dead_cell_table::in, hlds_goal::in, hlds_goal::out, reuse_as::out, 
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.type_util.
:- import_module hlds.hlds_data.
:- import_module libs.compiler_util.
:- import_module parse_tree.prog_data.

:- import_module float.
:- import_module int.
:- import_module maybe.
:- import_module multi_map.
:- import_module pair.
:- import_module set.
:- import_module string.
:- import_module svmulti_map.

%-----------------------------------------------------------------------------%

determine_reuse(Strategy, ModuleInfo, ProcInfo, DeadCellTable, !Goal,
        ReuseAs, !IO):-
    % Check for local reuse:
    BackGroundInfo = background_info_init(Strategy, ModuleInfo, ProcInfo),
    process_goal(BackGroundInfo, DeadCellTable, RemainingDeadCellTable,
        !Goal, reuse_as_init, ReuseAs, !IO),

    % Check for cell caching.
    check_for_cell_caching(RemainingDeadCellTable, !Goal, !IO).
     
%-----------------------------------------------------------------------------%

    % A type to collect all the background information needed to process
    % each individual goal.
    %
:- type background_info 
    --->    background(
                strategy    :: reuse_strategy,
                module_info :: module_info, 
                proc_info   :: proc_info, 
                vartypes    :: vartypes
            ).

:- func background_info_init(reuse_strategy, module_info, proc_info) = 
    background_info.

background_info_init(Strategy, ModuleInfo, ProcInfo) = Background :- 
    proc_info_get_vartypes(ProcInfo, VarTypes),
    Background = background(Strategy, ModuleInfo, ProcInfo, VarTypes).

%-----------------------------------------------------------------------------%
% Some types and predicates for the administration of the deconstructions,
% constructions and the 'matches' we want to derive from them.
%

% XXX With the --use-atomic-cells option, the compiler generates code
% that uses GC_MALLOC_ATOMIC to allocate memory for heap cells that contain
% no pointers to GCable memory. If we later reuse such a cell and put a pointer
% to GCable memory into it, the Boehm collector will not see that pointer,
% which may lead to the heap cell being pointed to being reclaimed prematurely,
% a bug that will probably be very hard to find.
%
% To avoid this situation, we should
%
% (1) extend deconstruction_spec with a field of type may_use_atomic_alloc,
%     indicating whether the potentially reused cell may be atomic or not, and
% (2) ensure that we reuse atomically-created cells only for connstructions
%     in which all arguments can be put into atomic cells.
%
% These will require applying type_may_use_atomic_alloc to the arguments of
% both the reused deconstruction unifications and the reusing construction
% unifications.
%
% However, a fix to this problem can wait until structure reuse starts to be
% used in earnest. Until then, Nancy can simply avoid turning on
% --use-atomic-cells.

    % Details of a deconstruction yielding garbage.
    %
:- type deconstruction_spec
    --->    decon(
                decon_var       :: dead_var, 
                decon_pp        :: program_point, 
                decon_cons_id   :: cons_id, 
                decon_args      :: prog_vars, 
                decon_conds     :: reuse_as
            ).

    % Details of a construction possibly reusing some specific garbage cells
    % generated at a deconstruction.
    %
:- type construction_spec 
    --->    con(
                con_pp      :: program_point, 
                con_reuse   :: reuse_type
            ).

    % The reuse-type is a basic identification of whether the cons-ids involved
    % in the reuse are the same, what the arities of the old and new cells are,
    % and which arguments do not need to be updated. 
    %
:- type reuse_type 
    --->    reuse_type(
                same_cons       :: bool,    
                reuse_fields    :: list(needs_update),
                    % States whether the corresponding argument in the list of
                    % arguments of the reused cons needs to be updated when
                    % reused or not. 
                    % Note that list.length(reuse_fields) is the arity of the
                    % reused term.
                reuse_value     :: float
                    % A metric measuring the value of the reuse. A high value
                    % should represent a 'good' reuse (yielding possibly good
                    % results on the general memory behaviour of the procedure)
                    % compared to a reuse with a lower value. 
        ). 

        % A match is a description of a list of deconstructions and a list of
        % constructions. The deconstructions and constructions can all be coded
        % into reuses, as they are such that at run-time at most one
        % deconstruction yielding the dead cell will occur on the same
        % execution path as a construction that
        % can reuse that cell. 
        % This means that all the deconstructions can be coded as
        % deconstructions yielding dead cell, and all the constructions can be
        % coded as constructions reusing the cell that becomes available
        % through one of the deconstructions.
        %
:- type match
    --->    match(
                decon_specs     :: list(deconstruction_spec),
                con_specs       :: list(construction_spec),
                match_value     :: float,
                match_degree    :: int
            ).
    
:- type match_table == multi_map(dead_var, match).

    % Initialise a deconstruction_spec.
    %
:- func deconstruction_spec_init(dead_var, program_point, cons_id, 
    prog_vars, reuse_as) = deconstruction_spec.

deconstruction_spec_init(Var, PP, ConsId, Args, Cond) 
    = decon(Var, PP, ConsId, Args, Cond). 

    % Pre-condition: the set of variables to which the list of deconstructions
    % relate (the dead vars) should be a singleton set. In other words, 
    % all of the deconstructions in a match relate to one and the same
    % dying variable. 
    %
:- func match_init(list(deconstruction_spec)) = match.

match_init(DS) = match(DS, [], 0.0, 0).

    % Verify that a match is still 'empty', i.e. has no constructions that can
    % reuse the dead cell available from the deconstructions listed in the
    % match.
    %
:- pred match_has_no_construction_candidates(match::in) is semidet.

match_has_no_construction_candidates(match(_, [], _, _)).

    % Determine the variable whose term is involved in the reuse if the
    % match would be implemented. 
    %
:- func match_get_dead_var(match) = dead_var. 

match_get_dead_var(Match) = Var :- 
    GetVar = (func(D) = D ^ decon_var), 
    DeadVars0 = list.map(GetVar, Match ^ decon_specs), 
    DeadVars  = list.remove_dups(DeadVars0), 
    (
        DeadVars = [Var | Rest], 
        (
            Rest = []
        ;
            Rest = [_ | _],
            unexpected(choose_reuse.this_file, "match_get_dead_var: " ++
                "too many dead vars.")
        )
    ; 
        DeadVars = [], 
        unexpected(choose_reuse.this_file, "match_get_dead_vars: " ++
            "empty list of vars.") 
    ).

    % Get the list of cons_ids that the dead variable may have when it
    % will be reused. 
    %
:- func match_get_dead_cons_ids(match) = list(cons_id).

match_get_dead_cons_ids(Match) = ConsIds :- 
    GetConsId = (func(D) = D ^ decon_cons_id), 
    ConsIds = list.map(GetConsId, Match ^ decon_specs).

    % Determine the reuse condition of the match. 
    %
:- func match_get_condition(background_info, match) = reuse_as.

match_get_condition(Background, Match) = Condition :- 
    GetCond = (func(D) = D ^ decon_conds),
    Conditions = list.map(GetCond, Match ^ decon_specs),
    (
        Conditions = [First | Rest], 
        list.foldl(
            reuse_as_least_upper_bound(Background ^ module_info, 
                Background ^ proc_info),
            Rest, First, Condition)
    ; 
        Conditions = [], 
        unexpected(choose_reuse.this_file, "match_get_condition: " ++
            "no reuse conditions.\n")
    ). 

    % Add a construction as a potential place for reusing the garbage
    % produced by any of the deconstructions listed in the match.
    % This changes the value of the match.
    %
:- pred match_add_construction(construction_spec::in, match::in, 
        match::out) is det.
match_add_construction(ConSpec, Match0, Match) :- 
    Match0 = match(DeconSpecs0, ConSpecs0, Value0, Degree0), 
    ConSpecs = [ConSpec | ConSpecs0],
    Degree = Degree0 + 1, 
    FDegree0 = float(Degree0), 
    FDegree = float(Degree), 
    Value = (Value0 * FDegree0 + ConSpec ^ con_reuse ^ reuse_value) / FDegree,
    Match = match(DeconSpecs0, ConSpecs, Value, Degree).

%-----------------------------------------------------------------------------%
%
% Manipulating the values of matches... 
%

:- func highest_match_degree_ratio(match_table) = match.

highest_match_degree_ratio(MatchTable) = Match :-
    multi_map.values(MatchTable, Matches), 
    list.sort(reverse_compare_matches_value_degree, Matches, Sorted), 
    (
        Sorted = [Match | _]
    ; 
        Sorted = [], 
        unexpected(choose_reuse.this_file, "highest_match_degree_ratio: " ++
            "empty multi_map.\n")
    ). 

:- pred compare_matches_value_degree(match::in, match::in, 
        comparison_result::out) is det. 

compare_matches_value_degree(MatchA, MatchB, Result) :- 
    VA = match_value_degree(MatchA), 
    VB = match_value_degree(MatchB), 
    compare(Result, VA, VB). 

:- pred reverse_compare_matches_value_degree(match::in, match::in,
        comparison_result::out) is det.

reverse_compare_matches_value_degree(MatchA, MatchB, Result) :- 
    compare_matches_value_degree(MatchB, MatchA, Result). 

:- func match_value_degree(match) = float.

match_value_degree(Match) =
    ( Match ^ match_value \= 0.0 ->
        Match ^ match_value / float(Match ^ match_degree)
    ;
        0.0
    ).

:- pred compare_matches_value(match::in, match::in, 
        comparison_result::out) is det.

compare_matches_value(Match1, Match2, Result) :- 
    V1 = Match1 ^ match_value,
    V2 = Match2 ^ match_value,
    compare(Result, V1, V2).

:- pred reverse_compare_matches_value(match::in, match::in, 
        comparison_result::out) is det.

reverse_compare_matches_value(Match1, Match2, Result) :- 
    compare_matches_value(Match2, Match1, Result). 
    
:- pred match_allows_reuse(match::in) is semidet. 

match_allows_reuse(Match) :- 
    Constructions = Match ^ con_specs, 
    Value = Match ^ match_value,  
    Constructions = [_|_], 
    Value > 0.0.

:- pred highest_match_in_list(list(match)::in, match::in, match::out) is det.

highest_match_in_list(Matches, Match0, Match) :- 
    list.sort(reverse_compare_matches_value, [Match0 | Matches], Sorted), 
    (
        Sorted = [Match | _]
    ;
        Sorted = [], 
        unexpected(choose_reuse.this_file, "highest_match_in_list: " ++
            "empty list of matches.\n")
    ).

    % Given a list of matches concerning the same (list of) deconstruction,
    % compute the average reuse value of that deconstruction. This means
    % merging all the constructions together into one list, and using the
    % average value of the reuses of each of the matches. The final degree
    % of the match is set to the sum of all degrees.
    %
:- pred average_match(list(match)::in, match::out) is det.

average_match(List, AverageMatch):- 
    (
        List = [First | Rest], 
        list.length(List, Length), 
        P = (pred(M::in, !.Acc::in, !:Acc::out) is det :- 
            DeconSpecs = !.Acc ^ decon_specs, 
            ConSpecs = append(!.Acc ^ con_specs, M ^ con_specs),
            Val = !.Acc ^ match_value + M ^ match_value, 
            Deg = !.Acc ^ match_degree + M ^ match_degree, 
            !:Acc = match(DeconSpecs, ConSpecs, Val, Deg)
        ),
        list.foldl(P, Rest, First, Match0), 
        AverageMatch = (Match0 ^ match_value := 
            (Match0 ^ match_value / float(Length)))
    ; 
        List = [], 
        unexpected(choose_reuse.this_file, "average_match: empty list.")
    ). 
            
%-----------------------------------------------------------------------------%
%
% Process a single goal
%
%   * determine a match table
%   * find the best match
%   * annotate the goal with the reuse described by that match
%   * and reprocess the goal until no matches are found.

:- pred process_goal(background_info::in, dead_cell_table::in,
    dead_cell_table::out, hlds_goal::in, hlds_goal::out, reuse_as::in,
    reuse_as::out, io::di, io::uo) is det.

process_goal(Background, !DeadCellTable, !Goal, !ReuseAs, !IO):-
    globals.io_lookup_bool_option(very_verbose, VeryVerbose, !IO),
    %
    % Compute a match table.
    %
    compute_match_table(Background, !.DeadCellTable, !.Goal, MatchTable, !IO),  

    % As long as the match table is not empty, pick out the match with the
    % highest value, annotate the goal accordingly, and repeat the procedure. 
    % If the match table is empty, the work is finished.
    %
    ( multi_map.is_empty(MatchTable) -> 
        true
    ;
        % Select the deconstructions-constructions with highest value. 
        %
        Match = highest_match_degree_ratio(MatchTable),

        % Maybe dump all the matches recorded in the table, highlight the
        % match with the highest value. 
        %
        maybe_write_string(VeryVerbose, "% Reuse results: \n", !IO), 
        maybe_dump_match_table(VeryVerbose, MatchTable, Match, !IO), 

        % Realise the reuses by explicitly annotating the procedure goal. 
        %
        annotate_reuses_in_goal(Background, Match, !Goal), 
        %
        % Remove the deconstructions from the available map of dead cells.
        %
        remove_deconstructions_from_dead_cell_table(Match, !DeadCellTable),

        % Add the conditions involved in the reuses to the existing
        % conditions. 
        %
        ModuleInfo = Background ^ module_info,
        ProcInfo   = Background ^ proc_info,
        reuse_as_least_upper_bound(ModuleInfo, ProcInfo, 
            match_get_condition(Background, Match), !ReuseAs),

        % Process the goal for further reuse-matches. 
        %
        process_goal(Background, !DeadCellTable, !Goal, !ReuseAs, !IO)
    ). 

:- pred remove_deconstructions_from_dead_cell_table(match::in, 
    dead_cell_table::in, dead_cell_table::out) is det.

remove_deconstructions_from_dead_cell_table(Match, !DeadCellTable):- 
    DeconSpecs = Match ^ decon_specs, 
    list.foldl(remove_deconstruction_from_dead_cell_table, DeconSpecs, 
        !DeadCellTable).

:- pred remove_deconstruction_from_dead_cell_table(deconstruction_spec::in,
    dead_cell_table::in, dead_cell_table::out) is det.

remove_deconstruction_from_dead_cell_table(DeconSpec, !DeadCellTable):- 
    dead_cell_table_remove(DeconSpec ^ decon_pp, !DeadCellTable).

%-----------------------------------------------------------------------------%
%
% Compute the match table for a given goal
%
% The table is computed by traversing the whole goal. For each
% deconstruction encountered that is also listed in the dead_cell_table,
% compute a match. 
%

:- pred compute_match_table(background_info::in, dead_cell_table::in,
    hlds_goal::in, match_table::out, io::di, io::uo) is det.

compute_match_table(Background, DeadCellTable, Goal, MatchTable, !IO) :- 
    ContinuationGoals = [], 
    compute_match_table_with_continuation(Background, DeadCellTable, 
        Goal, ContinuationGoals, multi_map.init, MatchTable, !IO).

:- pred compute_match_table_goal_list(background_info::in, dead_cell_table::in,
    hlds_goals::in, match_table::in, match_table::out, io::di, io::uo) is det.

compute_match_table_goal_list(Background, DeadCellTable, Goals, !Table,
        !IO) :- 
    (
        Goals = []
    ;
        Goals = [CurrentGoal | Cont],
        compute_match_table_with_continuation(Background, DeadCellTable,
            CurrentGoal, Cont, !Table, !IO)
    ).

:- pred compute_match_table_with_continuation(background_info::in,
    dead_cell_table::in, hlds_goal::in, hlds_goals::in, 
    match_table::in, match_table::out, io::di, io::uo) is det.

compute_match_table_with_continuation(Background, DeadCellTable, 
        CurrentGoal, Cont, !Table, !IO) :- 
    CurrentGoal = GoalExpr - GoalInfo, 
    (
        GoalExpr = unify(_, _, _, Unification, _),
        (
            Unification = deconstruct(Var, ConsId, Args, _, _, _)
        ->

            ProgramPoint = program_point_init(GoalInfo),
            (
                Condition = dead_cell_table_search(ProgramPoint, 
                    DeadCellTable)
            ->
                ReuseAs = reuse_as_init_with_one_condition(Condition), 
                DeconstructionSpec = deconstruction_spec_init(Var, 
                    ProgramPoint, ConsId, Args, ReuseAs),
                Match0 = match_init([DeconstructionSpec]),
                find_best_match_in_conjunction(Background, Cont, Match0, Match),
                svmulti_map.set(Var, Match, !Table)
            ;
                true
            )
        ;
            true
        ),
        compute_match_table_goal_list(Background, DeadCellTable, Cont, !Table,
            !IO)
    ;
        GoalExpr = plain_call(_, _, _, _, _, _),
        compute_match_table_goal_list(Background, DeadCellTable, 
            Cont, !Table, !IO)
    ;
        GoalExpr = generic_call( _, _, _, _),
        compute_match_table_goal_list(Background, DeadCellTable, 
            Cont, !Table, !IO)
    ;
        GoalExpr = call_foreign_proc(_, _, _, _, _, _, _),
        compute_match_table_goal_list(Background, DeadCellTable, 
            Cont, !Table, !IO)
    ;
        GoalExpr = conj(_, Goals),
        list.append(Goals, Cont, NewCont),
        compute_match_table_goal_list(Background, DeadCellTable, 
            NewCont, !Table, !IO)
    ;
        GoalExpr = disj(Goals),
        compute_match_table_in_disjunction(Background, DeadCellTable, Goals, 
            Cont, !Table, !IO),
        compute_match_table_goal_list(Background, DeadCellTable, Cont, !Table,
            !IO)
    ;
        GoalExpr = switch(_, _, Cases),
        Goals = list.map((func(C) = C ^ case_goal), Cases),
        compute_match_table_in_disjunction(Background, DeadCellTable,
            Goals, Cont, !Table, !IO),
        compute_match_table_goal_list(Background, DeadCellTable, Cont, !Table,
            !IO)
    ;
        GoalExpr = negation(Goal),
        % if Goal contains deconstructions, they should not be reused within
        % Cont. 
        compute_match_table_with_continuation(Background, DeadCellTable, 
            Goal, [], !Table, !IO),
        compute_match_table_goal_list(Background, DeadCellTable, Cont, 
            !Table, !IO)
    ;
        GoalExpr = scope(_, Goal),
        compute_match_table_with_continuation(Background, DeadCellTable, 
            Goal, Cont, !Table, !IO)
    ;
        GoalExpr = if_then_else(_, CondGoal, ThenGoal, ElseGoal),
        multi_map.init(Table0), 
        compute_match_table_with_continuation(Background, DeadCellTable, 
            CondGoal, [ThenGoal], Table0, TableThen, !IO),
        compute_match_table_with_continuation(Background, DeadCellTable, 
            ElseGoal, [], Table0, TableElse, !IO),
        multi_map.merge(TableThen, !Table), 
        multi_map.merge(TableElse, !Table), 
        process_possible_common_dead_vars(Background, Cont, 
            [TableThen, TableElse], CommonDeadVarsTables, !IO),
        list.foldl(multi_map.merge, CommonDeadVarsTables, !Table),
        compute_match_table_goal_list(Background, DeadCellTable, Cont, 
            !Table, !IO)
    ;
        GoalExpr = shorthand(_),
        unexpected(choose_reuse.this_file, "compute_match_table: " ++
            "shorthand goal.")
    ).

:- pred compute_match_table_in_disjs(background_info::in, dead_cell_table::in,
    hlds_goals::in, list(match_table)::out, io::di, io::uo) is det.

compute_match_table_in_disjs(Background, DeadCellTable, Branches, Tables, 
        !IO) :-     
    list.map_foldl(compute_match_table(Background, DeadCellTable),
        Branches, Tables, !IO).
    
:- pred compute_match_table_in_disjunction(background_info::in,
    dead_cell_table::in, hlds_goals::in, hlds_goals::in, 
    match_table::in, match_table::out, io::di, io::uo) is det.  

compute_match_table_in_disjunction(Background, DeadCellTable, DisjGoals, Cont, 
        !Table, !IO) :-
    % Compute a match table for each of the branches of the disjunction.
    % Each of these tables will contain information about local reuses
    % w.r.t. the disjunction, i.e. a data structure is reused within the
    % same branch in which it dies. 
    compute_match_table_in_disjs(Background, DeadCellTable, DisjGoals, 
        DisjTables, !IO),
    list.foldl(multi_map.merge, DisjTables, !Table),

    % It is possible that each of the branches of the disjunctions
    % deconstructs the same (non local) dead variable. In such a case, we
    % need to check if that dead variable can be reused outside of the
    % disjunction.
    process_possible_common_dead_vars(Background, Cont, DisjTables,
        CommonDeadVarsDisjTables, !IO),
    list.foldl(multi_map.merge, CommonDeadVarsDisjTables, !Table).

:- pred process_possible_common_dead_vars(background_info::in, hlds_goals::in,
    list(match_table)::in, list(match_table)::out, io::di, io::uo) is det.

process_possible_common_dead_vars(Background, Cont, DisjTables, 
        ExtraTables, !IO) :- 
    CommonDeadVars = common_vars(DisjTables),
    (
        CommonDeadVars = [_ | _]
    ->
        list.filter_map(process_common_var(Background, Cont, DisjTables),
            CommonDeadVars, ExtraTables)
    ;
        ExtraTables = []
    ).

:- func common_vars(list(match_table)) = dead_vars.

common_vars(Tables) = CommonVars :- 
    (  
        Tables = [ First | RestTables ],
        CommonVars = list.foldl(common_var_with_list, RestTables, 
            map.keys(First))
    ;
        Tables = [], 
        CommonVars = []
    ).

:- func common_var_with_list(match_table, prog_vars) = dead_vars.

common_var_with_list(Table, List0) = List :- 
    map.keys(Table, Keys),
    Set = set.intersect(list_to_set(List0), list_to_set(Keys)), 
    List = set.to_sorted_list(Set).

:- pred process_common_var(background_info::in, hlds_goals::in,
    list(match_table)::in, dead_var::in, match_table::out) is semidet.

process_common_var(Background, Cont, DisjTables, CommonDeadVar, Table) :- 
    Match0 = match_init(deconstruction_specs(CommonDeadVar, DisjTables)),
    find_best_match_in_conjunction(Background, Cont, Match0, Match),
    match_allows_reuse(Match), % can fail
    multi_map.init(Table0),
    multi_map.det_insert(Table0, CommonDeadVar, Match, Table).
   
:- func deconstruction_specs(prog_var, list(match_table)) = 
    list(deconstruction_spec).

deconstruction_specs(DeadVar, Tables) = DeconstructionSpecs :- 
    list.foldl(deconstruction_specs_2(DeadVar), Tables, [], 
        DeconstructionSpecs).

:- pred deconstruction_specs_2(prog_var::in, match_table::in, 
    list(deconstruction_spec)::in, list(deconstruction_spec)::out) is det.

deconstruction_specs_2(DeadVar, Table, !DeconstructionSpecs) :- 
    multi_map.lookup(Table, DeadVar, Matches),
    NewSpecs = list.condense(list.map(match_get_decon_specs, Matches)),
    append(NewSpecs, !DeconstructionSpecs).

:- func match_get_decon_specs(match) = list(deconstruction_spec). 

match_get_decon_specs(Match) = Match ^ decon_specs. 

%-----------------------------------------------------------------------------%
%
% Find construction unifications for dead cells, compute the values of the
% matches.
%

    % Compute the value of a dead cell with respect to its possible reuses in
    % a conjunction of goals. If reuse is possible, add the specification of
    % the construction where it can be reused to the list of constructions
    % recorded in the match. 
    %
    % In a conjunction, a dead cell can only be reused in at most one of its
    % direct children. This means that for each child a new value is computed.
    % At the end of a conjunction, we immediately choose the reuse with the
    % highest value.  
    %
    % XXX This may not be such a good idea, as the notion of "degree" is used
    % to decide between reuses with the same value later on, once the full
    % match_table is computed.  
    %
    % XXX What is the thing with the degrees here? 
    %
:- pred find_best_match_in_conjunction(background_info::in, hlds_goals::in,
    match::in, match::out) is det.

find_best_match_in_conjunction(Background, Goals, !Match) :- 
    Match0 = !.Match,
    list.map(find_match_in_goal(Background, Match0), Goals, ExclusiveMatches), 
    Degree = count_candidates(ExclusiveMatches),
    highest_match_in_list(ExclusiveMatches, !Match),
    !:Match = !.Match ^ match_degree := Degree.

    % Compute the matches for a dead cell in the context of a disjunction. For
    % each branch, a different match may be found.  At the end, these matches
    % are merged together into one single match, taking the average of match
    % values to be the value of the final match.  Each construction involved in
    % the reuses is counted as a possibility for reuse, hence is reflected in
    % the degree of the final match description.
    %
:- pred find_match_in_disjunction(background_info::in, hlds_goals::in,
    match::in, match::out) is det.

find_match_in_disjunction(Background, Branches, !Match) :- 
    (
        Branches = []
    ;
        Branches = [_ | _],
        list.map(find_match_in_goal(Background, !.Match), Branches,
            BranchMatches),
        average_match(BranchMatches, !:Match)
    ).

:- pred find_match_in_goal(background_info::in, match::in, hlds_goal::in,
    match::out) is det.

find_match_in_goal(Background, Match0, Goal, Match) :- 
    find_match_in_goal_2(Background, Goal, Match0, Match).

:- pred find_match_in_goal_2(background_info::in, hlds_goal::in, 
    match::in, match::out) is det.

find_match_in_goal_2(Background, Goal, !Match) :- 
    Goal = GoalExpr - GoalInfo, 
    (
        GoalExpr = unify(_, _, _, Unification, _),
        (
            Unification = construct(Var, Cons, Args, _, _, _, _),
                % Is the construction still looking for reuse-possibilities...
            empty_reuse_description(goal_info_get_reuse(GoalInfo))

        ->
            % Is it possible for the construction to reuse the dead cell
            % specified by the match?
            %
            verify_match(Background, Var, Cons, Args, 
                program_point_init(GoalInfo), !Match)
        ;
            true
        )
    ;
        GoalExpr = plain_call(_, _, _, _, _, _)
    ;
        GoalExpr = generic_call( _, _, _, _)
    ;
        GoalExpr = call_foreign_proc(_, _, _, _, _, _, _)
    ;
        GoalExpr = conj(_, Goals),
        find_best_match_in_conjunction(Background, Goals, !Match)
    ;
        GoalExpr = disj(Goals),
        find_match_in_disjunction(Background, Goals, !Match)
    ;
        GoalExpr = switch(_, _, Cases),
        Goals = list.map((func(C) = C ^ case_goal), Cases),
        find_match_in_disjunction(Background, Goals, !Match)
    ;
        GoalExpr = negation(_)
    ;
        GoalExpr = scope(_, ScopeGoal),
        find_match_in_goal_2(Background, ScopeGoal, !Match)
    ;
        GoalExpr = if_then_else(_, CondGoal, ThenGoal, ElseGoal),
        Match0 = !.Match, 
        find_best_match_in_conjunction(Background, [CondGoal, ThenGoal], 
            !Match),
        find_match_in_goal_2(Background, ElseGoal, Match0, MatchElse),
        average_match([!.Match, MatchElse], !:Match)
    ;
        GoalExpr = shorthand(_),
        unexpected(choose_reuse.this_file, "find_match_in_goal: " ++
            "shorthand goal.")
    ).

:- func count_candidates(list(match)) = int.

count_candidates(Matches) = list.foldl(add_degree, Matches, 0).

:- func add_degree(match, int) = int. 

add_degree(Match, Degree0) = Degree0 + Match ^ match_degree.

:- pred empty_reuse_description(reuse_description::in) is semidet.

empty_reuse_description(no_reuse_info).

%-----------------------------------------------------------------------------%
%
% Verify the value of a match for a given construction
%

% The value is computed using the following rule: 
%
% Gain = (Alfa + Gamma) * ArityNewCell + Beta
%       - Gamma * (ArityNewCell - UptoDateFields)
%       - ( SameCons? Beta; 0)
%       - Alfa * (ArityOldCell - ArityNewCell)
%
% where
% * Alfa: cost of allocating one single memory cell on the heap; 
% * Gamma: cost of setting the value of one single memory cell on the heap; 
% * Beta: cost of setting the value of the cons_id field; 

:- func alfa_value = int is det.

alfa_value = 5. 

:- func gamma_value = int is det.

gamma_value = 1.

:- func beta_value = int is det.

beta_value = 1. 

:- pred verify_match(background_info::in, prog_var::in, cons_id::in, 
    prog_vars::in, program_point::in, match::in, match::out) is det.

verify_match(Background, NewVar, NewCons, NewArgs, PP, !Match) :- 
    DeconSpecs = !.Match ^ decon_specs, 
    list.filter_map(compute_reuse_type(Background, NewVar, NewCons, NewArgs),
        DeconSpecs, ReuseTypes),
    (
        ReuseType = glb_reuse_types(ReuseTypes) % Can Fail.
    ->
        ConSpec = con(PP, ReuseType),
        match_add_construction(ConSpec, !Match)
    ;
        true
    ).

    % compute_reuse_type(Background, NewVar, NewCons, NewArgs, 
    %   DeconstructionSpecification) = Cost (represented as a reuse_type).
    %
    % Compute a description (including its cost) of reusing the 
    % specified deconstruction for the construction of the new var (NewVar),
    % with cons_id NewCons, and arguments NewArgs.
    %
    % The predicate fails if the construction is incompatible with the
    % deconstructed dead data structure.
    %
:- pred compute_reuse_type(background_info::in, prog_var::in, cons_id::in,
    prog_vars::in, deconstruction_spec::in, reuse_type::out) is semidet.
    
compute_reuse_type(Background, NewVar, NewCons, NewCellArgs, DeconSpec, 
            ReuseType) :- 
    DeconSpec = decon(DeadVar, _, DeadCons, DeadCellArgs, _),

    ModuleInfo = Background ^ module_info, 
    Vartypes = Background ^ vartypes, 
    NewArity = list.length(NewCellArgs), 
    DeadArity = list.length(DeadCellArgs), 

    % Cells with arity zero can not reuse heap cells. 
    NewArity \= 0, 

    % The new cell must not be bigger than the dead cell. 
    NewArity =< DeadArity,

    % Verify wether the cons_ids and arities match the reuse constraint
    % specified by the user. 
    Constraint = Background ^ strategy, 
    DiffArity = DeadArity - NewArity, 
    ( NewCons = DeadCons -> SameCons = yes ; SameCons = no), 
    ( 
        Constraint = within_n_cells_difference(N),
        DiffArity =< N
    ; 
        Constraint = same_cons_id, 
        SameCons = yes
    ),

    % Upon success of all the previous checks, determine the number of
    % fields that do not require an update if the construction unification 
    % would reuse the deconstructed cell. 
    %
    has_secondary_tag(ModuleInfo, Vartypes, NewVar, NewCons, SecTag), 
    has_secondary_tag(ModuleInfo, Vartypes, DeadVar, DeadCons, DeadSecTag), 
    ReuseFields = already_correct_fields(SecTag, NewCellArgs,
        DeadSecTag - DeadCellArgs),
    UpToDateFields = list.length(
        list.delete_all(ReuseFields, needs_update)),
    %
    % Finally, compute the value of this reuse-configuration.
    %
    ( SameCons = yes -> SameConsV = 0; SameConsV = 1),

    Weight = ( (alfa_value + gamma_value) * NewArity + beta_value
        - gamma_value * (NewArity - UpToDateFields)
        - beta_value * SameConsV
        - alfa_value * DiffArity ),
    Weight > 0,
    ReuseType = reuse_type(SameCons, ReuseFields, float(Weight)).


:- func glb_reuse_types(list(reuse_type)) = reuse_type is semidet.

glb_reuse_types([First|Rest]) = 
    list.foldl(glb_reuse_types_2, Rest, First).

:- func glb_reuse_types_2(reuse_type, reuse_type) = reuse_type.

glb_reuse_types_2(R1, R2) = R :- 
    R1 = reuse_type(SameCons1, Fields1, V1),
    R2 = reuse_type(SameCons2, Fields2, V2),
    R = reuse_type(SameCons1 `and` SameCons2, Fields1 `ands` Fields2, 
        (V1 + V2) / 2.00 ).

:- func ands(list(needs_update), list(needs_update)) = list(needs_update). 

ands(L1, L2) = L :- 
    (
        length(L1) =< length(L2)
    -> 
        L1b = L1, 
        L2b = take_upto(length(L1), L2)
    ;
        L1b = take_upto(length(L2), L1),
        L2b = L2
    ),
    L = list.map_corresponding(needs_update_and, L1b, L2b).

:- func needs_update_and(needs_update, needs_update) = needs_update.

needs_update_and(needs_update, needs_update) = needs_update.
needs_update_and(needs_update, does_not_need_update) = needs_update.
needs_update_and(does_not_need_update, needs_update) = needs_update.
needs_update_and(does_not_need_update, does_not_need_update) = 
    does_not_need_update.
    

%-----------------------------------------------------------------------------%
        
        % has_secondary_tag(Var, ConsId, HasSecTag) returns `yes' iff the
        % variable, Var, with cons_id, ConsId, requires a remote
        % secondary tag to distinguish between its various functors.
        %
:- pred has_secondary_tag(module_info::in, vartypes::in,
    prog_var::in, cons_id::in, bool::out) is det.

has_secondary_tag(ModuleInfo, VarTypes, Var, ConsId, SecondaryTag) :- 
    (
        map.lookup(VarTypes, Var, Type),
        type_to_type_defn_body(ModuleInfo, Type, TypeBody),
        TypeBody = hlds_du_type(_, ConsTagValues, _, _, _, _),
        map.search(ConsTagValues, ConsId, ConsTag),
        MaybeSecondaryTag = get_secondary_tag(ConsTag), 
        MaybeSecondaryTag = yes(_)
    ->
        SecondaryTag = yes
    ;
        SecondaryTag = no
    ).

    % already_correct_fields(HasSecTagC, VarsC, HasSecTagR - VarsR)
    % takes a list of variables, VarsC, which are the arguments for the cell to
    % be constructed and the list of variables, VarsR, which are the arguments
    % for the cell to be reused and returns a list of 'needs_update' values.
    % Each occurrence of 'does_not_need_update' indicates that the argument at
    % the corresponding position in the list of arguments already has the
    % correct value stored in it.  To do this correctly we
    % need to know whether each cell has a secondary tag field.
    %
:- func already_correct_fields(bool, prog_vars, pair(bool, prog_vars)) =
    list(needs_update).

already_correct_fields(SecTagC, CurrentCellVars, SecTagR - ReuseCellVars)
        = NeedsNoUpdate ++ list.duplicate(LengthC - LengthB, needs_update) :-
    NeedsNoUpdate = already_correct_fields_2(SecTagC, CurrentCellVars,
        SecTagR, ReuseCellVars),
    LengthC = list.length(CurrentCellVars),
    LengthB = list.length(NeedsNoUpdate).

:- func already_correct_fields_2(bool, prog_vars, bool, prog_vars) 
    = list(needs_update).

already_correct_fields_2(yes, CurrentCellVars, yes, ReuseCellVars)
    = equals(CurrentCellVars, ReuseCellVars).
already_correct_fields_2(yes, CurrentCellVars, no, ReuseCellVars)
    = [needs_update | equals(CurrentCellVars, drop_one(ReuseCellVars))].
already_correct_fields_2(no, CurrentCellVars, yes, ReuseCellVars) 
    = [needs_update | equals(drop_one(CurrentCellVars), ReuseCellVars)].
already_correct_fields_2(no, CurrentCellVars, no, ReuseCellVars) 
    = equals(CurrentCellVars, ReuseCellVars).

    % equals(ListA, ListB) produces a list of 'needs_update' that indicates
    % whether the corresponding elements from ListA and ListB are equal.  If
    % ListA and ListB are of different lengths, the resulting list is the
    % length of the shorter of the two.
    %
:- func equals(list(T), list(T)) = list(needs_update).

equals([], []) = [].
equals([], [_|_]) = [].
equals([_|_], []) = [].
equals([X | Xs], [Y | Ys]) = [NeedsUpdate | equals(Xs, Ys)] :-
    ( X = Y ->
        NeedsUpdate = does_not_need_update
    ;
        NeedsUpdate = needs_update
    ).

:- func drop_one(list(T)) = list(T).

drop_one([]) = [].
drop_one([_ | Xs]) = Xs.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
%
    % Once a match is selected (hence a set of deconstructions and matching
    % constructions), annotate all the involved unifications in the goal.
    %
:- pred annotate_reuses_in_goal(background_info::in, match::in, hlds_goal::in, 
    hlds_goal::out) is det.

annotate_reuses_in_goal(Background, Match, !Goal) :- 
    !.Goal = GoalExpr0 - GoalInfo0, 
    (
        GoalExpr0 = unify(_, _, _, Unification, _),
        GoalExpr = GoalExpr0, 
        annotate_reuse_for_unification(Background, Match, Unification, 
            GoalInfo0, GoalInfo)
    ;
        GoalExpr0 = plain_call(_, _, _, _, _, _),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = generic_call( _, _, _, _),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = call_foreign_proc(_, _, _, _, _, _, _),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = conj(A, Goals0),
        list.map(annotate_reuses_in_goal(Background, Match), Goals0, Goals),
        GoalExpr = conj(A, Goals),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = disj(Goals0),
        list.map(annotate_reuses_in_goal(Background, Match), Goals0, Goals),
        GoalExpr = disj(Goals),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = switch(A, B, Cases0),
        list.map(annotate_reuses_in_case(Background, Match), Cases0, Cases),
        GoalExpr = switch(A, B, Cases),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = negation(_),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = scope(A, ScopeGoal0),
        annotate_reuses_in_goal(Background, Match, ScopeGoal0, ScopeGoal),
        GoalExpr = scope(A, ScopeGoal),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = if_then_else(A, CondGoal0, ThenGoal0, ElseGoal0),
        annotate_reuses_in_goal(Background, Match, CondGoal0, CondGoal),
        annotate_reuses_in_goal(Background, Match, ThenGoal0, ThenGoal), 
        annotate_reuses_in_goal(Background, Match, ElseGoal0, ElseGoal),
        GoalExpr = if_then_else(A, CondGoal, ThenGoal, ElseGoal),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = shorthand(_),
        unexpected(choose_reuse.this_file, "annotate_reuses: " ++
            "shorthand goal.")
    ),
    !:Goal = GoalExpr - GoalInfo.

:- pred annotate_reuses_in_case(background_info::in, match::in, 
    case::in, case::out) is det.
annotate_reuses_in_case(Background, Match, !Case) :-
    !.Case = case(A, Goal0),
    annotate_reuses_in_goal(Background, Match, Goal0, Goal), 
    !:Case = case(A, Goal).

:- pred annotate_reuse_for_unification(background_info::in, match::in,
    unification::in, hlds_goal_info::in, hlds_goal_info::out) is det.

annotate_reuse_for_unification(Background, Match, Unification, !GoalInfo):- 
    CurrentProgramPoint = program_point_init(!.GoalInfo),
    (
        Unification = deconstruct(_, _, _, _, _, _),
        (
            match_find_deconstruction_spec(Match, CurrentProgramPoint, 
                _DeconSpec)
        -> 
            goal_info_set_reuse(potential_reuse(cell_died), !GoalInfo)
        ;
            true
        )
    ;
        Unification = construct(_, _, _, _, _, _, _),
        (   
            match_find_construction_spec(Match, CurrentProgramPoint, ConSpec)
        ->
            DeadVar = match_get_dead_var(Match),
            DeadConsIds = match_get_dead_cons_ids(Match),
            ReuseAs = match_get_condition(Background, Match),
            ReuseFields = ConSpec ^ con_reuse ^ reuse_fields,

            (
                reuse_as_conditional_reuses(ReuseAs)
            -> 
                Kind = conditional_reuse
            ;
                reuse_as_all_unconditional_reuses(ReuseAs)
            ->
                Kind = unconditional_reuse
            ;
                % reuse_as_no_reuses(ReuseAs)
                unexpected(choose_reuse.this_file, 
                    "annotate_reuse_for_unification: no reuse conditions!")
            ),
            CellReused = cell_reused(DeadVar, Kind, DeadConsIds, 
                ReuseFields),
           
            (
                Kind = conditional_reuse,
                KindReuse = potential_reuse(CellReused)
            ;
                % When the reuse is unconditional, we can safely annotate
                % that the unification is always a reuse unification.
                Kind = unconditional_reuse, 
                KindReuse = reuse(CellReused)
            ),
            goal_info_set_reuse(KindReuse, !GoalInfo)
        ;
            true
        )
    ;
        Unification = assign(_, _)
    ;
        Unification = simple_test(_, _)
    ;
        Unification = complicated_unify(_, _, _),
        unexpected(choose_reuse.this_file, 
            "annotate_reuse_for_unification: complicated_unify.")
    ).

:- pred match_find_deconstruction_spec(match::in, program_point::in, 
    deconstruction_spec::out) is semidet.

match_find_deconstruction_spec(Match, ProgramPoint, DeconstructionSpec) :-
    list.filter(deconstruction_spec_with_program_point(ProgramPoint),
        Match ^ decon_specs, [DeconstructionSpec]).

:- pred match_find_construction_spec(match::in, program_point::in, 
    construction_spec::out) is semidet.

match_find_construction_spec(Match, ProgramPoint, ConstructionSpec) :-
    list.filter(construction_spec_with_program_point(ProgramPoint),
        Match ^ con_specs, [ConstructionSpec]).

:- pred deconstruction_spec_with_program_point(program_point::in, 
    deconstruction_spec::in) is semidet.

deconstruction_spec_with_program_point(DeconstructionSpec ^ decon_pp, 
    DeconstructionSpec).

:- pred construction_spec_with_program_point(program_point::in, 
    construction_spec::in) is semidet.

construction_spec_with_program_point(ConstructionSpec ^ con_pp,
    ConstructionSpec).

%-----------------------------------------------------------------------------%
%
% Predicates to print intermediate results as stored in a match_table
%

:- func line_length = int. 

line_length = 79.

:- pred dump_line(string::in, io::di, io::uo) is det.

dump_line(Msg, !IO) :- 
    Prefix = "%---", 
    Start = string.append(Prefix, Msg), 
    Remainder = line_length - string.length(Start) - 1, 
    Line = Start ++ string.duplicate_char('-', Remainder),
    io.write_string(Line, !IO),
    io.write_string("%\n", !IO).
    
:- pred maybe_dump_match_table(bool::in, match_table::in, match::in,
        io::di, io::uo) is det.

maybe_dump_match_table(VeryVerbose, MatchTable, HighestMatch, !IO) :- 
    (
        VeryVerbose = yes,
        dump_line("reuse table", !IO), 
        io.write_string("%\t|\tvar\t|\tvalue\t|\tdegree\n", !IO),
        dump_match("%-sel- ", HighestMatch, !IO),
        dump_full_table(MatchTable, !IO),
        dump_line("", !IO)
    ;
        VeryVerbose = no
    ).

:- pred dump_match(string::in, match::in, io::di, io::uo) is det.
dump_match(Prefix, Match, !IO):- 
    io.write_string(Prefix, !IO), 
    io.write_string("\t|\t", !IO),
    io.write_int(term.var_to_int(match_get_dead_var(Match)), !IO),
    io.write_string("\t|\t", !IO),
    Val = Match ^ match_value, 
    (
        Val \= 0.0 
    ->  
        io.format("%.2f", [f(Val)], !IO)
    ; 
        io.write_string("-", !IO)
    ),
    Degree = Match ^ match_degree, 
    io.write_string("\t|\t", !IO),
    io.write_int(Degree, !IO),
    io.write_string("\t", !IO), 
    dump_match_details(Match, !IO),
    io.nl(!IO).

:- pred dump_match_details(match::in, io::di, io::uo) is det.
dump_match_details(Match, !IO) :- 
    Conds = list.map((func(DeconSpec) = DeconSpec ^ decon_conds), 
        Match ^ decon_specs),
    (
        list.takewhile(reuse_as_all_unconditional_reuses, Conds, _, [])
    -> 
        CondsString = "A"
    ;
        CondsString = "C"
    ), 

    D = list.length(Match ^ decon_specs), 
    C = list.length(Match ^ con_specs), 
    string.append_list(["d: ", int_to_string(D), ", c: ", 
        int_to_string(C), 
        ", Co: ", CondsString], Details), 
    io.write_string(Details, !IO).

:- pred dump_full_table(match_table::in, io::di, io::uo) is det.
dump_full_table(MatchTable, !IO) :- 
    (
        multi_map.is_empty(MatchTable)
    -> 
        dump_line("empty match table", !IO)
    ; 
        dump_line("full table (start)", !IO), 
        multi_map.values(MatchTable, Matches), 
        list.foldl(dump_match("%-----"), Matches, !IO),
        dump_line("full table (end)", !IO)
    ).

:- pred maybe_dump_full_table(bool::in, match_table::in,
    io::di, io::uo) is det.

maybe_dump_full_table(no, _M, !IO).
maybe_dump_full_table(yes, M, !IO) :-
    dump_full_table(M, !IO).

%-----------------------------------------------------------------------------%
    
    % After determining all local reuses of dead datastructures (a data
    % structure becomes dead and is reused in one and the same procedure), we
    % determine the 'global reuses': deconstructions that yield dead data
    % structures, without imposing any reuse constraints are annotated so that
    % these cells can be cached whenever the user specifies that option. 
    %
:- pred check_for_cell_caching(dead_cell_table::in, hlds_goal::in, 
    hlds_goal::out, io::di, io::uo) is det.

check_for_cell_caching(DeadCellTable0, !Goal, !IO) :- 
    dead_cell_table_remove_conditionals(DeadCellTable0, DeadCellTable),
    globals.io_lookup_bool_option(very_verbose, VeryVerbose, !IO),
    (
        \+ dead_cell_table_is_empty(DeadCellTable)
    -> 
        maybe_write_string(VeryVerbose, "% Marking cacheable cells.\n", !IO),
        check_for_cell_caching_2(DeadCellTable, !Goal)
    ;
        maybe_write_string(VeryVerbose, "% No cells to be cached.\n", !IO)
    ).

:- pred check_for_cell_caching_2(dead_cell_table::in, 
    hlds_goal::in, hlds_goal::out) is det.

check_for_cell_caching_2(DeadCellTable, !Goal):- 
    !.Goal = GoalExpr0 - GoalInfo0, 
    (
        GoalExpr0 = unify(A, B, C, Unification0, D),
        check_for_cell_caching_in_unification(DeadCellTable, 
            Unification0, Unification, GoalInfo0, GoalInfo),
        GoalExpr = unify(A, B, C, Unification, D)
    ;
        GoalExpr0 = plain_call(_, _, _, _, _, _),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = generic_call( _, _, _, _),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = call_foreign_proc(_, _, _, _, _, _, _),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = conj(A, Goals0),
        list.map(check_for_cell_caching_2(DeadCellTable), Goals0, Goals),
        GoalExpr = conj(A, Goals),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = disj(Goals0),
        list.map(check_for_cell_caching_2(DeadCellTable), Goals0, Goals),
        GoalExpr = disj(Goals),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = switch(A, B, Cases0),
        list.map(check_for_cell_caching_in_case(DeadCellTable), Cases0, Cases),
        GoalExpr = switch(A, B, Cases),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = negation(_),
        GoalExpr = GoalExpr0, 
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = scope(A, ScopeGoal0),
        check_for_cell_caching_2(DeadCellTable, ScopeGoal0, ScopeGoal),
        GoalExpr = scope(A, ScopeGoal),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = if_then_else(A, CondGoal0, ThenGoal0, ElseGoal0),
        check_for_cell_caching_2(DeadCellTable, CondGoal0, CondGoal),
        check_for_cell_caching_2(DeadCellTable, ThenGoal0, ThenGoal), 
        check_for_cell_caching_2(DeadCellTable, ElseGoal0, ElseGoal),
        GoalExpr = if_then_else(A, CondGoal, ThenGoal, ElseGoal),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = shorthand(_),
        unexpected(choose_reuse.this_file, "check_cc: " ++
            "shorthand goal.")
    ),
    !:Goal = GoalExpr - GoalInfo.

:- pred check_for_cell_caching_in_case(dead_cell_table::in, 
    case::in, case::out) is det.

check_for_cell_caching_in_case(DeadCellTable, !Case) :-
    !.Case = case(A, Goal0),
    check_for_cell_caching_2(DeadCellTable, Goal0, Goal), 
    !:Case = case(A, Goal).

:- pred check_for_cell_caching_in_unification(dead_cell_table::in,
    unification::in, unification::out, 
    hlds_goal_info::in, hlds_goal_info::out) is det.

check_for_cell_caching_in_unification(DeadCellTable, !Unification, !GoalInfo):- 
    (
        !.Unification = deconstruct(A, B, C, D, E, _),
        Condition = dead_cell_table_search(program_point_init(!.GoalInfo), 
            DeadCellTable),
        \+ reuse_condition_is_conditional(Condition)
    -> 
        !:Unification = deconstruct(A, B, C, D, E, can_cgc),
        % XXX Why potential_reuse and not simply "reuse" ? 
        ReuseInfo = potential_reuse(cell_died),
        goal_info_set_reuse(ReuseInfo, !GoalInfo)
    ;
        true
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "structure_reuse.direct.choose_reuse.m". 

%-----------------------------------------------------------------------------%
:- end_module transform_hlds.ctgc.structure_reuse.direct.choose_reuse.
%-----------------------------------------------------------------------------%