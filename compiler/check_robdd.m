%---------------------------------------------------------------------------%
% Copyright (C) 2001 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%

% File: check_robdd.m.
% Main author: dmo
% Stability: low

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module xrobdd__check_robdd.

:- interface.

:- import_module term, robdd.

:- type check_robdd(T).
:- type check_robdd == check_robdd(generic).

:- inst check_robdd == ground. % XXX

:- mode di_check_robdd == in. % XXX
:- mode uo_check_robdd == out. % XXX

% Constants.
:- func one = check_robdd(T).
:- func zero = check_robdd(T).

% Conjunction.
:- func check_robdd(T) * check_robdd(T) = check_robdd(T).

% Disjunction.
:- func check_robdd(T) + check_robdd(T) = check_robdd(T).

%-----------------------------------------------------------------------------%

:- func var(var(T)::in, check_robdd(T)::in(check_robdd)) = (check_robdd(T)::out(check_robdd))
		is det.

:- func not_var(var(T)::in, check_robdd(T)::in(check_robdd)) = (check_robdd(T)::out(check_robdd))
		is det.

:- func eq_vars(var(T)::in, var(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

:- func neq_vars(var(T)::in, var(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

:- func imp_vars(var(T)::in, var(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

:- func conj_vars(vars(T)::in, check_robdd(T)::di_check_robdd) = (check_robdd(T)::uo_check_robdd)
		is det.

:- func disj_vars(vars(T)::in, check_robdd(T)::di_check_robdd) = (check_robdd(T)::uo_check_robdd)
		is det.

:- func at_most_one_of(vars(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

:- func not_both(var(T)::in, var(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

:- func io_constraint(var(T)::in, var(T)::in, var(T)::in,
check_robdd(T)::di_check_robdd)
		= (check_robdd(T)::uo_check_robdd) is det.

		% disj_vars_eq(Vars, Var) <=> (disj_vars(Vars) =:= Var).
:- func disj_vars_eq(vars(T)::in, var(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

:- func var_restrict_true(var(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

:- func var_restrict_false(var(T)::in, check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

%-----------------------------------------------------------------------------%

	% Succeed iff the var is entailed by the xROBDD.
:- pred var_entailed(check_robdd(T)::in, var(T)::in) is semidet.

	% Return the set of vars entailed by the xROBDD.
:- func vars_entailed(check_robdd(T)) = vars_entailed_result(T).

	% Return the set of vars disentailed by the xROBDD.
:- func vars_disentailed(check_robdd(T)) = vars_entailed_result(T).

	% Existentially quantify away the var in the xROBDD.
:- func restrict(var(T), check_robdd(T)) = check_robdd(T).

	% Existentially quantify away all vars greater than the specified var.
:- func restrict_threshold(var(T), check_robdd(T)) = check_robdd(T).

:- func restrict_filter(pred(var(T))::(pred(in) is semidet),
		check_robdd(T)::di_check_robdd) =
		(check_robdd(T)::uo_check_robdd) is det.

%-----------------------------------------------------------------------------%

	% labelling(Vars, xROBDD, TrueVars, FalseVars)
	%	Takes a set of Vars and an xROBDD and returns a value assignment
	%	for those Vars that is a model of the Boolean function
	%	represented by the xROBDD.
	%	The value assignment is returned in the two sets TrueVars (set
	%	of variables assigned the value 1) and FalseVars (set of
	%	variables assigned the value 0).
	%
	% XXX should try using sparse_bitset here.
:- pred labelling(vars(T)::in, check_robdd(T)::in, vars(T)::out, vars(T)::out)
		is nondet.

	% minimal_model(Vars, xROBDD, TrueVars, FalseVars)
	%	Takes a set of Vars and an xROBDD and returns a value assignment
	%	for those Vars that is a minimal model of the Boolean function
	%	represented by the xROBDD.
	%	The value assignment is returned in the two sets TrueVars (set
	%	of variables assigned the value 1) and FalseVars (set of
	%	variables assigned the value 0).
	%
	% XXX should try using sparse_bitset here.
:- pred minimal_model(vars(T)::in, check_robdd(T)::in, vars(T)::out, vars(T)::out)
		is nondet.

%-----------------------------------------------------------------------------%

% XXX
:- func robdd(check_robdd(T)) = robdd(T).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module robdd, sparse_bitset.
:- import_module unsafe, io, pprint.

% T - true vars, F - False Vars, E - equivalent vars, N -
% non-equivalent vars, R - ROBDD.
%
% Combinations to try:
%	R	(straight ROBDD)
%	TER	(Peter Schachte's extension)
%	TFENR	(Everything)

:- import_module xrobdd__r_robdd.
:- import_module xrobdd__tfer_robdd.
:- import_module xrobdd__tfeir_robdd.

:- type check_robdd(T)
	--->	xrobdd(
			x1 :: r(T),
			x2 :: tfeir(T)
		).

:- func check_robdd(r(T), tfeir(T)) = check_robdd(T).
:- pragma promise_pure(check_robdd/2).

check_robdd(X1, X2) = xrobdd(X1, X2) :-
	R1 = to_robdd(X1),
	R2 = to_robdd(X2),
	( R1 = R2 ->
		true
	;
		impure unsafe_perform_io(report_robdd_error(R1, R2))
	).

:- pred report_robdd_error(robdd(T)::in, robdd(T)::in, io__state::di,
		io__state::uo) is det.

report_robdd_error(R1, R2) -->
	%{ R12 = R1 * (~ R2) },
	%{ R21 = R2 * (~ R1) },
	io__write_string("ROBDD representations differ\n"),
	{ P = (pred(V::in, di, uo) is det --> io__write_int(var_to_int(V))) },
	robdd_to_dot(R1, P, "r1.dot"),
	robdd_to_dot(R2, P, "r2.dot").
	/*
	io__write_string("R1 - R2:\n"),
	pprint__write(80, to_doc(R12)),
	io__write_string("\nR2 - R1:\n"),
	pprint__write(80, to_doc(R21)),
	io__nl.
	*/

%-----------------------------------------------------------------------------%

one = xrobdd(one, one).

zero = xrobdd(zero, zero).

X * Y = check_robdd(X ^ x1 * Y ^ x1, X ^ x2 * Y ^ x2).

X + Y = check_robdd(X ^ x1 + Y ^ x1, X ^ x2 + Y ^ x2).

var_entailed(X, V) :-
	var_entailed(X ^ x1, V).

vars_entailed(X) =
	vars_entailed(X ^ x1).

vars_disentailed(X) = 
	vars_disentailed(X ^ x1).

restrict(V, X) =
	check_robdd(restrict(V, X ^ x1), restrict(V, X ^ x2)).

restrict_threshold(V, X) =
	check_robdd(restrict_threshold(V, X ^ x1),
		restrict_threshold(V, X ^ x2)).

var(V, X) = check_robdd(var(V, X ^ x1), var(V, X ^ x2)).

not_var(V, X) = check_robdd(not_var(V, X ^ x1), not_var(V, X ^ x2)).

eq_vars(VarA, VarB, X) =
	check_robdd(eq_vars(VarA, VarB, X ^ x1), eq_vars(VarA, VarB, X ^ x2)).

neq_vars(VarA, VarB, X) =
	check_robdd(neq_vars(VarA, VarB, X ^ x1), neq_vars(VarA, VarB, X ^ x2)).

imp_vars(VarA, VarB, X) =
	check_robdd(imp_vars(VarA, VarB, X ^ x1), imp_vars(VarA, VarB, X ^ x2)).

conj_vars(Vars, X) =
	check_robdd(conj_vars(Vars, X ^ x1), conj_vars(Vars, X ^ x2)).

disj_vars(Vars, X) =
	check_robdd(disj_vars(Vars, X ^ x1), disj_vars(Vars, X ^ x2)).

at_most_one_of(Vars, X) =
	check_robdd(at_most_one_of(Vars, X ^ x1), at_most_one_of(Vars, X ^ x2)).

not_both(VarA, VarB, X) =
	check_robdd(not_both(VarA, VarB, X ^ x1), not_both(VarA, VarB, X ^ x2)).

io_constraint(V_in, V_out, V_, X) =
	check_robdd(io_constraint(V_in, V_out, V_, X ^ x1),
		io_constraint(V_in, V_out, V_, X ^ x2)).

disj_vars_eq(Vars, Var, X) =
	check_robdd(disj_vars_eq(Vars, Var, X ^ x1),
		disj_vars_eq(Vars, Var, X ^ x2)).

var_restrict_true(V, X) =
	check_robdd(var_restrict_true(V, X ^ x1), var_restrict_true(V, X ^ x2)).

var_restrict_false(V, X) =
	check_robdd(var_restrict_false(V, X ^ x1),
		var_restrict_false(V, X ^ x2)).

restrict_filter(P, X) =
	check_robdd(restrict_filter(P, X ^ x1), restrict_filter(P, X ^ x2)).

labelling(Vars, X, TrueVars, FalseVars) :-
	labelling(Vars, X ^ x1, TrueVars, FalseVars).

minimal_model(Vars, X, TrueVars, FalseVars) :-
	minimal_model(Vars, X ^ x1, TrueVars, FalseVars).

%-----------------------------------------------------------------------------%

robdd(X) = X ^ x1 ^ robdd.

%-----------------------------------------------------------------------------%
